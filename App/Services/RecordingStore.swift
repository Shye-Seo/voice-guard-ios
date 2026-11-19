import Foundation
import AVFoundation
import VoiceGuardCore

@MainActor
final class RecordingStore: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var records: [RecordingSessionRecord] = []
    @Published private(set) var playingRecordID: UUID?

    private let fileManager = FileManager.default
    private var audioPlayer: AVAudioPlayer?

    private var recordingsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var indexFileURL: URL {
        recordingsDirectory.appendingPathComponent("index.json")
    }

    override init() {
        super.init()
        load()
    }

    func fileURL(for fileName: String) -> URL {
        recordingsDirectory.appendingPathComponent(fileName)
    }

    func add(_ record: RecordingSessionRecord) {
        records.insert(record, at: 0)
        save()
    }

    func toggleStar(for id: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].isStarred.toggle()
        save()
    }

    func updateNote(for id: UUID, note: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].note = note
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
    }

    func togglePlayback(for record: RecordingSessionRecord) {
        if playingRecordID == record.id {
            stopPlayback()
            return
        }
        stopPlayback()
        let url = fileURL(for: record.fileName)
        do {
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

    private func load() {
        guard let data = try? Data(contentsOf: indexFileURL),
              let decoded = try? JSONDecoder().decode([RecordingSessionRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: indexFileURL, options: [.atomic])
    }
}
