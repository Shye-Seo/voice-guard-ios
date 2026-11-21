import Foundation
import AVFoundation
import Combine
import VoiceGuardCore

/// 녹음 파일 인덱스와 재생, 파일 보호(암호화) 속성을 관리한다.
///
/// 모든 녹음 파일과 `index.json`은 `FileProtectionType.completeUnlessOpen`으로 저장되어,
/// 기기가 잠긴 상태에서는 복호화 키가 메모리에 올라가지 않는다. 앱 잠금(`AppLockService`)이
/// 인증을 담당하고, 이 클래스는 파일 단위 암호화 속성을 책임진다.
@MainActor
final class RecordingStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var records: [RecordingSessionRecord] = []
    @Published private(set) var playingRecordID: UUID?
    /// 보호 속성이 확인된 녹음 파일 수
    @Published private(set) var protectedFileCount: Int = 0
    @Published private(set) var lastProtectionError: String?
    @Published private(set) var protectionAppliedAt: Date?

    /// 녹음 파일에 적용하는 iOS 데이터 보호 등급
    static let fileProtection: FileProtectionType = .completeUnlessOpen

    private let fileManager = FileManager.default
    private var audioPlayer: AVAudioPlayer?

    private var recordingsDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Recordings", isDirectory: true)
    }

    private var indexFileURL: URL {
        recordingsDirectory.appendingPathComponent("index.json")
    }

    override init() {
        super.init()
        load()
    }

    // MARK: - 파일 경로 / 보호 속성

    @discardableResult
    private func ensureDirectory() throws -> URL {
        let directory = recordingsDirectory
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        applyProtection(to: directory)
        return directory
    }

    /// 새 녹음 파일을 만들 경로를 준비한다(디렉터리 생성 + 디렉터리 보호 등급 적용).
    func prepareProtectedFileURL(for fileName: String) throws -> URL {
        let directory = try ensureDirectory()
        return directory.appendingPathComponent(fileName)
    }

    /// 개별 파일에 데이터 보호 등급을 적용한다. 실패해도 녹음 자체는 계속 진행되도록 오류만 기록한다.
    func applyFileProtection(to url: URL) {
        applyProtection(to: url)
    }

    private func applyProtection(to url: URL) {
        do {
            try fileManager.setAttributes(
                [.protectionKey: RecordingStore.fileProtection],
                ofItemAtPath: url.path
            )
        } catch {
            lastProtectionError = "파일 보호 속성 적용 실패: \(error.localizedDescription)"
        }
    }

    /// 기존 녹음 전체(구버전 파일 포함)에 다시 보호 속성을 적용한다.
    func reapplyFileProtection() {
        lastProtectionError = nil
        migrateProtection()
    }

    private func migrateProtection() {
        guard let directory = try? ensureDirectory() else { return }
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var protectedCount = 0
        for url in contents {
            guard url.pathExtension.lowercased() == "m4a" else { continue }
            if !isFileProtected(url) {
                applyProtection(to: url)
            }
            if isFileProtected(url) {
                protectedCount += 1
            }
        }
        protectedFileCount = protectedCount
        protectionAppliedAt = Date()
    }

    /// 단일 파일의 보호 등급을 확인한다.
    func isFileProtected(_ fileName: String) -> Bool {
        isFileProtected(fileURL(for: fileName))
    }

    private func isFileProtected(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let rawValue = attributes[.protectionKey] as? String else {
            return false
        }
        return rawValue == RecordingStore.fileProtection.rawValue
            || rawValue == FileProtectionType.complete.rawValue
            || rawValue == FileProtectionType.completeUnlessOpen.rawValue
    }

    func fileURL(for fileName: String) -> URL {
        let directory = (try? ensureDirectory()) ?? recordingsDirectory
        return directory.appendingPathComponent(fileName)
    }

    func fileSizeBytes(for fileName: String) -> Int {
        let url = fileURL(for: fileName)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    func fileSizeText(for fileName: String) -> String {
        let bytes = fileSizeBytes(for: fileName)
        guard bytes > 0 else { return "확인 불가" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - 목록 조작

    func add(_ record: RecordingSessionRecord) {
        records.insert(record, at: 0)
        save()
        applyFileProtection(to: fileURL(for: record.fileName))
        migrateProtection()
    }

    func record(with id: UUID) -> RecordingSessionRecord? {
        records.first { $0.id == id }
    }

    func toggleStar(for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isStarred.toggle()
        save()
    }

    func updateNote(for id: UUID, note: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].note = note
        save()
    }

    /// 온디바이스 전사·쟁점 요약을 녹음 인덱스에 저장한다(생성은 `EpisodeSummarizer`).
    func updateEpisodeReport(for id: UUID, report: EpisodeReport?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].episodeReport = report
        save()
    }

    func delete(_ record: RecordingSessionRecord) {
        if playingRecordID == record.id {
            stopPlayback()
        }
        let url = fileURL(for: record.fileName)
        try? fileManager.removeItem(at: url)
        records.removeAll { $0.id == record.id }
        save()
        migrateProtection()
    }

    // MARK: - 재생

    func togglePlayback(for record: RecordingSessionRecord) {
        if playingRecordID == record.id {
            stopPlayback()
            return
        }
        stopPlayback()
        let url = fileURL(for: record.fileName)
        do {
            // 잠금 해제 상태에서만 호출된다(잠금 화면이 탭 전체를 덮는다).
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            audioPlayer = player
            playingRecordID = record.id
        } catch {
            playingRecordID = nil
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingRecordID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playingRecordID = nil
        }
    }

    // MARK: - 저장 / 불러오기

    private func load() {
        defer { migrateProtection() }
        guard let data = try? Data(contentsOf: indexFileURL),
              let decoded = try? JSONDecoder().decode([RecordingSessionRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded
    }

    private func save() {
        do {
            let directory = try ensureDirectory()
            let data = try JSONEncoder().encode(records)
            try data.write(
                to: directory.appendingPathComponent("index.json"),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
        } catch {
            lastProtectionError = "녹음 목록 저장 실패: \(error.localizedDescription)"
        }
    }
}
