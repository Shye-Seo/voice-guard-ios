import SwiftUI
import VoiceGuardCore

struct RecordingsListView: View {
    @EnvironmentObject private var recordingStore: RecordingStore
    @State private var editingRecord: RecordingSessionRecord?
    @State private var draftNote: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if recordingStore.records.isEmpty {
                    ContentUnavailableView(
                        "저장된 자동 녹음이 없습니다",
                        systemImage: "waveform.slash",
                        description: Text("감정 격양이 감지되면 직전 5초부터 자동으로 이 목록에 저장됩니다.")
                    )
                } else {
                    List {
                        ForEach(recordingStore.records) { record in
                            recordingRow(record)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                recordingStore.delete(recordingStore.records[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("자동 녹음함")
            .sheet(item: $editingRecord) { record in
                NavigationStack {
                    Form {
                        Section("메모") {
                            TextEditor(text: $draftNote)
                                .frame(minHeight: 120)
                        }
                    }
                    .navigationTitle("녹음 메모")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("취소") { editingRecord = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("저장") {
                                recordingStore.updateNote(for: record.id, note: draftNote)
                                editingRecord = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private func recordingRow(_ record: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.startedAt, style: .date)
                Text(record.startedAt, style: .time)
                Spacer()
                Button {
                    recordingStore.toggleStar(for: record.id)
                } label: {
                    Image(systemName: record.isStarred ? "star.fill" : "star")
                        .foregroundStyle(record.isStarred ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            Text(record.triggerReason)
                .font(.subheadline.weight(.semibold))

            if !record.note.isEmpty {
                Text(record.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    recordingStore.togglePlayback(for: record)
                } label: {
                    Label(
                        recordingStore.playingRecordID == record.id ? "정지" : "재생 (\(Int(record.durationSeconds))초)",
                        systemImage: recordingStore.playingRecordID == record.id ? "stop.fill" : "play.fill"
                    )
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)

                Button {
                    draftNote = record.note
                    editingRecord = record
                } label: {
                    Label("메모", systemImage: "square.and.pencil")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                ShareLink(item: recordingStore.fileURL(for: record.fileName)) {
                    Label("공유", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
