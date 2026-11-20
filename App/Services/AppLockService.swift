import Foundation
import LocalAuthentication
import Combine

/// 민감한 대화 녹음을 보호하는 앱 잠금 서비스.
///
/// - Face ID / Touch ID / 기기 암호(`.deviceOwnerAuthentication`)를 모두 지원한다.
/// - 잠금이 켜져 있으면 앱을 켤 때와 백그라운드에서 돌아올 때 잠금 화면이 표시된다.
/// - 인증은 `LAContext`로만 수행하며 생체 정보는 앱이 읽지도, 저장하지도 않는다.
@MainActor
final class AppLockService: ObservableObject {
    private enum Keys {
        static let lockEnabled = "appLockEnabled"
        static let lockOnBackground = "appLockOnBackground"
    }

    /// 앱 잠금 기능이 켜져 있는지 (사용자 설정)
    @Published private(set) var isLockEnabled: Bool
    /// 현재 잠금 화면이 떠 있어야 하는지
    @Published private(set) var isLocked: Bool
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isAuthenticating = false
    @Published private(set) var biometryType: LABiometryType = .none
    @Published private(set) var canEvaluateBiometrics = false
    @Published private(set) var deviceCredentialAvailable = false

    /// 백그라운드 진입 시 자동 잠금 여부
    @Published var lockOnBackground: Bool {
        didSet { defaults.set(lockOnBackground, forKey: Keys.lockOnBackground) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Keys.lockEnabled)
        self.isLockEnabled = enabled
        self.isLocked = enabled
        self.lockOnBackground = defaults.object(forKey: Keys.lockOnBackground) as? Bool ?? true
        refreshBiometryAvailability()
    }

    /// 화면에 보여줄 인증 수단 이름
    var biometryDescription: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "기기 암호"
        }
    }

    /// 기기에서 실제로 쓸 수 있는 인증 수단을 다시 확인한다.
    func refreshBiometryAvailability() {
        let biometricContext = LAContext()
        var biometricError: NSError?
        canEvaluateBiometrics = biometricContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError)
        biometryType = biometricContext.biometryType

        let credentialContext = LAContext()
        var credentialError: NSError?
        deviceCredentialAvailable = credentialContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &credentialError)
    }

    /// 앱이 백그라운드로 갈 때 호출한다.
    func lockIfNeeded() {
        guard isLockEnabled, lockOnBackground else { return }
        isLocked = true
    }

    /// 잠금 화면에서 인증을 시도한다.
    @discardableResult
    func unlock() async -> Bool {
        guard isLockEnabled else {
            isLocked = false
            return true
        }
        let success = await authenticate(reason: "녹음 파일을 열려면 \(biometryDescription) 인증이 필요합니다.")
        if success {
            isLocked = false
            lastErrorMessage = nil
        }
        return success
    }

    /// 설정 화면에서 앱 잠금을 켠다. 켜기 전에 본인 확인을 한 번 요구한다.
    func enableLock() async {
        refreshBiometryAvailability()
        let success = await authenticate(reason: "앱 잠금을 켜려면 본인 확인이 필요합니다.")
        guard success else { return }
        isLockEnabled = true
        isLocked = false
        lastErrorMessage = nil
        defaults.set(true, forKey: Keys.lockEnabled)
    }

    /// 설정 화면에서 앱 잠금을 끈다. 끄기 전에 본인 확인을 요구한다.
    func disableLock() async {
        let success = await authenticate(reason: "앱 잠금을 끄려면 본인 확인이 필요합니다.")
        guard success else { return }
        isLockEnabled = false
        isLocked = false
        defaults.set(false, forKey: Keys.lockEnabled)
    }

    /// 지금 즉시 잠근다.
    func lockNow() {
        guard isLockEnabled else { return }
        isLocked = true
    }

    /// 생체 인증 → 실패 시 기기 암호로 폴백되는 정책으로 인증한다.
    func authenticate(reason: String) async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedFallbackTitle = "기기 암호 입력"
        context.localizedCancelTitle = "취소"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            lastErrorMessage = "이 기기에서는 잠금 인증(Face ID · Touch ID · 기기 암호)을 사용할 수 없습니다. iOS 설정에서 기기 암호를 먼저 설정해 주세요."
            return false
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if !success {
                lastErrorMessage = "인증에 실패했습니다. 다시 시도해 주세요."
            }
            return success
        } catch {
            lastErrorMessage = Self.message(for: error)
            return false
        }
    }

    private static func message(for error: Error) -> String {
        guard let laError = error as? LAError else {
            return "인증에 실패했습니다. (\(error.localizedDescription))"
        }
        switch laError.code {
        case .userCancel, .appCancel, .systemCancel:
            return "인증이 취소되었습니다."
        case .authenticationFailed:
            return "인증에 실패했습니다. 다시 시도해 주세요."
        case .biometryNotAvailable:
            return "이 기기에서 생체 인증을 사용할 수 없습니다. 기기 암호로 잠금을 해제해 주세요."
        case .biometryNotEnrolled:
            return "Face ID/Touch ID가 등록되어 있지 않습니다. iOS 설정에서 등록하거나 기기 암호를 사용해 주세요."
        case .biometryLockout:
            return "생체 인증이 잠겨 있습니다. 기기 암호로 잠금을 해제해 주세요."
        case .passcodeNotSet:
            return "기기 암호가 설정되어 있지 않아 앱 잠금을 사용할 수 없습니다."
        default:
            return "인증을 완료하지 못했습니다. (코드 \(laError.code.rawValue))"
        }
    }
}
