import XCTest
@testable import VoiceGuardCore

final class TwoStageVADTests: XCTestCase {
    private let sampleRate: Double = 48_000
    private let frameLength = 2_048

    /// 일정 진폭의 사인파 프레임을 만든다.
    private func makeSamples(amplitude: Float, frequency: Double = 220.0, frameLength: Int? = nil) -> [Float] {
        let count = frameLength ?? self.frameLength
        var samples = [Float](repeating: 0, count: count)
        let step = 2.0 * Double.pi * frequency / sampleRate
        for index in 0..<count {
            samples[index] = amplitude * Float(sin(step * Double(index)))
        }
        return samples
    }

    private func analyze(_ analyzer: TwoStageVADAnalyzer, amplitude: Float, timestamp: TimeInterval) -> VADAnalysisFrame {
        analyzer.process(samples: makeSamples(amplitude: amplitude), sampleRate: sampleRate, timestamp: timestamp)
    }

    // MARK: - 1단계 게이트

    func testQuietRoomSkipsDeepAnalysisAndSavesBattery() {
        let analyzer = TwoStageVADAnalyzer(configuration: .recommended(for: .medium))
        var t: TimeInterval = 0
        var deepFrames = 0

        // 30초(20fps 600프레임) 조용한 실내 배경음 (-54dB 수준)
        for _ in 0..<600 {
            let frame = analyze(analyzer, amplitude: 0.002, timestamp: t)
            XCTAssertEqual(frame.gateState, .closed)
            if frame.didRunDeepAnalysis {
                deepFrames += 1
                // 조용한 구간의 2단계 분석은 주기적 프로브일 때만 허용된다.
                XCTAssertEqual(deepFrames % 1, 0)
            } else {
                XCTAssertEqual(frame.features.estimatedPitchHz, 0.0, "경량 프레임에 피치 연산이 들어감")
                XCTAssertEqual(frame.features.spectralFlux, 0.0)
            }
            t += 0.05
        }

        let stats = analyzer.stats
        XCTAssertEqual(stats.totalFrames, 600)
        XCTAssertEqual(deepFrames, stats.deepAnalysisFrames)
        XCTAssertLessThanOrEqual(deepFrames, 31, "조용한 30초 동안 2단계 분석이 31회를 넘음")
        XCTAssertLessThanOrEqual(stats.deepAnalysisRatio, 0.06, "2단계 분석 비율이 6%를 넘음")
        XCTAssertGreaterThan(stats.estimatedBatterySavingsPercent, 90.0, "배터리 절약 추정치가 90% 미만")
        XCTAssertEqual(stats.gateOpenFrames, 0)
    }

    func testLoudFrameOpensGateAndRunsDeepAnalysis() {
        let analyzer = TwoStageVADAnalyzer(configuration: .recommended(for: .medium))
        var t: TimeInterval = 0

        for _ in 0..<10 {
            _ = analyze(analyzer, amplitude: 0.002, timestamp: t)
            t += 0.05
        }
        XCTAssertEqual(analyzer.currentGateState, .closed)

        let loud = analyze(analyzer, amplitude: 0.2, timestamp: t)
        XCTAssertTrue(loud.didRunDeepAnalysis, "고음량 프레임에서 2단계 분석이 실행되지 않음")
        XCTAssertEqual(loud.gateState, .open)
        XCTAssertGreaterThan(loud.features.rmsDB, -30.0)
        XCTAssertGreaterThan(loud.features.estimatedPitchHz, 0.0, "2단계 분석에서 피치가 추정되지 않음")
    }

    func testHysteresisKeepsGateOpenThroughShortDip() {
        let config = TwoStageVADConfiguration(
            gateEnterMarginDB: 9.0,
            gateExitMarginDB: 6.0,
            gateHoldFrames: 3,
            probeIntervalFrames: 20,
            decimationFactor: 4,
            absoluteFloorDB: -70.0,
            noiseFloorAdaptationRate: 0.04
        )
        let analyzer = TwoStageVADAnalyzer(configuration: config)
        var t: TimeInterval = 0

        // 배경 소음 프라이밍 (-54dB)
        for _ in 0..<20 {
            _ = analyze(analyzer, amplitude: 0.002, timestamp: t)
            t += 0.05
        }

        // 큰 소리로 게이트 열기
        _ = analyze(analyzer, amplitude: 0.2, timestamp: t)
        t += 0.05
        XCTAssertEqual(analyzer.currentGateState, .open)

        // exit 임계 아래로 떨어지는 짧은 딥 — hold 프레임 동안은 계속 열린 상태
        var openFramesDuringDip = 0
        for _ in 0..<3 {
            let frame = analyze(analyzer, amplitude: 0.0015, timestamp: t)
            if frame.gateState == .open { openFramesDuringDip += 1 }
            t += 0.05
        }
        XCTAssertEqual(openFramesDuringDip, 3, "히스테리시스 hold 프레임이 동작하지 않음")

        // 추가 딥이 이어지면 닫힌다
        let closed = analyze(analyzer, amplitude: 0.0015, timestamp: t)
        XCTAssertEqual(closed.gateState, .closed)
    }

    func testGatedFramesCannotTriggerDetector() {
        // 고감도(requiredDeltaDB = 8dB) + 권장 게이트(enter 6dB) 조합에서,
        // 게이트가 닫힌 프레임은 트리거 조건을 만족할 수 없어야 한다.
        let preset = SensitivityPreset.high
        let config = TwoStageVADConfiguration.recommended(for: preset)
        XCTAssertLessThan(config.gateEnterMarginDB, preset.requiredDeltaDB, "게이트 임계가 트리거 임계보다 높으면 경계 프레임을 놓친다")

        let analyzer = TwoStageVADAnalyzer(configuration: config)
        let detector = AgitationDetector(sensitivity: preset, cooldownDurationSeconds: 5.0)
        var t: TimeInterval = 0

        for _ in 0..<10 {
            let frame = analyzer.process(samples: makeSamples(amplitude: 0.002), sampleRate: sampleRate, timestamp: t)
            let decision = detector.process(features: frame.features, timestamp: t)
            XCTAssertFalse(decision.shouldStartRecording)
            t += 0.05
        }

        // 배경보다 5dB 정도 큰 웅성거림(게이트 임계 6dB 미만) — 2단계 분석도, 트리거도 없어야 한다.
        for _ in 0..<200 {
            let frame = analyzer.process(samples: makeSamples(amplitude: 0.0036), sampleRate: sampleRate, timestamp: t)
            let decision = detector.process(features: frame.features, timestamp: t)
            if frame.gateState == .closed {
                XCTAssertFalse(decision.shouldStartRecording, "게이트가 닫힌 프레임에서 오탐이 발생함")
            }
            t += 0.05
        }
    }

    func testProbeFramesRefreshNoiseFloor() {
        let analyzer = TwoStageVADAnalyzer(configuration: .recommended(for: .medium))
        var t: TimeInterval = 0
        for _ in 0..<200 {
            _ = analyze(analyzer, amplitude: 0.002, timestamp: t)
            t += 0.05
        }
        // 조용한 환경으로 내려간 뒤에도 주기적 프로브로 배경 소음이 추종되어야 한다.
        for _ in 0..<300 {
            _ = analyze(analyzer, amplitude: 0.0006, timestamp: t)
            t += 0.05
        }
        XCTAssertLessThan(analyzer.currentNoiseFloorDB, -60.0, "배경 소음이 더 조용한 환경으로 추종되지 않음")
    }

    func testResetClearsStatsAndGate() {
        let analyzer = TwoStageVADAnalyzer(configuration: .recommended(for: .medium))
        _ = analyzer.process(samples: makeSamples(amplitude: 0.2), sampleRate: sampleRate, timestamp: 0)
        XCTAssertGreaterThan(analyzer.stats.totalFrames, 0)

        analyzer.reset()
        XCTAssertEqual(analyzer.stats.totalFrames, 0)
        XCTAssertEqual(analyzer.stats.deepAnalysisFrames, 0)
        XCTAssertEqual(analyzer.currentGateState, .closed)
        XCTAssertEqual(analyzer.currentNoiseFloorDB, -55.0)
    }

    func testConfigurationUpdateIsApplied() {
        let analyzer = TwoStageVADAnalyzer(configuration: TwoStageVADConfiguration(gateEnterMarginDB: 30.0, gateExitMarginDB: 20.0))
        var t: TimeInterval = 0
        for _ in 0..<5 {
            _ = analyze(analyzer, amplitude: 0.002, timestamp: t)
            t += 0.05
        }
        let blocked = analyze(analyzer, amplitude: 0.05, timestamp: t)
        XCTAssertEqual(blocked.gateState, .closed, "높은 게이트 임계에도 게이트가 열림")

        analyzer.update(configuration: TwoStageVADConfiguration(gateEnterMarginDB: 4.0, gateExitMarginDB: 2.0))
        let opened = analyze(analyzer, amplitude: 0.05, timestamp: t + 0.05)
        XCTAssertEqual(opened.gateState, .open, "설정 변경이 반영되지 않음")
    }

    func testSubsampleEnergyEstimateMatchesFullEnergy() {
        let samples = makeSamples(amplitude: 0.1)
        let full = TwoStageVADAnalyzer.estimateEnergyDB(samples: samples, decimationFactor: 1)
        let decimated = TwoStageVADAnalyzer.estimateEnergyDB(samples: samples, decimationFactor: 4)
        XCTAssertEqual(full, decimated, accuracy: 1.5, "서브샘플 RMS 추정 오차가 1.5dB를 넘음")
    }
}
