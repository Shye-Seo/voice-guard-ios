import SwiftUI
import UIKit
import VoiceGuardCore

/// 전사·핵심 쟁점 요약 화면.
///
/// 녹음 파일을 온디바이스 음성 인식으로 전사한 뒤, 격양 타임라인과 매핑해
/// 핵심 쟁점 발언·키워드·타임라인 마커를 보여준다. 생성된 리포트는 녹음 인덱스에 저장된다.
struct EpisodeReportView: View {
    private enum Phase: Equatable {
        case idle
        case transcribing
        case ready
        case failed(String)
    }

    let recordID: UUID

    @EnvironmentObject private var recordingStore: RecordingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var phase: Phase = .idle
    @State private var report: EpisodeReport?
    @State private var availability: SpeechTranscriptionSupport.Availability = .needsPermission

    private var support: SpeechTranscriptionSupport {
        SpeechTranscriptionSupport()
    }

    private var record: RecordingSessionRecord? {
        recordingStore.record(with: recordID)
    }

    private var isWorking: Bool {
        phase == .transcribing
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let record {
                        statusBanner
                        summarySection(record)
                        keyClaimSection
                        keywordSection
                        markerSection
                        transcriptSection
                        privacyFooter
                    } else {
                        ContentUnavailableView(
                            "녹음을 찾을 수 없습니다",
                            systemImage: "waveform.slash",
                            description: Text("이미 삭제되었을 수 있습니다.")
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("전사 · 핵심 쟁점")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let report {
                        ShareLink(item: EpisodeReportFormatter.reportText(for: report)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await generate() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isWorking || record == nil)
                }
            }
        }
        .task {
            availability = support.availability
            if let stored = record?.episodeReport {
                apply(stored)
            } else {
                await generate()
            }
        }
    }

    // MARK: - 상태

    @ViewBuilder
    private var statusBanner: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("기기 안에서 전사하는 중입니다")
                        .font(.subheadline.weight(.semibold))
                    Text("음성 인식과 요약은 모두 온디바이스에서 처리됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if availability == .needsPermission {
                        Button("음성 인식 허용") {
                            Task {
                                _ = await SpeechTranscriptionSupport.requestPermission()
                                availability = support.availability
                                await generate()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.caption)
                    }
                    if availability == .denied || availability == .restricted {
                        Button("설정 열기") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                    Button("다시 시도") {
                        Task { await generate() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        case .ready:
            if let report, !report.hasTranscript {
                Label(
                    "이 녹음에서는 발화를 찾지 못했습니다. 격양 타임라인만 표시합니다.",
                    systemImage: "text.bubble"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 요약 카드

    @ViewBuilder
    private func summarySection(_ record: RecordingSessionRecord) -> some View {
        if let summary = report?.summary {
            VStack(alignment: .leading, spacing: 12) {
                Text("핵심 쟁점 요약")
                    .font(.headline)

                Text(summary.headline)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(spacing: 18) {
                    statItem("발화", value: EpisodeReportFormatter.durationText(summary.speechSeconds))
                    statItem("격양 중 발화", value: EpisodeReportFormatter.durationText(summary.agitatedSpeechSeconds))
                    statItem("격양 구간", value: "\(summary.agitationEventCount)회")
                }

                Text("엔진: \(summary.engineName) · 생성 \(SessionReportFormatter.dateText(summary.generatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        } else if phase == .idle {
            VStack(alignment: .leading, spacing: 8) {
                Text("아직 요약이 없습니다")
                    .font(.subheadline.weight(.semibold))
                Text("녹음 \(EpisodeReportFormatter.durationText(record.durationSeconds)) · 격양 \(record.agitationEvents.count)구간")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("전사 · 요약 시작") {
                    Task { await generate() }
                }
                .buttonStyle(.borderedProminent)
                .font(.caption)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func statItem(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }

    // MARK: - 핵심 발언

    @ViewBuilder
    private var keyClaimSection: some View {
        if let keyClaim = report?.summary.keyClaim {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "quote.opening")
                        .foregroundStyle(.red)
                    Text(keyClaim.isNearestFallback ? "격양 구간 근처 핵심 발언" : "가장 격양이 심했던 발언")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("격양도 \(Int((keyClaim.peakAgitationScore * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.red)
                }

                Text("「\(keyClaim.text)」")
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(SessionReportFormatter.timestampText(keyClaim.startedAtOffset))
                    Text("~")
                    Text(SessionReportFormatter.timestampText(keyClaim.endedAtOffset))
                    if let index = keyClaim.eventIndex {
                        Text("· 격양 구간 \(index + 1)")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
            )
        }
    }

    // MARK: - 키워드

    @ViewBuilder
    private var keywordSection: some View {
        if let keywords = report?.summary.keywords, !keywords.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("반복 키워드")
                    .font(.subheadline.weight(.semibold))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(keywords) { keyword in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(keyword.term)
                                    .font(.caption.weight(.semibold))
                                Text("\(keyword.count)회 · 가중 \(String(format: "%.1f", keyword.weight))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - 타임라인 마커

    @ViewBuilder
    private var markerSection: some View {
        if let markers = report?.summary.markers, !markers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("타임라인 마커")
                    .font(.subheadline.weight(.semibold))

                ForEach(markers) { marker in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: marker.kind == .keyClaim ? "quote.bubble.fill" : "waveform.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(marker.kind == .keyClaim ? Color.red : Color.orange)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(SessionReportFormatter.timestampText(marker.offset))
                                .font(.caption.monospacedDigit().weight(.semibold))
                            Text(marker.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if marker.agitationScore > 0 {
                            Text("\(Int((marker.agitationScore * 100).rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - 전사 타임라인

    @ViewBuilder
    private var transcriptSection: some View {
        if let transcript = report?.transcript, !transcript.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("전사 타임라인")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(transcript.count)구간")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ForEach(transcript) { segment in
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle()
                            .fill(segment.isAgitated ? Color.red : Color.clear)
                            .frame(width: 3)
                            .clipShape(Capsule())

                        Text(SessionReportFormatter.timestampText(segment.startedAtOffset))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)

                        Text(segment.text)
                            .font(.footnote)
                            .fontWeight(segment.isAgitated ? .semibold : .regular)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var privacyFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("온디바이스 처리", systemImage: "lock.shield")
                .font(.caption.weight(.semibold))
            Text("음성 인식·요약은 기기 내부에서만 수행되고 오디오·텍스트는 서버로 전송되지 않습니다. 리포트는 녹음함과 같은 \(RecordingStore.fileProtection.rawValue) 등급으로 저장됩니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 실행

    private func apply(_ stored: EpisodeReport) {
        report = stored
        phase = .ready
    }

    /// 전사 → 격양 타임라인 매핑 → 요약 → 인덱스 저장.
    private func generate() async {
        guard let record else { return }

        let support = SpeechTranscriptionSupport()
        availability = support.availability
        if availability == .needsPermission {
            _ = await SpeechTranscriptionSupport.requestPermission()
            availability = support.availability
        }

        report = nil
        phase = .transcribing

        let transcriber = support.makeTranscriber()
        let fileURL = recordingStore.fileURL(for: record.fileName)

        do {
            let segments = try await transcriber.transcribe(audioFileURL: fileURL)
            let generated = EpisodeSummarizer().makeReport(
                record: record,
                segments: segments,
                engineName: transcriber.engineName
            )
            report = generated
            phase = .ready
            recordingStore.updateEpisodeReport(for: record.id, report: generated)
        } catch let error as SpeechTranscriptionError {
            phase = .failed(error.message)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
