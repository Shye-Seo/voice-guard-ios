import SwiftUI
import LocalAuthentication

/// 앱 잠금이 켜져 있을 때 탭 전체를 덮는 인증 화면.
struct AppLockGateView: View {
    @EnvironmentObject private var appLockService: AppLockService
    @State private var isUnlocking = false

    private var lockSymbolName: String {
        switch appLockService.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.shield.fill"
        }
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: lockSymbolName)
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)

                Text("녹음함이 잠겨 있습니다")
                    .font(.title3.bold())

                Text("민감한 대화 녹음을 보호하기 위해 \(appLockService.biometryDescription) 인증이 필요합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    Task {
                        isUnlocking = true
                        await appLockService.unlock()
                        isUnlocking = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.open")
                        Text(isUnlocking ? "인증 중…" : "잠금 해제")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                }
                .disabled(isUnlocking || appLockService.isAuthenticating)
                .padding(.horizontal, 40)

                if let message = appLockService.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Text("모든 녹음과 분석은 기기 안에서만 처리됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            appLockService.refreshBiometryAvailability()
        }
    }
}
