import Foundation
import AVFoundation
import Combine
import VoiceGuardCore

@MainActor
final class AudioMonitorService: ObservableObject {
    @Published private(set) var isMonitoring = false
    @Published private(set) var currentState: MonitorState = .idle
    @Published private(set) var currentDB: Double = -60.0
    @Published private(set) var noiseFloorDB: Double = -55.0
    @Published private(set) var currentAgitationScore: Double = 0.0
    @Published private(set) var activeTriggerReason: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var errorMessage: String?

    @Published var sensitivity: SensitivityPreset = .medium {
        didSet { detector.sensitivity = sensitivity }
    }
    @Published var preRollSeconds: Double = 5.0
    @Published var cooldownSeconds: Double = 12.0 {
        didSet { detector.cooldownDurationSeconds = cooldownSeconds }
    }

    private let recordingStore: RecordingStore
    private let audioEngine = AVAudioEngine()
    private let featureExtractor = AudioFeatureExtractor()
    private let detector = AgitationDetector(sensitivity: .medium, cooldownDurationSeconds: 12.0)

    private var preRollBuffer: PreRollRingBuffer?
    private var activeAudioFile: AVAudioFile?
    private var activeFileName: String?
    private var activeStartedAt: Date?
    private var activePeakScore: Double = 0.0
    private var activeReason: String = ""
    private var inputFormat: AVAudioFormat?

    init(recordingStore: RecordingStore) {
        self.recordingStore = recordingStore
    }

    func toggleMonitoring() async {
        if isMonitoring {
            stopMonitoring()
        } else {
            await startMonitoring()
        }
    }

    func startMonitoring() async {
        errorMessage = nil
        let granted = await requestMicrophonePermission()
        guard granted else {
            permissionDenied = true
            errorMessage = "마이크 권한이 필요합니다. 설정 > 개인정보 보호 > 마이크에서 허용해 주세요."
            return
        }
        permissionDenied = false

        do {
            try configureAudioSession()
            try startAudioEngine()
            isMonitoring = true
            currentState = .monitoring
        } catch {
            errorMessage = "오디오 감지 시작 실패: \(error.localizedDescription)"
            stopMonitoring()
        }
    }

    func stopMonitoring() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        finalizeActiveRecordingIfNeeded()
        featureExtractor.reset()
        detector.reset()
        preRollBuffer?.clear()

        isMonitoring = false
        currentState = .idle
        currentAgitationScore = 0.0
        activeTriggerReason = nil
    }

    private func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
        )
        try session.setActive(true)
    }

    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(
                domain: "AudioMonitorService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "유효한 마이크 입력 포맷을 찾을 수 없습니다."]
            )
        }

        inputFormat = format
        preRollBuffer = PreRollRingBuffer(seconds: preRollSeconds, sampleRate: format.sampleRate)

        let bufferSize: AVAudioFrameCount = 2048
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.handleAudioBuffer(buffer: buffer, sampleRate: format.sampleRate)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    nonisolated private func handleAudioBuffer(buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        let features = featureExtractor.extract(samples: samples, sampleRate: sampleRate)
        let now = Date().timeIntervalSince1970

        Task { @MainActor [weak self] in
            guard let self, self.isMonitoring else { return }

            let decision = self.detector.process(features: features, timestamp: now)
            self.currentDB = features.rmsDB
            self.noiseFloorDB = decision.noiseFloorDB
            self.currentAgitationScore = decision.agitationScore
            self.currentState = decision.state

            if decision.shouldStartRecording {
                self.beginRecording(reason: decision.triggerReason ?? "감정 격양 감지", score: decision.agitationScore)
            }

            if self.activeAudioFile != nil {
                self.activePeakScore = max(self.activePeakScore, decision.agitationScore)
                self.writeSamplesToActiveFile(samples: samples)
            } else {
                self.preRollBuffer?.append(samples)
            }

            if decision.shouldStopRecording {
                self.finalizeActiveRecordingIfNeeded()
            }
        }
    }

    private func beginRecording(reason: String, score: Double) {
        guard activeAudioFile == nil, let format = inputFormat else { return }

        let fileName = "vg_\(Int(Date().timeIntervalSince1970)).m4a"
        let fileURL = recordingStore.fileURL(for: fileName)

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

            // 격양 직전 프리롤 샘플을 먼저 기록해 대화 맥락 보존
            if let preRollSamples = preRollBuffer?.drainOrderedSamples(), !preRollSamples.isEmpty {
                writeFloatArray(preRollSamples, to: file, format: format)
            }

            activeAudioFile = file
            activeFileName = fileName
            activeStartedAt = Date().addingTimeInterval(-preRollSeconds)
            activePeakScore = score
            activeReason = reason
            activeTriggerReason = reason
        } catch {
            errorMessage = "녹음 파일 생성 실패: \(error.localizedDescription)"
        }
    }

    private func writeSamplesToActiveFile(samples: [Float]) {
        guard let file = activeAudioFile, let format = inputFormat else { return }
        writeFloatArray(samples, to: file, format: format)
    }

    private func writeFloatArray(_ samples: [Float], to file: AVAudioFile, format: AVAudioFormat) {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = pcmBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                dst.update(from: base, count: samples.count)
            }
        }
        try? file.write(from: pcmBuffer)
    }

    private func finalizeActiveRecordingIfNeeded() {
        guard let fileName = activeFileName, let startedAt = activeStartedAt else {
            activeAudioFile = nil
            return
        }

        let endedAt = Date()
        let duration = max(1.0, endedAt.timeIntervalSince(startedAt))
        let record = RecordingSessionRecord(
            fileName: fileName,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            peakAgitationScore: activePeakScore,
            triggerReason: activeReason
        )
        recordingStore.add(record)

        activeAudioFile = nil
        activeFileName = nil
        activeStartedAt = nil
        activePeakScore = 0.0
        activeReason = ""
        activeTriggerReason = nil
    }
}
