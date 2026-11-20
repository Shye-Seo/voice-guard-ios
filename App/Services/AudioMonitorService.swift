import Foundation
import AVFoundation
import Combine
import VoiceGuardCore

/// 온디바이스 감지 파이프라인.
///
/// - 2-Stage VAD: 1단계 저전력 RMS 게이트를 통과한 프레임만 2단계 스펙트럴/피치 분석을 수행한다.
/// - 세션 복구: 통화·알람 인터럽션, 오디오 경로 변경(에어팟 연결/해제), 미디어 서비스 리셋,
///   엔진 구성 변경 시 파이프라인을 자동으로 다시 세운다.
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

    // MARK: - 2-Stage VAD / 배터리 지표

    /// 2단계 분석을 수행한 프레임 비율
    @Published private(set) var deepAnalysisRatio: Double = 0.0
    /// 모델링 기반 배터리 절약 추정치(%)
    @Published private(set) var estimatedBatterySavingsPercent: Double = 0.0
    /// 1단계 게이트가 열려 있는지
    @Published private(set) var isGateOpen = false

    // MARK: - 시스템 복구 상태

    /// 인터럽션·경로 변경 등으로 감지를 잠시 멈췄는지
    @Published private(set) var isSuspendedBySystem = false
    /// 복구/자동 재개 안내 메시지
    @Published private(set) var systemStatusMessage: String?

    // MARK: - 사용자 설정

    @Published var sensitivity: SensitivityPreset = .medium {
        didSet {
            detector.sensitivity = sensitivity
            analyzer.update(configuration: TwoStageVADConfiguration.recommended(for: sensitivity))
        }
    }
    @Published var preRollSeconds: Double = 5.0 {
        didSet {
            // 감지 중에 프리롤 길이를 바꾸면 링버퍼 크기를 즉시 맞춰준다.
            guard isMonitoring, let format = inputFormat else { return }
            preRollBuffer = PreRollRingBuffer(seconds: preRollSeconds, sampleRate: format.sampleRate)
        }
    }
    @Published var cooldownSeconds: Double = 12.0 {
        didSet { detector.cooldownDurationSeconds = cooldownSeconds }
    }

    private let recordingStore: RecordingStore
    private let audioEngine = AVAudioEngine()
    /// 오디오 탭 콜백에서만 접근하는 2-Stage VAD 분석기 (내부적으로 lock 보호)
    private let analyzer = TwoStageVADAnalyzer(configuration: .recommended(for: .medium))
    /// 메인 액터에서만 접근하는 격양 판정 상태 머신
    private let detector = AgitationDetector(sensitivity: .medium, cooldownDurationSeconds: 12.0)
    private let notificationBag = NotificationObserverBag()

    private var preRollBuffer: PreRollRingBuffer?
    private var activeAudioFile: AVAudioFile?
    private var activeFileName: String?
    private var activeStartedAt: Date?
    private var activePeakScore: Double = 0.0
    private var activeReason: String = ""
    private var activeAccumulator: RecordingSessionAccumulator?
    private var inputFormat: AVAudioFormat?
    private var tapInstalled = false

    private var pendingRecoveryTask: Task<Void, Never>?
    private var lastPipelineRestartAt: Date = .distantPast
    private var recoveryAttemptCount = 0
    private static let maximumRecoveryAttempts = 3

    init(recordingStore: RecordingStore) {
        self.recordingStore = recordingStore
        observeSystemAudioNotifications()
    }

    // MARK: - 시작 / 중지

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
            isSuspendedBySystem = false
            systemStatusMessage = nil
            recoveryAttemptCount = 0
            currentState = .monitoring
        } catch {
            errorMessage = "오디오 감지 시작 실패: \(error.localizedDescription)"
            stopMonitoring()
        }
    }

    func stopMonitoring() {
        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = nil
        detachTap()
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        finalizeActiveRecordingIfNeeded()
        detector.reset()
        preRollBuffer?.clear()

        isMonitoring = false
        isSuspendedBySystem = false
        systemStatusMessage = nil
        recoveryAttemptCount = 0
        currentState = .idle
        currentAgitationScore = 0.0
        isGateOpen = false
        activeTriggerReason = nil
    }

    // MARK: - 권한 / 세션 설정

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

    /// 오디오 입력 탭을 설치하고 엔진을 시작한다.
    ///
    /// 탭 콜백은 실시간 스레드에서 실행되므로 메인 액터 상태를 직접 만지지 않고,
    /// 분석기만 사용한 뒤 결과를 메인 액터 Task로 넘긴다.
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
        detector.reset()

        detachTap()

        let analyzer = self.analyzer
        let sampleRate = format.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            let timestamp = Date().timeIntervalSince1970
            let analysis = analyzer.process(samples: samples, sampleRate: sampleRate, timestamp: timestamp)
            let stats = analyzer.stats

            Task { @MainActor [weak self] in
                self?.handle(analysis: analysis, stats: stats, samples: samples)
            }
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func detachTap() {
        guard tapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    // MARK: - 프레임 처리 (메인 액터)

    private func handle(analysis: VADAnalysisFrame, stats: TwoStageVADStats, samples: [Float]) {
        guard isMonitoring else { return }

        let decision = detector.process(features: analysis.features, timestamp: analysis.timestamp)
        currentDB = analysis.features.rmsDB
        noiseFloorDB = decision.noiseFloorDB
        currentAgitationScore = decision.agitationScore
        currentState = decision.state
        isGateOpen = analysis.gateState == .open
        deepAnalysisRatio = stats.deepAnalysisRatio
        estimatedBatterySavingsPercent = stats.estimatedBatterySavingsPercent

        if decision.shouldStartRecording {
            beginRecording(
                reason: decision.triggerReason ?? "감정 격양 감지",
                score: decision.agitationScore,
                at: Date()
            )
        }

        if let accumulator = activeAccumulator, let startedAt = activeStartedAt {
            let offset = max(0.0, analysis.timestamp - startedAt.timeIntervalSince1970)
            accumulator.ingest(features: analysis.features, decision: decision, offset: offset)
        }

        if activeAudioFile != nil {
            activePeakScore = max(activePeakScore, decision.agitationScore)
            writeSamplesToActiveFile(samples: samples)
        } else {
            preRollBuffer?.append(samples)
        }

        if decision.shouldStopRecording {
            finalizeActiveRecordingIfNeeded()
        }
    }

    // MARK: - 녹음 파일

    private func beginRecording(reason: String, score: Double, at date: Date) {
        guard activeAudioFile == nil, let format = inputFormat else { return }

        let fileName = "vg_\(Int(date.timeIntervalSince1970)).m4a"

        do {
            let fileURL = try recordingStore.prepareProtectedFileURL(for: fileName)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let file = try AVAudioFile(
                forWriting: fileURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            recordingStore.applyFileProtection(to: fileURL)

            // 격양 직전 프리롤 샘플을 먼저 기록해 대화 맥락을 보존한다.
            if let preRollSamples = preRollBuffer?.drainOrderedSamples(), !preRollSamples.isEmpty {
                writeFloatArray(preRollSamples, to: file)
            }

            activeAudioFile = file
            activeFileName = fileName
            activeStartedAt = date.addingTimeInterval(-preRollSeconds)
            activePeakScore = score
            activeReason = reason
            activeTriggerReason = reason
            activeAccumulator = RecordingSessionAccumulator(
                mergeGapSeconds: 1.0,
                extensionScoreRatio: 0.82,
                envelopeBucketSeconds: 0.5
            )
        } catch {
            errorMessage = "녹음 파일 생성 실패: \(error.localizedDescription)"
        }
    }

    private func writeSamplesToActiveFile(samples: [Float]) {
        guard let file = activeAudioFile else { return }
        writeFloatArray(samples, to: file)
    }

    /// 마이크 입력 포맷(모노/스테레오, 인터리브 여부)과 무관하게 파일의 처리 포맷으로 변환해 쓴다.
    private func writeFloatArray(_ samples: [Float], to file: AVAudioFile) {
        let format = file.processingFormat
        guard !samples.isEmpty,
              format.channelCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let destination = pcmBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                destination.update(from: base, count: samples.count)
            }
            // 스테레오 처리 포맷으로 열린 경우에도 마이크 한 채널만 기록한다(무음 채널 유지).
            if format.channelCount > 1, let channels = pcmBuffer.floatChannelData {
                for channel in 1..<Int(format.channelCount) {
                    channels[channel].update(repeating: 0, count: samples.count)
                }
            }
        }
        try? file.write(from: pcmBuffer)
    }

    private func finalizeActiveRecordingIfNeeded() {
        guard let fileName = activeFileName, let startedAt = activeStartedAt else {
            activeAudioFile = nil
            activeAccumulator = nil
            return
        }

        let endedAt = Date()
        let duration = max(1.0, endedAt.timeIntervalSince(startedAt))
        let summary = activeAccumulator?.finalize(at: endedAt.timeIntervalSince(startedAt))
            ?? SessionAnalysisSummary()

        let record = RecordingSessionRecord(
            fileName: fileName,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            peakAgitationScore: max(activePeakScore, summary.peakAgitationScore),
            triggerReason: activeReason,
            peakRMSDB: summary.peakRMSDB,
            averageRMSDB: summary.averageRMSDB,
            maxPitchHz: summary.maxPitchHz,
            agitatedSeconds: summary.agitatedSeconds,
            agitationEvents: summary.events,
            levelEnvelope: summary.levelEnvelope,
            envelopeBucketSeconds: summary.envelopeBucketSeconds
        )

        // AVAudioFile 핸들을 먼저 닫아야(스코프 해제) 파일 크기·보호 속성이 확정된다.
        activeAudioFile = nil
        recordingStore.add(record)

        activeFileName = nil
        activeStartedAt = nil
        activePeakScore = 0.0
        activeReason = ""
        activeAccumulator = nil
        activeTriggerReason = nil
    }

    // MARK: - 시스템 인터럽션 / 경로 변경 복구

    private func observeSystemAudioNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        notificationBag.add(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        })

        notificationBag.add(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(notification)
            }
        })

        notificationBag.add(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        })

        notificationBag.add(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEngineConfigurationChange()
            }
        })
    }

    /// 전화 수신·알람 등으로 오디오가 끊겼을 때: 파일을 안전하게 닫고 엔진을 멈춘다.
    /// 인터럽션이 끝나면 `handleInterruption`의 `.ended` 분기에서 자동으로 다시 시작한다.
    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            guard isMonitoring else { return }
            isSuspendedBySystem = true
            systemStatusMessage = "통화·알람 등 시스템 인터럽션으로 감지를 잠시 멈췄습니다. 끝나면 자동으로 다시 시작합니다."
            finalizeActiveRecordingIfNeeded()
            detachTap()
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            currentState = .monitoring
            currentAgitationScore = 0.0
            isGateOpen = false

        case .ended:
            guard isMonitoring, isSuspendedBySystem else { return }
            let rawOptions = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            isSuspendedBySystem = false
            let reason = options.contains(.shouldResume)
                ? "인터럽션 종료 · 감지를 자동으로 재개했습니다."
                : "인터럽션 종료 · 감지를 다시 시작했습니다."
            schedulePipelineRestart(reason: reason)

        @unknown default:
            break
        }
    }

    /// 에어팟 연결/해제 등 오디오 경로 변경 시 입력 포맷이 바뀌므로 파이프라인을 다시 세운다.
    private func handleRouteChange(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }

        let inputName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
        switch reason {
        case .newDeviceAvailable:
            schedulePipelineRestart(reason: "오디오 입력 장치 연결됨(\(inputName ?? "외부 마이크")) · 감지를 다시 시작했습니다.")
        case .oldDeviceUnavailable:
            schedulePipelineRestart(reason: "오디오 입력 장치가 분리되어 내장 마이크로 전환했습니다.")
        case .override, .routeConfigurationChange, .categoryChange, .wakeFromSleep:
            schedulePipelineRestart(reason: "오디오 경로가 변경되어 감지를 다시 시작했습니다.")
        case .noSuitableRouteForCategory, .unknown:
            schedulePipelineRestart(reason: "오디오 경로를 다시 확인했습니다.")
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        guard isMonitoring else { return }
        schedulePipelineRestart(reason: "iOS 오디오 서비스가 재시작되어 감지를 자동 복구했습니다.")
    }

    private func handleEngineConfigurationChange() {
        guard isMonitoring, !isSuspendedBySystem else { return }
        // 짧은 간격의 중복 알림은 schedulePipelineRestart의 디바운스가 걸러낸다.
        schedulePipelineRestart(reason: "오디오 엔진 구성이 바뀌어 감지를 다시 시작했습니다.")
    }

    /// 복구 요청을 디바운스하고 약간의 지연 후 파이프라인을 다시 세운다.
    private func schedulePipelineRestart(reason: String) {
        guard isMonitoring else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPipelineRestartAt) >= 0.6 else { return }
        lastPipelineRestartAt = now

        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.restartPipeline(reason: reason)
        }
    }

    private func restartPipeline(reason: String) {
        guard isMonitoring else { return }

        // 파일을 열어둔 채 입력 포맷이 바뀌면 손상되므로 먼저 확정 저장한다.
        finalizeActiveRecordingIfNeeded()
        detachTap()
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        do {
            try configureAudioSession()
            try startAudioEngine()
            isSuspendedBySystem = false
            systemStatusMessage = reason
            errorMessage = nil
            recoveryAttemptCount = 0
            currentState = .monitoring
            currentAgitationScore = 0.0
        } catch {
            if recoveryAttemptCount < Self.maximumRecoveryAttempts {
                recoveryAttemptCount += 1
                systemStatusMessage = "오디오 감지 복구 재시도 \(recoveryAttemptCount)/\(Self.maximumRecoveryAttempts)…"
                scheduleRetry(reason: reason)
            } else {
                errorMessage = "오디오 감지를 복구하지 못했습니다. 감지를 중지했습니다. (\(error.localizedDescription))"
                recoveryAttemptCount = 0
                stopMonitoring()
            }
        }
    }

    private func scheduleRetry(reason: String) {
        pendingRecoveryTask?.cancel()
        pendingRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.restartPipeline(reason: reason)
        }
    }
}
