import SwiftUI
import VoiceGuardCore

/// 녹음 구간의 음량 엔벨로프와 격양 구간 하이라이트를 그리는 타임라인 (SwiftUI Canvas).
struct AgitationTimelineView: View {
    let envelope: [Double]
    let bucketSeconds: Double
    let events: [AgitationEvent]
    let duration: TimeInterval
    var minimumDB: Double = -70
    var maximumDB: Double = 0
    var height: CGFloat = 132

    private var safeDuration: TimeInterval {
        max(0.5, duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                drawGrid(in: &context, size: size)
                drawEventBands(in: &context, size: size)
                drawEnvelope(in: &context, size: size)
            }
            .frame(height: height)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                Text("음량 · 격양 구간")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    legendDot(color: .red, text: "격양")
                    legendDot(color: .accentColor, text: "음량")
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }

            HStack {
                Text(SessionReportFormatter.timestampText(0))
                Spacer()
                Text(SessionReportFormatter.timestampText(safeDuration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color.opacity(0.7))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Canvas Drawing

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        for step in 1..<4 {
            let y = size.height * CGFloat(step) / 4.0
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(Color.secondary.opacity(0.15)), lineWidth: 0.5)
        }
    }

    private func drawEventBands(in context: inout GraphicsContext, size: CGSize) {
        for event in events {
            let startX = xPosition(for: event.startedAtOffset, width: size.width)
            let endX = xPosition(for: event.endedAtOffset, width: size.width)
            let width = max(2.0, endX - startX)
            let rect = CGRect(x: startX, y: 0, width: width, height: size.height)
            context.fill(Path(rect), with: .color(Color.red.opacity(0.16)))
        }
    }

    private func drawEnvelope(in context: inout GraphicsContext, size: CGSize) {
        guard envelope.count > 1 else { return }
        let span = max(1.0, maximumDB - minimumDB)
        var path = Path()

        for (index, db) in envelope.enumerated() {
            let seconds = Double(index) * bucketSeconds
            let x = xPosition(for: seconds, width: size.width)
            let clamped = min(maximumDB, max(minimumDB, db))
            let normalized = (clamped - minimumDB) / span
            let y = size.height - CGFloat(normalized) * (size.height - 12) - 6
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        context.stroke(path, with: .color(Color.accentColor), lineWidth: 1.5)
    }

    private func xPosition(for seconds: TimeInterval, width: CGFloat) -> CGFloat {
        let ratio = max(0.0, min(1.0, seconds / safeDuration))
        return CGFloat(ratio) * width
    }
}
