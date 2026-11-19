import Foundation

public struct RecordingSessionRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let fileName: String
    public let startedAt: Date
    public var endedAt: Date
    public var durationSeconds: TimeInterval
    public var peakAgitationScore: Double
    public var triggerReason: String
    public var note: String
    public var isStarred: Bool

    public init(
        id: UUID = UUID(),
        fileName: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        peakAgitationScore: Double,
        triggerReason: String,
        note: String = "",
        isStarred: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.peakAgitationScore = peakAgitationScore
        self.triggerReason = triggerReason
        self.note = note
        self.isStarred = isStarred
    }
}
