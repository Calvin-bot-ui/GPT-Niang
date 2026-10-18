import XCTest
@testable import GPTNiangCore

final class BusinessAndLanguageTests: XCTestCase {
    func testCharacterClickActionsCycleQuotaQuoteChat() {
        XCTAssertEqual(CharacterAction.quota.next, .quote)
        XCTAssertEqual(CharacterAction.quote.next, .chat)
        XCTAssertEqual(CharacterAction.chat.next, .quota)
        XCTAssertTrue(CharacterAction.quota.closesChatWindow)
        XCTAssertTrue(CharacterAction.quote.closesChatWindow)
        XCTAssertFalse(CharacterAction.chat.closesChatWindow)
        XCTAssertEqual(CharacterAction.allCases.map(\.title), ["查看额度", "查看语录", "打开聊天"])
    }

    func testProactiveChatPolicyEnforcesIdleIntervalDailyCapQuietHoursAndQuotaSafety() {
        XCTAssertTrue(ProactiveChatPolicy.isQuietTime(minuteOfDay: 23 * 60, start: 23 * 60, end: 8 * 60))
        XCTAssertTrue(ProactiveChatPolicy.isQuietTime(minuteOfDay: 7 * 60 + 59, start: 23 * 60, end: 8 * 60))
        XCTAssertFalse(ProactiveChatPolicy.isQuietTime(minuteOfDay: 8 * 60, start: 23 * 60, end: 8 * 60))
        XCTAssertFalse(ProactiveChatPolicy.quotaIsSafe(remaining: [100, 15], verified: true))
        XCTAssertFalse(ProactiveChatPolicy.quotaIsSafe(remaining: [100], verified: false))
        XCTAssertTrue(ProactiveChatPolicy.quotaIsSafe(remaining: [100, 15.1], verified: true))
        let ready: (Int, TimeInterval?, Int, Bool) -> Bool = { count, sinceLast, minute, quota in
            ProactiveChatPolicy.shouldSend(enabled: true, dailyCount: count, dailyLimit: 4, idleFor: 1800,
                                           sinceLastMessage: sinceLast, minuteOfDay: minute, quietStart: 1380,
                                           quietEnd: 480, quotaSafe: quota, chatBusy: false, chatVisible: false,
                                           settingsVisible: false, speedVisible: false)
        }
        XCTAssertTrue(ready(0, nil, 12 * 60, true))
        XCTAssertTrue(ready(3, nil, 12 * 60, true))
        XCTAssertFalse(ready(4, nil, 12 * 60, true))
        XCTAssertFalse(ready(0, 1799, 12 * 60, true))
        XCTAssertFalse(ready(0, nil, 12 * 60, false))
        XCTAssertFalse(ready(0, nil, 23 * 60 + 5, true))
    }

    func testWeightedEditorRoundTripAndInvalidWeights() {
        let quotes = [Quote(text: "繁體語錄", weight: 3.5), Quote(text: "A | B")]
        XCTAssertEqual(QuoteFile.editorQuotes(QuoteFile.editorText(quotes)), quotes)
        XCTAssertFalse(QuoteFile.editorQuotes("0 | 无效")[0].valid)
        XCTAssertFalse(QuoteFile.editorQuotes("1001 | 无效")[0].valid)
    }
    func testDesktopClampingKeepsSecondaryDisplayAndRecoversOffscreen() {
        let area = CGRect(x: -1440, y: 40, width: 1440, height: 860)
        let size = CGSize(width: 378, height: 378)
        let frame = WidgetPlacement.desktopFrame(area: area, size: size, origin: CGPoint(x: -1000, y: 200))
        XCTAssertEqual(frame.origin, CGPoint(x: -1000, y: 200))
        XCTAssertEqual(frame.size, size)
        let recovered = WidgetPlacement.desktopFrame(area: area, size: size, origin: CGPoint(x: -9000, y: 9000))
        XCTAssertTrue(area.contains(recovered)); XCTAssertEqual(recovered.size, size)
    }
    func testBusinessPersonalAndTimedWindowsDecodeTogether() throws {
        let json = #"{"ok":true,"queryOk":true,"planLabel":"Business","windows":[{"kind":"individual","minutes":null,"remaining":0,"total":4000,"amountUsed":4000,"amountRemaining":0},{"minutes":10080,"remaining":4},{"minutes":300,"remaining":65}]}"#
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.validWindows.count, 3)
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["individual", "time:300"])
        XCTAssertEqual(snapshot.displayWindows[0].title(language: .simplified), "个人额度")
        XCTAssertEqual(snapshot.displayWindows[0].title(language: .traditional), "個人額度")
        XCTAssertEqual(snapshot.displayWindows[0].remaining, 0)
        XCTAssertEqual(snapshot.displayWindows[0].amountRemaining, 0)
        XCTAssertEqual(snapshot.validWindows.last?.minutes, 300)
        XCTAssertTrue(snapshot.stale(at: Date(timeIntervalSince1970: 1)))
    }
    func testInvalidAndDuplicateWindowsDoNotReachPercentageRendering() {
        let snapshot = UsageSnapshot(windows: [
            QuotaWindow(minutes: nil, remaining: 50), QuotaWindow(minutes: 0, remaining: 50),
            QuotaWindow(minutes: 300, remaining: .nan), QuotaWindow(minutes: 300, remaining: 101),
            QuotaWindow(minutes: 300, remaining: -1), QuotaWindow(minutes: 300, remaining: 20),
            QuotaWindow(minutes: 300, remaining: 30), QuotaWindow(remaining: 40, kind: "individual")
        ])
        XCTAssertEqual(snapshot.validWindows.count, 2)
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["individual", "time:300"])
        XCTAssertEqual(snapshot.displayWindows.last?.remaining, 20)
        let timed = UsageSnapshot(windows: [QuotaWindow(minutes: 60, remaining: 1), QuotaWindow(minutes: 300, remaining: 48.5), QuotaWindow(minutes: 10080, remaining: 50)])
        XCTAssertEqual(timed.displayWindows.map(\.id), ["time:300", "time:10080"])
        XCTAssertEqual(timed.displayWindows[0].percentageText, "48.5")
        XCTAssertEqual(timed.displayWindows[1].percentageText, "50")
    }
    func testSystemSelectionAndFormattingPreserveArguments() {
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferredLanguages: ["zh-TW"]), .traditional)
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferredLanguages: ["zh-Hant-HK"]), .traditional)
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN"]), .simplified)
        XCTAssertEqual(InterfaceLanguage.system.resolved(preferredLanguages: ["en-US"]), .simplified)
        XCTAssertEqual(InterfaceLanguage.traditional.resolved(preferredLanguages: ["zh-CN"]), .traditional)
        XCTAssertEqual(InterfaceLanguage.simplified.text("跟隨 Codex 主視窗"), "跟随 Codex 主窗口")
        XCTAssertEqual(InterfaceLanguage.traditional.text("始终置顶"), "始終置頂")
        let quote = "使用者：繁體語錄 100% / C:/讀取資料"
        XCTAssertEqual(InterfaceLanguage.simplified.text("目前方案：%@", quote), "目前方案：" + quote)
        XCTAssertEqual(QuotaWindow(minutes: 300, remaining: 50).resetText(at: Date(timeIntervalSince1970: 0), language: .simplified), "未提供重置时间")
    }
}
