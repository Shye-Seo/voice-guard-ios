import SwiftUI
import AVFoundation

@main
struct VoiceGuardApp: App {
    @StateObject private var recordingStore: RecordingStore
    @StateObject private var monitorService: AudioMonitorService
    @StateObject private var appLockService: AppLockService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = RecordingStore()
        _recordingStore = StateObject(wrappedValue: store)
        _monitorService = StateObject(wrappedValue: AudioMonitorService(recordingStore: store))
        _appLockService = StateObject(wrappedValue: AppLockService())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordingStore)
                .environmentObject(monitorService)
                .environmentObject(appLockService)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        appLockService.refreshBiometryAvailability()
                    case .background:
                        // 백그라운드로 내려가면 녹음함을 잠근다(감지는 계속 동작).
                        appLockService.lockIfNeeded()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var appLockService: AppLockService

    var body: some View {
        ZStack {
            TabView {
                MonitorView()
                    .tabItem {
                        Label("감지", systemImage: "waveform.circle.fill")
                    }

                RecordingsListView()
                    .tabItem {
                        Label("녹음함", systemImage: "folder.fill")
                    }

                SettingsAndPrivacyView()
                    .tabItem {
                        Label("설정·안내", systemImage: "shield.lefthalf.filled")
                    }
            }

            if appLockService.isLocked {
                AppLockGateView()
                    .environmentObject(appLockService)
                    .transition(.opacity)
            }
        }
    }
}
