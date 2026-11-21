import SwiftUI
import UIKit
import VoiceGuardCore

struct SettingsAndPrivacyView: View {
    @EnvironmentObject private var monitorService: AudioMonitorService
    @EnvironmentObject private var recordingStore: RecordingStore
    @EnvironmentObject private var appLockService: AppLockService
    @Environment(\.openURL) private var openURL

    @AppStorage("hasAcknowledgedPrivacyNotice") private var hasAcknowledgedPrivacy = false
    @State private var isProcessingLock = false
    @State private var speechAvailability: SpeechTranscriptionSupport.Availability = .needsPermission

    var body: some View {
        NavigationStack {
            Form {
                recordingSection
                lockSection
                protectionSection
                energySection
                speechSection
                privacySection
                legalSection
            }
            .navigationTitle("설정 · 안내")
            .onAppear { refreshSpeechAvailability() }
        }
    }

    // MARK: - 녹음 동작

    private var recordingSection: some View {
        Section("녹음 동작 설정") {
            Stepper(value: $monitorService.preRollSeconds, in: 3...15, step: 1) {
                Text("직전 프리롤 보존: \(Int(monitorService.preRollSeconds))초")
            }

            Stepper(value: $monitorService.cooldownSeconds, in: 5...30, step: 1) {
                Text("진정 후 자동 종료 대기: \(Int(monitorService.cooldownSeconds))초")
            }

            Picker("감지 민감도", selection: $monitorService.sensitivity) {
                ForEach(SensitivityPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
        }
    }

    // MARK: - 앱 잠금

    private var lockSection: some View {
        Section {
            if appLockService.isLockEnabled {
                HStack {
                    Label("앱 잠금", systemImage: "lock.fill")
                    Spacer()
                    Text("켜짐 · \(appLockService.biometryDescription)")
                        .foregroundStyle(Color.green)
                        .font(.caption)
                }

                Toggle("백그라운드 진입 시 자동 잠금", isOn: $appLockService.lockOnBackground)

                Button {
                    appLockService.lockNow()
                } label: {
                    Label("지금 잠그기", systemImage: "lock.rotation")
                }

                Button(role: .destructive) {
                    isProcessingLock = true
                    Task {
                        await appLockService.disableLock()
                        isProcessingLock = false
                    }
                } label: {
                    Label("앱 잠금 끄기", systemImage: "lock.open")
                }
                .disabled(isProcessingLock)
            } else {
                Button {
                    isProcessingLock = true
                    Task {
                        await appLockService.enableLock()
                        isProcessingLock = false
                    }
                } label: {
                    Label("앱 잠금 켜기 (Face ID · Touch ID · 기기 암호)", systemImage: "faceid")
                }
                .disabled(isProcessingLock || !appLockService.deviceCredentialAvailable)

                if !appLockService.deviceCredentialAvailable {
                    Text("기기 암호가 설정되어 있어야 앱 잠금을 켤 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = appLockService.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("잠금이 켜져 있으면 앱을 열 때와 백그라운드에서 돌아올 때 녹음함 전체가 가려집니다. 인증은 기기 안에서만 처리되며 생체 정보는 앱이 읽거나 저장하지 않습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("녹음 보안 · 앱 잠금")
        } footer: {
            Text("Face ID 사용을 위해 iOS 설정에서 Face ID가 등록되어 있어야 합니다.")
        }
    }

    // MARK: - 전사 · 요약(온디바이스 STT)

    private var speechSection: some View {
        Section {
            HStack {
                Label("온디바이스 음성 인식", systemImage: "text.bubble")
                Spacer()
                Text(speechStatusLabel)
                    .font(.caption)
                    .foregroundStyle(speechAvailability.isReady ? Color.green : Color.secondary)
            }

            Text(SpeechTranscriptionSupport().statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if speechAvailability == .needsPermission {
                Button {
                    Task {
                        _ = await SpeechTranscriptionSupport.requestPermission()
                        refreshSpeechAvailability()
                    }
                } label: {
                    Label("음성 인식 권한 허용", systemImage: "mic.badge.plus")
                }
            }

            if speechAvailability == .denied || speechAvailability == .restricted {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("설정에서 음성 인식 켜기", systemImage: "gearshape")
                }
            }
        } header: {
            Text("전사 · 핵심 쟁점 요약")
        } footer: {
            Text("녹음 상세 화면에서 '전사 · 쟁점 요약'을 누르면 기기 안에서만 음성을 텍스트로 변환하고 격양 구간과 매핑해 핵심 발언·키워드를 정리합니다. 온디바이스 인식이 불가능한 기기에서는 서버 인식으로 넘어가지 않고 기능을 끕니다.")
        }
    }

    private var speechStatusLabel: String {
        switch speechAvailability {
        case .ready: return "사용 가능"
        case .needsPermission: return "권한 필요"
        case .denied: return "꺼짐"
        case .restricted: return "제한됨"
        case .unsupported: return "미지원"
        }
    }

    private func refreshSpeechAvailability() {
        speechAvailability = SpeechTranscriptionSupport().availability
    }

    // MARK: - 파일 보호

    private var protectionSection: some View {
        Section("파일 암호화 (Data Protection)") {
            HStack {
                Text("보호 등급")
                Spacer()
                Text(RecordingStore.fileProtection.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("보호된 녹음 파일")
                Spacer()
                Text("\(recordingStore.protectedFileCount)개")
                    .font(.caption.monospacedDigit())
            }

            Button {
                recordingStore.reapplyFileProtection()
            } label: {
                Label("모든 녹음에 보호 속성 다시 적용", systemImage: "lock.shield")
            }

            if let appliedAt = recordingStore.protectionAppliedAt {
                Text("마지막 확인: \(SessionReportFormatter.dateText(appliedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = recordingStore.lastProtectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("completeUnlessOpen 등급은 기기가 잠기면 파일 복호화 키를 메모리에서 내리고, 이미 열린 파일만 유지합니다. 녹음 본문과 index.json 모두 같은 등급으로 저장됩니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 배터리

    private var energySection: some View {
        Section("배터리 · 2-Stage VAD") {
            HStack {
                Text("2단계 분석 비율")
                Spacer()
                Text(String(format: "%.1f%%", monitorService.deepAnalysisRatio * 100))
                    .font(.caption.monospacedDigit())
            }

            HStack {
                Text("배터리 절약 추정")
                Spacer()
                Text(String(format: "%.1f%%", monitorService.estimatedBatterySavingsPercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
            }

            HStack {
                Text("1단계 에너지 게이트")
                Spacer()
                Text(monitorService.isGateOpen ? "열림 (분석 중)" : "닫힘 (절전)")
                    .font(.caption)
                    .foregroundStyle(monitorService.isGateOpen ? Color.orange : Color.secondary)
            }

            if let message = monitorService.systemStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("1단계는 샘플의 1/4만 사용해 RMS 에너지만 계산하고, 게이트를 통과한 프레임에만 자기상관 피치·스펙트럴 분석을 수행합니다. 절약 수치는 연산량 모델 기준 추정치이며 실측 전력량은 아닙니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 프라이버시 / 법적 안내

    private var privacySection: some View {
        Section("프라이버시 및 온디바이스 원칙") {
            Text("• 음성 분석은 100% 기기 내부(On-Device)에서만 수행되며 외부 서버로 전송되지 않습니다.")
            Text("• 평상시 대화는 파일로 저장하지 않고 최근 \(Int(monitorService.preRollSeconds))초 링버퍼만 메모리에 유지합니다.")
            Text("• 백그라운드 감지 중에는 iOS 정책에 따라 상태바 주황색 마이크 표시가 유지됩니다.")
            Text("• 통화·알람 등으로 오디오가 끊기면 감지를 잠시 멈추고, 끝나면 자동으로 다시 시작합니다.")
        }
        .font(.footnote)
    }

    private var legalSection: some View {
        Section("법적 안내 및 동의") {
            Text("본인이 참여하지 않은 타인 간의 대화를 몰래 녹음하는 행위는 통신비밀보호법 등 관련 법령에 위반될 수 있습니다. 본인이 대화 당사자인 상황의 기록 및 안전 보호 목적으로만 사용해 주세요.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("위 프라이버시 및 법적 안내를 확인했습니다", isOn: $hasAcknowledgedPrivacy)
        }
    }
}
