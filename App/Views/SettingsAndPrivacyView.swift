import SwiftUI

struct SettingsAndPrivacyView: View {
    @EnvironmentObject private var monitorService: AudioMonitorService
    @AppStorage("hasAcknowledgedPrivacyNotice") private var hasAcknowledgedPrivacy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("녹음 동작 설정") {
                    Stepper(value: $monitorService.preRollSeconds, in: 3...15, step: 1) {
                        Text("직전 프리롤 보존: \(Int(monitorService.preRollSeconds))초")
                    }

                    Stepper(value: $monitorService.cooldownSeconds, in: 5...30, step: 1) {
                        Text("진정 후 자동 종료 대기: \(Int(monitorService.cooldownSeconds))초")
                    }
                }

                Section("프라이버시 및 온디바이스 원칙") {
                    Text("• 음성 분석은 100% 기기 내부(On-Device)에서만 수행되며 외부 서버로 전송되지 않습니다.")
                    Text("• 평상시 대화는 파일로 저장하지 않고 최근 \(Int(monitorService.preRollSeconds))초 링버퍼만 메모리에 유지합니다.")
                    Text("• 백그라운드 감지 중에는 iOS 정책에 따라 상태바 주황색 마이크 표시가 유지됩니다.")
                }
                .font(.footnote)

                Section("법적 안내 및 동의") {
                    Text("본인이 참여하지 않은 타인 간의 대화를 몰래 녹음하는 행위는 통신비밀보호법 등 관련 법령에 위반될 수 있습니다. 본인이 대화 당사자인 상황의 기록 및 안전 보호 목적으로만 사용해 주세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("위 프라이버시 및 법적 안내를 확인했습니다", isOn: $hasAcknowledgedPrivacy)
                }
            }
            .navigationTitle("설정 · 안내")
        }
    }
}
