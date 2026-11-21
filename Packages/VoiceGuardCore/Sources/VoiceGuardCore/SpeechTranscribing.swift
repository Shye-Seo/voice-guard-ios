import Foundation

/// 전사된 발화 1구간.
///
/// 모든 시각은 `AgitationEvent`와 동일하게 **녹음 파일 시작(프리롤 포함) 기준 상대 초**다.
/// 온디바이스 인식 엔진은 구간별 타임스탬프를 돌려주므로, 이 구조체 하나로
/// 격양 구간·음량 엔벨로프와 같은 시간축에서 비교할 수 있다.
public struct SpeechTranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var startedAtOffset: TimeInterval
    public var endedAtOffset: TimeInterval
    /// 인식 신뢰도(0.0 ~ 1.0). 엔진이 값을 주지 않으면 0.0.
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        text: String,
        startedAtOffset: TimeInterval,
        endedAtOffset: TimeInterval,
        confidence: Double = 0.0
    ) {
        let start = max(0, startedAtOffset)
        self.id = id
        self.text = text
        self.startedAtOffset = start
        self.endedAtOffset = max(start, endedAtOffset)
        self.confidence = min(1.0, max(0.0, confidence))
    }

    public var durationSeconds: TimeInterval {
        max(0, endedAtOffset - startedAtOffset)
    }

    public var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 격양 구간 1건과 겹치는 시간(초). 겹치지 않으면 0.
    public func overlapSeconds(with event: AgitationEvent) -> TimeInterval {
        let lower = max(startedAtOffset, event.startedAtOffset)
        let upper = min(endedAtOffset, event.endedAtOffset)
        return max(0, upper - lower)
    }
}

/// 온디바이스 음성 인식에서 발생할 수 있는 실패 사유.
public enum SpeechTranscriptionError: Error, Equatable, Sendable {
    /// 이 기기·이 언어에서 인식기를 쓸 수 없음(모델 미설치, 미지원 기기 등)
    case unavailable(reason: String)
    /// 사용자가 음성 인식 권한을 허용하지 않음
    case notAuthorized
    /// 파일에서 발화를 찾지 못함(무음 구간만 있는 경우)
    case noSpeechDetected
    case cancelled
    case audioUnreadable(reason: String)
    case engineFailure(message: String)

    public var message: String {
        switch self {
        case .unavailable(let reason):
            return "이 기기에서 온디바이스 음성 인식을 사용할 수 없습니다: \(reason)"
        case .notAuthorized:
            return "음성 인식 권한이 꺼져 있습니다. 설정 > VoiceGuard에서 음성 인식을 켜 주세요."
        case .noSpeechDetected:
            return "녹음에서 발화를 찾지 못했습니다. 음량이 작거나 대부분 무음인 구간입니다."
        case .cancelled:
            return "전사가 취소되었습니다."
        case .audioUnreadable(let reason):
            return "녹음 파일을 읽을 수 없습니다: \(reason)"
        case .engineFailure(let message):
            return "음성 인식 엔진 오류: \(message)"
        }
    }
}

extension SpeechTranscriptionError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 음성 → 텍스트 변환 엔진의 추상화.
///
/// 앱은 이 프로토콜만 의존하므로, 실제 기기에서는 `AppleSpeechTranscriber`(SFSpeechRecognizer),
/// 테스트·미리보기에서는 `ScriptedSpeechTranscriber`로 바꿔 끼울 수 있다.
/// 구현체는 **온디바이스 인식만** 사용해야 한다(오디오가 기기 밖으로 나가면 안 됨).
public protocol SpeechTranscribing: Sendable {
    /// 리포트에 기록할 엔진 이름(예: "Apple SFSpeechRecognizer (on-device)")
    var engineName: String { get }
    /// 서버 전송 없이 기기 내부에서만 인식하는 엔진인지
    var isOnDevice: Bool { get }
    func transcribe(audioFileURL: URL) async throws -> [SpeechTranscriptSegment]
}

// MARK: - 전사 결과 정규화

/// 전사 세그먼트 목록을 시간축 기준으로 정리한다.
///
/// 엔진이 돌려주는 구간은 겹치거나 순서가 어긋날 수 있어, 요약 전에 항상 이 과정을 거친다.
public enum SpeechTranscriptNormalizer {
    /// 빈 발화를 버리고 시작 시각 순으로 정렬하며, `duration`이 주어지면 그 이후 구간을 잘라낸다.
    public static func normalize(
        _ segments: [SpeechTranscriptSegment],
        duration: TimeInterval? = nil
    ) -> [SpeechTranscriptSegment] {
        var result: [SpeechTranscriptSegment] = []
        for segment in segments {
            guard segment.hasText else { continue }
            var copy = segment
            copy.text = collapseWhitespace(copy.text)
            if let duration, duration > 0 {
                copy.startedAtOffset = min(copy.startedAtOffset, duration)
                copy.endedAtOffset = min(max(copy.endedAtOffset, copy.startedAtOffset), duration)
            }
            result.append(copy)
        }
        result.sort { lhs, rhs in
            if lhs.startedAtOffset != rhs.startedAtOffset {
                return lhs.startedAtOffset < rhs.startedAtOffset
            }
            if lhs.endedAtOffset != rhs.endedAtOffset {
                return lhs.endedAtOffset < rhs.endedAtOffset
            }
            return lhs.text < rhs.text
        }
        return result
    }

    public static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

// MARK: - 테스트·미리보기용 결정적 전사기

/// 파일 이름별로 미리 정해진 전사 결과를 돌려주는 결정적 전사기.
///
/// `SFSpeechRecognizer`는 시뮬레이터·CI에서 결과가 매번 달라지므로,
/// 요약 로직 검증은 이 구현으로 고정한다.
public struct ScriptedSpeechTranscriber: SpeechTranscribing {
    public let engineName: String
    public let isOnDevice: Bool
    /// 파일 이름(마지막 경로 요소)별 스크립트
    public let scripts: [String: [SpeechTranscriptSegment]]
    /// 등록되지 않은 파일에 사용할 기본 스크립트
    public let fallbackScript: [SpeechTranscriptSegment]

    public init(
        engineName: String = "Scripted (deterministic)",
        isOnDevice: Bool = true,
        scripts: [String: [SpeechTranscriptSegment]] = [:],
        fallbackScript: [SpeechTranscriptSegment] = []
    ) {
        self.engineName = engineName
        self.isOnDevice = isOnDevice
        self.scripts = scripts
        self.fallbackScript = fallbackScript
    }

    public func transcribe(audioFileURL: URL) async throws -> [SpeechTranscriptSegment] {
        let script = scripts[audioFileURL.lastPathComponent] ?? fallbackScript
        return SpeechTranscriptNormalizer.normalize(script)
    }
}

/// 음성 인식을 쓸 수 없는 환경(권한 거부·미지원)을 표현하는 전사기.
public struct UnavailableSpeechTranscriber: SpeechTranscribing {
    public let engineName: String = "unavailable"
    public let isOnDevice: Bool = true
    public let reason: String

    public init(reason: String = "온디바이스 음성 인식을 사용할 수 없습니다.") {
        self.reason = reason
    }

    public func transcribe(audioFileURL: URL) async throws -> [SpeechTranscriptSegment] {
        throw SpeechTranscriptionError.unavailable(reason: reason)
    }
}
