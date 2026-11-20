import SwiftUI
import VoiceGuardCore

struct RecordingsListView: View {
    @EnvironmentObject private var recordingStore: RecordingStore

    var body: some View {
        NavigationStack {
            Group {
                if recordingStore.records.isEmpty {
                    ContentUnavailableView(
                        "저장된 자동 녹음이 없습니다",
                        systemImage: "waveform.slash",
                        description: Text("감정 격양이 감지되면 직전 프리롤부터 자동으로 이 목록에 저장됩니다.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(recordingStore.records) { record in
                                NavigationLink {
                                    RecordingDetailView(recordID: record.id)
                                } label: {
                                    recordingRow(record)
                                }
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    recordingStore.delete(recordingStore.records[index])
                                }
                            }
                        } footer: {
                            Text("모든 녹음 파일은 기기 내부에 \(RecordingStore.fileProtection.rawValue) 등급으로 암호화되어 저장됩니다. 앱 잠금이 켜져 있으면 인증 후에만 열립니다.")
                        }
                    }
                }
            }
            .navigationTitle("자동 녹음함")
        }
    }

    private func recordingRow(_ record: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(record.startedAt, style: .date)
                Text(record.startedAt, style: .time)
                Spacer()
                if record.isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                Text(String(format: "%.0f초", record.durationSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Text(record.triggerReason)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            if record.hasAnalysisMetadata {
                HStack(spacing: 10) {
                    Label("\(Int(record.peakRMSDB.rounded()))dB", systemImage: "speaker.wave.2")
                    if record.maxPitchHz > 0 {
                        Label("\(Int(record.maxPitchHz.rounded()))Hz", systemImage: "waveform.path.ecg")
                    }
                    Label("격양 \(record.agitationEvents.count)구간", systemImage: "exclamationmark.triangle")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            if !record.note.isEmpty {
                Text(record.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}
