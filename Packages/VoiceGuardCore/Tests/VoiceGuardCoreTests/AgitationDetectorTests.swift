import XCTest
@testable import VoiceGuardCore

final class AgitationDetectorTests: XCTestCase {
    func testPreRollRingBufferPreservesChronologicalOrder() {
        let buffer = PreRollRingBuffer(capacitySamples: 5)
        buffer.append([1, 2, 3])
        buffer.append([4, 5, 6, 7])

        let drained = buffer.drainOrderedSamples()
        XCTAssertEqual(drained, [3, 4, 5, 6, 7])
        XCTAssertTrue(buffer.drainOrderedSamples().isEmpty)
    }

    func testCalmSpeechDoesNotTriggerRecording() {
        let detector = AgitationDetector(sensitivity: .medium, cooldownDurationSeconds: 10.0)
        var t: TimeInterval = 1.0
        for _ in 0..<20 {
            let calm = AudioFrameFeatures(rmsDB: -48.0, zeroCrossingRate: 0.05, spectralFlux: 0.02, estimatedPitchHz: 150.0)
            let decision = detector.process(features: calm, timestamp: t)
            XCTAssertFalse(decision.shouldStartRecording)
            XCTAssertEqual(decision.state, .monitoring)
            t += 0.05
        }
    }

    func testSustainedAgitationTriggersAndCooldownStopsRecording() {
        let detector = AgitationDetector(sensitivity: .medium, cooldownDurationSeconds: 5.0)
        var t: TimeInterval = 0.0

        // 배경 소음 안정화
        for _ in 0..<10 {
            let ambient = AudioFrameFeatures(rmsDB: -56.0, zeroCrossingRate: 0.04, spectralFlux: 0.01, estimatedPitchHz: 0.0)
            _ = detector.process(features: ambient, timestamp: t)
            t += 0.05
        }

        // 격양 발화 6프레임 이상 지속
        var started = false
        for _ in 0..<8 {
            let agitated = AudioFrameFeatures(rmsDB: -18.0, zeroCrossingRate: 0.22, spectralFlux: 0.16, estimatedPitchHz: 290.0)
            let decision = detector.process(features: agitated, timestamp: t)
            if decision.shouldStartRecording {
                started = true
            }
            t += 0.05
        }
        XCTAssertTrue(started)
        XCTAssertEqual(detector.state, .recordingAgitated)

        // 진정 구간 5초 이상 경과 시 종료
        var stopped = false
        for _ in 0..<120 {
            let calm = AudioFrameFeatures(rmsDB: -52.0, zeroCrossingRate: 0.04, spectralFlux: 0.01, estimatedPitchHz: 140.0)
            let decision = detector.process(features: calm, timestamp: t)
            if decision.shouldStopRecording {
                stopped = true
                break
            }
            t += 0.05
        }
        XCTAssertTrue(stopped)
        XCTAssertEqual(detector.state, .monitoring)
    }
}
