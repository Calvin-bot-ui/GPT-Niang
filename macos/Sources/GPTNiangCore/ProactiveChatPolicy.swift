import Foundation

public enum ProactiveChatPolicy {
    public static let minimumInterval: TimeInterval = 30 * 60
    public static let minimumIdle: TimeInterval = 30 * 60
    public static let quotaPauseThreshold = 15.0

    public static func isQuietTime(minuteOfDay: Int, start: Int, end: Int) -> Bool {
        guard (0..<1440).contains(minuteOfDay), (0..<1440).contains(start), (0..<1440).contains(end), start != end else { return false }
        return start < end ? (minuteOfDay >= start && minuteOfDay < end) : (minuteOfDay >= start || minuteOfDay < end)
    }

    public static func quotaIsSafe(remaining: [Double], verified: Bool) -> Bool {
        verified && !remaining.isEmpty && remaining.allSatisfy { $0.isFinite && $0 > quotaPauseThreshold }
    }

    public static func shouldSend(enabled: Bool, dailyCount: Int, dailyLimit: Int, idleFor: TimeInterval,
                                  sinceLastMessage: TimeInterval?, minuteOfDay: Int, quietStart: Int,
                                  quietEnd: Int, quotaSafe: Bool, chatBusy: Bool, chatVisible: Bool,
                                  settingsVisible: Bool, speedVisible: Bool) -> Bool {
        guard enabled, dailyCount < dailyLimit, idleFor >= minimumIdle,
              sinceLastMessage == nil || sinceLastMessage! >= minimumInterval,
              !isQuietTime(minuteOfDay: minuteOfDay, start: quietStart, end: quietEnd),
              quotaSafe, !chatBusy, !chatVisible, !settingsVisible, !speedVisible else { return false }
        return true
    }
}
