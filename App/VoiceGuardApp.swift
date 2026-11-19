import SwiftUI
import AVFoundation

@main
struct VoiceGuardApp: App {
    @StateObject private var recordingStore = RecordingStore()
    @StateObject private var monitorService: AudioMonitorService

    init() {
        let store = RecordingStore()
        _recordingStore = StateObject(wrappedValue: store)
        _monitorService = StateObject(wrappedValue: AudioMonitorService(recordingStore: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recordingStore)
                .environmentObject(monitorService)
        }
    }
}

struct ContentView: View {
    var body: some View {
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
    }
}
