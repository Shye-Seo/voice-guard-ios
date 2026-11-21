import Foundation
import Speech
import VoiceGuardCore

/// 온디바이스 음성 인식의 가용성 판정과 전사기 생성을 담당하는 값 타입 헬퍼.
///
/// 상태를 들고 있지 않으므로(모든 판정은 호출 시점의 시스템 상태를 읽는다) 화면은
/// 필요한 시점에 `availability`를 읽어 표시하면 된다.
///
/// 프라이버시 약속(100% 온디바이스)을 지키기 위해, 온디바이스 인식이 불가능한 기기·언어에서는
/// 서버 인식으로 넘어가지 않고 `UnavailableSpeechTranscriber`를 돌려준다.
struct SpeechTranscriptionSupport {
    enum Availability: Equatable {
        case ready
        case needsPermission
        case denied
        case restricted
        case unsupported(String)

        var isReady: Bool { self == .ready }
    }

    let locale: Locale

    init(locale: Locale = Locale(identifier: "ko_KR")) {
        self.locale = locale
    }

    var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        AppleSpeechTranscriber.authorizationStatus
    }

    var supportsOnDeviceRecognition: Bool {
        AppleSpeechTranscriber.isOnDeviceRecognitionSupported(locale: locale)
    }

    var availability: Availability {
        guard supportsOnDeviceRecognition else {
            return .unsupported(
                "이 기기에서는 한국어 온디바이스 음성 인식을 지원하지 않습니다. 서버 인식은 사용하지 않습니다."
            )
        }
        switch authorizationStatus {
        case .authorized:
            return .ready
        case .notDetermined:
            return .needsPermission
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .needsPermission
        }
    }

    var statusText: String {
        switch availability {
        case .ready:
            return "온디바이스 음성 인식을 사용할 수 있습니다. 오디오는 기기 밖으로 전송되지 않습니다."
        case .needsPermission:
            return "음성 인식 권한을 허용하면 녹음을 기기 안에서 텍스트로 변환합니다."
        case .denied:
            return "음성 인식 권한이 꺼져 있습니다. 설정 > VoiceGuard에서 음성 인식을 켜 주세요."
        case .restricted:
            return "이 기기에서는 음성 인식이 제한되어 있습니다(스크린 타임·MDM 설정)."
        case .unsupported(let reason):
            return reason
        }
    }

    /// 시스템 권한 팝업(최초 1회). 결과 상태를 그대로 돌려준다.
    static func requestPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await AppleSpeechTranscriber.requestAuthorization()
    }

    /// 현재 상태에 맞는 전사기. 권한이 없으면 사유를 담은 실패 전사기를 돌려준다.
    func makeTranscriber() -> SpeechTranscribing {
        guard availability == .ready else {
            return UnavailableSpeechTranscriber(reason: statusText)
        }
        return AppleSpeechTranscriber(locale: locale)
    }
}
