import Foundation

#if canImport(Speech)
import Speech
import AVFoundation

/// Apple `SFSpeechRecognizer`를 **온디바이스 모드로만** 사용하는 전사기.
///
/// - `requiresOnDeviceRecognition = true`를 강제한다. 기기가 온디바이스 인식을 지원하지 않으면
///   서버로 오디오를 보내지 않고 `SpeechTranscriptionError.unavailable`로 실패한다(프라이버시 우선).
/// - 약 45초를 넘는 파일은 구간으로 나눠 순서대로 인식하고, 각 구간의 타임스탬프에 구간 오프셋을 더해
///   하나의 타임라인으로 합친다(온디바이스 인식의 발화 길이 제한 대응).
@available(iOS 17.0, macOS 14.0, *)
public final class AppleSpeechTranscriber: SpeechTranscribing {
    public let engineName: String
    public let isOnDevice: Bool = true
    public let locale: Locale
    /// 이 길이를 넘는 파일은 구간 분할 인식한다.
    public let maximumChunkSeconds: TimeInterval
    /// 분할 인식 시 최대 구간 수(과도한 분할로 인한 지연 방지)
    public let maximumChunks: Int

    public init(
        locale: Locale = Locale(identifier: "ko_KR"),
        maximumChunkSeconds: TimeInterval = 45,
        maximumChunks: Int = 8
    ) {
        self.locale = locale
        self.maximumChunkSeconds = max(10, maximumChunkSeconds)
        self.maximumChunks = max(1, maximumChunks)
        self.engineName = "Apple SFSpeechRecognizer (on-device, \(locale.identifier))"
    }

    /// 현재 권한 상태
    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// 음성 인식 권한을 요청한다(앱 최초 1회).
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// 이 기기·언어에서 온디바이스 인식이 가능한지
    public static func isOnDeviceRecognitionSupported(locale: Locale = Locale(identifier: "ko_KR")) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    public func transcribe(audioFileURL: URL) async throws -> [SpeechTranscriptSegment] {
        guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
            throw SpeechTranscriptionError.audioUnreadable(reason: "파일이 존재하지 않습니다.")
        }
        guard Self.authorizationStatus == .authorized else {
            throw SpeechTranscriptionError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SpeechTranscriptionError.unavailable(reason: "\(locale.identifier) 인식기를 만들 수 없습니다.")
        }
        guard recognizer.isAvailable else {
            throw SpeechTranscriptionError.unavailable(reason: "인식기가 일시적으로 사용할 수 없습니다.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechTranscriptionError.unavailable(reason: "이 기기에서 온디바이스 인식이 지원되지 않습니다.")
        }

        let duration = Self.audioDurationSeconds(of: audioFileURL)
        if duration <= maximumChunkSeconds {
            let segments = try await recognize(recognizer: recognizer, url: audioFileURL, offset: 0)
            return SpeechTranscriptNormalizer.normalize(segments, duration: duration > 0 ? duration : nil)
        }

        var collected: [SpeechTranscriptSegment] = []
        let chunks = try SpeechAudioChunker.makeChunks(
            of: audioFileURL,
            chunkSeconds: maximumChunkSeconds,
            maximumChunks: maximumChunks
        )
        defer { SpeechAudioChunker.removeTemporaryFiles(chunks) }

        for chunk in chunks {
            let segments = try await recognize(recognizer: recognizer, url: chunk.url, offset: chunk.offsetSeconds)
            collected.append(contentsOf: segments)
        }

        let normalized = SpeechTranscriptNormalizer.normalize(collected, duration: duration > 0 ? duration : nil)
        guard !normalized.isEmpty else { throw SpeechTranscriptionError.noSpeechDetected }
        return normalized
    }

    // MARK: - 단일 파일 인식

    private func recognize(
        recognizer: SFSpeechRecognizer,
        url: URL,
        offset: TimeInterval
    ) async throws -> [SpeechTranscriptSegment] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        // 프라이버시 약속: 서버 인식으로 폴백하지 않는다.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(iOS 16.0, macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let resumeGuard = ResumeGuard()
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    guard resumeGuard.claim() else { return }
                    continuation.resume(throwing: SpeechTranscriptionError.engineFailure(message: error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                guard resumeGuard.claim() else { return }
                let segments = result.bestTranscription.segments.compactMap { segment -> SpeechTranscriptSegment? in
                    let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return SpeechTranscriptSegment(
                        text: text,
                        startedAtOffset: offset + segment.timestamp,
                        endedAtOffset: offset + segment.timestamp + max(0, segment.duration),
                        confidence: Double(segment.confidence)
                    )
                }
                continuation.resume(returning: segments)
            }
        }
    }

    private static func audioDurationSeconds(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }
}

/// 인식 콜백이 여러 번 불릴 때 continuation이 두 번 resume되는 것을 막는다.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasResumed { return false }
        hasResumed = true
        return true
    }
}

/// 긴 녹음을 온디바이스 인식기가 처리할 수 있는 길이로 나눈다.
///
/// 원본 파일은 건드리지 않고 임시 `.caf` 조각을 만들어 읽기만 한다.
public enum SpeechAudioChunker {
    public struct Chunk: Sendable {
        public let url: URL
        /// 원본 녹음 시작 기준 이 조각의 시작 시각(초)
        public let offsetSeconds: TimeInterval
    }

    public static func makeChunks(
        of url: URL,
        chunkSeconds: TimeInterval,
        maximumChunks: Int
    ) throws -> [Chunk] {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: url)
        } catch {
            throw SpeechTranscriptionError.audioUnreadable(reason: error.localizedDescription)
        }
        let format = input.processingFormat
        guard format.sampleRate > 0, input.length > 0 else {
            throw SpeechTranscriptionError.noSpeechDetected
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceGuardSTT", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let framesPerChunk = AVAudioFrameCount(max(1, chunkSeconds * format.sampleRate))
        let totalFrames = input.length
        var chunks: [Chunk] = []
        var framePosition: AVAudioFramePosition = 0
        var index = 0

        while framePosition < totalFrames && chunks.count < maximumChunks {
            let remaining = totalFrames - framePosition
            let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(framesPerChunk), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw SpeechTranscriptionError.audioUnreadable(reason: "PCM 버퍼 생성 실패")
            }
            input.framePosition = framePosition
            do {
                try input.read(into: buffer, frameCount: framesToRead)
            } catch {
                throw SpeechTranscriptionError.audioUnreadable(reason: error.localizedDescription)
            }
            guard buffer.frameLength > 0 else { break }

            let chunkURL = directory.appendingPathComponent("chunk-\(index).caf")
            try? FileManager.default.removeItem(at: chunkURL)
            do {
                let output = try AVAudioFile(forWriting: chunkURL, settings: format.settings)
                try output.write(from: buffer)
            } catch {
                throw SpeechTranscriptionError.audioUnreadable(reason: error.localizedDescription)
            }

            chunks.append(
                Chunk(
                    url: chunkURL,
                    offsetSeconds: Double(framePosition) / format.sampleRate
                )
            )
            framePosition += AVAudioFramePosition(buffer.frameLength)
            index += 1
        }

        guard !chunks.isEmpty else { throw SpeechTranscriptionError.noSpeechDetected }
        return chunks
    }

    public static func removeTemporaryFiles(_ chunks: [Chunk]) {
        for chunk in chunks {
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }
}

#endif
