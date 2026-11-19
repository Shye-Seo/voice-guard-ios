import SwiftUI
import VoiceGuardCore

struct MonitorView: View {
    @EnvironmentObject private var monitorService: AudioMonitorService
    @AppStorage("hasAcknowledgedPrivacyNotice") private var hasAcknowledgedPrivacy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusBanner
                    meterCard
                    controlButton
                    sensitivityCard

                    if let reason = monitorService.activeTriggerReason {
                        triggerReasonCard(reason: reason)
                    }

                    if let error = monitorService.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    privacyHintCard
                }
                .padding()
            }
            .navigationTitle("VoiceGuard")
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private var meterCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("실시간 감정 격양도")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int((monitorService.currentAgitationScore * 100).rounded()))%")
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(statusColor)
            }

            ProgressView(value: min(1.0, max(0.0, monitorService.currentAgitationScore)))
                .tint(statusColor)

            HStack {
                Label("현재 음량 \(Int(monitorService.currentDB.rounded())) dB", systemImage: "speaker.wave.2.fill")
                Spacer()
                Label("배경 소음 \(Int(monitorService.noiseFloorDB.rounded())) dB", systemImage: "waveform.path")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var controlButton: some View {
        Button {
            Task {
                await monitorService.toggleMonitoring()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: monitorService.isMonitoring ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)
                Text(monitorService.isMonitoring ? "감지 중지" : "주변 대화 감지 시작")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(monitorService.isMonitoring ? Color.red : Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var sensitivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("감지 민감도")
                .font(.subheadline.weight(.semibold))

            Picker("감지 민감도", selection: $monitorService.sensitivity) {
                ForEach(SensitivityPreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue.uppercased()).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            Text(monitorService.sensitivity.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func triggerReasonCard(reason: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("자동 녹음 트리거됨")
                    .font(.caption.bold())
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var privacyHintCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            Text(
                hasAcknowledgedPrivacy
                ? "모든 음성 분석과 녹음 파일은 서버 전송 없이 이 iPhone 내부에서만 처리·보관됩니다."
                : "첫 사용 전 [설정·안내] 탭에서 온디바이스 처리 및 대화 녹음 법적 안내를 확인해 주세요."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusColor: Color {
        switch monitorService.currentState {
        case .idle: return .gray
        case .monitoring: return .blue
        case .recordingAgitated: return .red
        case .cooldown: return .orange
        }
    }

    private var statusTitle: String {
        switch monitorService.currentState {
        case .idle: return "대기 중"
        case .monitoring: return "주변 음성 감지 중 (녹음 전)"
        case .recordingAgitated: return "격양 감지 · 자동 녹음 중"
        case .cooldown: return "진정 대기 중 (자동 종료 카운트)"
        }
    }

    private var statusSubtitle: String {
        switch monitorService.currentState {
        case .idle: return "버튼을 누르면 온디바이스 감정 격양 감지를 시작합니다."
        case .monitoring: return "직전 \(Int(monitorService.preRollSeconds))초 링버퍼 유지 · 평상시 파일 미저장"
        case .recordingAgitated: return "격양 직전 \(Int(monitorService.preRollSeconds))초부터 자동 저장 중입니다."
        case .cooldown: return "대화가 진정되면 \(Int(monitorService.cooldownSeconds))초 후 자동 저장을 마칩니다."
        }
    }
}
