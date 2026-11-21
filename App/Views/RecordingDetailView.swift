import SwiftUI
import UIKit
import VoiceGuardCore

/// 녹음 1건의 상세 화면 — 격양 구간 타임라인, 음향 지표, 이벤트 목록, 공유/내보내기.
struct RecordingDetailView: View {
    let recordID: UUID

    @EnvironmentObject private var recordingStore: RecordingStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftNote: String = ""
    @State private var isEditingNote = false
    @State private var showingDeleteConfirmation = false
    @State private var showingEpisodeReport = false
    @State private var copiedReport = false

    private var record: RecordingSessionRecord? {
        recordingStore.record(with: recordID)
    }

    var body: some View {
        Group {
            if let record {
                content(for: record)
            } else {
                ContentUnavailableView(
                    "녹음을 찾을 수 없습니다",
                    systemImage: "waveform.slash",
                    description: Text("이미 삭제되었을 수 있습니다.")
                )
            }
        }
        .navigationTitle("녹음 상세")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(for record: RecordingSessionRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(record)
                playbackCard(record)

                if record.hasAnalysisMetadata {
                    timelineCard(record)
                    metricsCard(record)
                    if !record.agitationEvents.isEmpty {
                        eventListCard(record)
                    }
                } else {
                    legacyNotice
                }

                episodeReportCard(record)
                noteCard(record)
                shareCard(record)
                fileCard(record)
                deleteButton(record)
            }
            .padding()
        }
        .sheet(isPresented: $isEditingNote) {
            noteEditor(record)
        }
        .sheet(isPresented: $showingEpisodeReport) {
            EpisodeReportView(recordID: record.id)
                .environmentObject(recordingStore)
        }
        .confirmationDialog(
            "이 녹음을 삭제할까요?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                recordingStore.stopPlayback()
                recordingStore.delete(record)
                dismiss()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("녹음 파일과 분석 메타데이터가 함께 삭제되며 되돌릴 수 없습니다.")
        }
    }

    // MARK: - 카드

    private func header(_ record: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(SessionReportFormatter.dateText(record.startedAt))
                    .font(.headline)
                Spacer()
                Button {
                    recordingStore.toggleStar(for: record.id)
                } label: {
                    Image(systemName: record.isStarred ? "star.fill" : "star")
                        .foregroundStyle(record.isStarred ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(record.triggerReason)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label(String(format: "%.1f초", record.durationSeconds), systemImage: "clock")
                Label("격양 \(record.agitationEvents.count)회", systemImage: "waveform.badge.exclamationmark")
                if record.agitatedSeconds > 0 {
                    Label(String(format: "%.1f초", record.agitatedSeconds), systemImage: "exclamationmark.triangle")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func playbackCard(_ record: RecordingSessionRecord) -> some View {
        HStack(spacing: 14) {
            Button {
                recordingStore.togglePlayback(for: record)
            } label: {
                Image(systemName: recordingStore.playingRecordID == record.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(recordingStore.playingRecordID == record.id ? "재생 중" : "녹음 재생")
                    .font(.subheadline.weight(.semibold))
                Text(record.isStarred ? "중요 표시된 녹음입니다." : "격양 직전 프리롤부터 저장된 구간입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func timelineCard(_ record: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("격양 구간 타임라인")
                .font(.subheadline.weight(.semibold))

            AgitationTimelineView(
                envelope: record.levelEnvelope,
                bucketSeconds: record.envelopeBucketSeconds,
                events: record.agitationEvents,
                duration: record.durationSeconds
            )

            if record.agitationEvents.isEmpty {
                Text("이 녹음에서는 별도 격양 구간이 기록되지 않았습니다. 진정 구간에서 저장이 이어진 경우입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func metricsCard(_ record: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("오디오 분석 리포트")
                .font(.subheadline.weight(.semibold))

            metricRow("피크 음량", value: "\(Int(record.peakRMSDB.rounded())) dB")
            metricRow("평균 음량", value: "\(Int(record.averageRMSDB.rounded())) dB")
            metricRow("최대 피치(F0)", value: record.maxPitchHz > 0 ? "\(Int(record.maxPitchHz.rounded())) Hz" : "측정 안 됨")
            metricRow("최고 격양도", value: "\(Int((record.peakAgitationScore * 100).rounded()))%")
            metricRow("격양 구간 합계", value: String(format: "%.1f초 / %d회", record.agitatedSeconds, record.agitationEvents.count))
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }

    private func eventListCard(_ record: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("격양 이벤트 \(record.agitationEvents.count)건")
                .font(.subheadline.weight(.semibold))

            ForEach(record.agitationEvents.indices, id: \.self) { index in
                let event = record.agitationEvents[index]
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit().bold())
                        .frame(width: 18, height: 18)
                        .background(Color.red.opacity(0.15), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(SessionReportFormatter.timestampText(event.startedAtOffset)) ~ \(SessionReportFormatter.timestampText(event.endedAtOffset))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                        Text(SessionReportFormatter.eventText(event))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var legacyNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("이 녹음은 분석 메타데이터 기능 이전에 저장되어 구간 타임라인이 없습니다. 파일 재생과 공유는 그대로 사용할 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// 전사·핵심 쟁점 요약 카드(요약이 있으면 미리보기, 없으면 생성 진입점).
    private func episodeReportCard(_ record: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("전사 · 핵심 쟁점 요약", systemImage: "text.bubble")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if record.hasEpisodeReport {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if let episode = record.episodeReport {
                Text(episode.summary.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !episode.summary.keywords.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(episode.summary.keywords.prefix(3)) { keyword in
                            Text(keyword.term)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                }

                Button {
                    showingEpisodeReport = true
                } label: {
                    Label("리포트 열기", systemImage: "chevron.right")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Text("온디바이스 음성 인식으로 대화를 전사하고, 격양이 가장 심했던 발언과 반복 키워드를 정리합니다. 오디오는 기기 밖으로 나가지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showingEpisodeReport = true
                } label: {
                    Label("전사 · 쟁점 요약 만들기", systemImage: "waveform.badge.mic")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func noteCard(_ record: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("메모")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(record.note.isEmpty ? "메모 추가" : "메모 편집") {
                    draftNote = record.note
                    isEditingNote = true
                }
                .font(.caption.weight(.medium))
            }

            if record.note.isEmpty {
                Text("이 녹음에 대한 메모가 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(record.note)
                    .font(.subheadline)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func shareCard(_ record: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("공유 · 내보내기")
                .font(.subheadline.weight(.semibold))

            ShareLink(item: recordingStore.fileURL(for: record.fileName)) {
                Label("m4a 오디오 내보내기", systemImage: "square.and.arrow.up")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            ShareLink(item: SessionReportFormatter.reportText(record: record)) {
                Label("분석 리포트 텍스트 공유", systemImage: "doc.text")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            if let episode = record.episodeReport {
                ShareLink(item: EpisodeReportFormatter.reportText(for: episode)) {
                    Label("전사·쟁점 요약 공유", systemImage: "text.bubble")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            Button {
                UIPasteboard.general.string = SessionReportFormatter.reportText(record: record)
                copiedReport = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    copiedReport = false
                }
            } label: {
                Label(copiedReport ? "리포트를 복사했습니다" : "리포트 복사", systemImage: copiedReport ? "checkmark" : "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func fileCard(_ record: RecordingSessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("파일 정보")
                .font(.subheadline.weight(.semibold))

            metricRow("파일 이름", value: record.fileName)
            metricRow("파일 크기", value: recordingStore.fileSizeText(for: record.fileName))
            metricRow("보호 등급", value: "completeUnlessOpen")
            metricRow("파일 암호화", value: recordingStore.isFileProtected(record.fileName) ? "적용됨" : "확인 필요")
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func deleteButton(_ record: RecordingSessionRecord) -> some View {
        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            Label("녹음 삭제", systemImage: "trash")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
    }

    private func noteEditor(_ record: RecordingSessionRecord) -> some View {
        NavigationStack {
            Form {
                Section("메모") {
                    TextEditor(text: $draftNote)
                        .frame(minHeight: 140)
                }
            }
            .navigationTitle("녹음 메모")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { isEditingNote = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        recordingStore.updateNote(for: record.id, note: draftNote)
                        isEditingNote = false
                    }
                }
            }
        }
    }
}
