import XCTest
import AppKit
import GPTNiangCore
@testable import GPTNiangMac

final class NativeInteractionTests: XCTestCase {
    func testPersonaEditorMapsStructuredFieldsAndListLines() {
        let draft = PersonaDraft.from(["name": "小星", "personality": ["温柔", "耐心"], "instructions": "补充要求"])
        XCTAssertEqual(draft.name, "小星")
        XCTAssertEqual(draft.personality, "温柔\n耐心")
        XCTAssertEqual(draft.additionalInstructions, "补充要求")
        let saved = draft.json()
        XCTAssertEqual(saved["personality"] as? [String], ["温柔", "耐心"])
        XCTAssertEqual(saved["additionalInstructions"] as? String, "补充要求")
    }

    @MainActor func testCharacterClickCycleStartsAtQuotaThenReturnsAfterChat() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let model = WidgetModel(dataDirectory: data, resources: data)
        XCTAssertNil(model.characterAction)
        XCTAssertEqual(model.advanceCharacterAction(), .quota)
        XCTAssertEqual(model.characterAction, .quota)
        XCTAssertEqual(model.advanceCharacterAction(), .quote)
        XCTAssertEqual(model.advanceCharacterAction(), .chat)
        XCTAssertEqual(model.advanceCharacterAction(), .quota)
    }

    @MainActor func testLegacyDesktopPositionMigratesOnceWithoutLosingFollowOrUnknownPreferences() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        let file = data.appendingPathComponent("preferences.json")
        try Data(#"{"followCodex":false,"x":0.25,"y":0.75,"scale":1.4,"volume":0.4,"futurePreference":"preserve"}"#.utf8).write(to: file)
        let model = WidgetModel(dataDirectory: data, resources: data)
        XCTAssertTrue(model.desktopNeedsMigration)
        let area = CGRect(x: -1200, y: 40, width: 1200, height: 800), size = CGSize(width: 529.2, height: 529.2)
        let expected = WidgetPlacement.frame(host: area, visibleScreen: area, size: size, x: 0.25, y: 0.75)
        model.migrateDesktopPosition(area: area, size: size)
        XCTAssertEqual(model.desktopLeft, expected.minX); XCTAssertEqual(model.desktopBottom, expected.minY)
        let restored = WidgetModel(dataDirectory: data, resources: data)
        XCTAssertFalse(restored.desktopNeedsMigration); XCTAssertEqual(restored.x, 0.25); XCTAssertEqual(restored.y, 0.75)
        XCTAssertEqual(restored.volume, 0.4); XCTAssertEqual(restored.scale, 1.4)
        restored.migrateDesktopPosition(area: CGRect(x: 0, y: 0, width: 1920, height: 1080), size: size)
        XCTAssertEqual(restored.desktopLeft, expected.minX)
        let values = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(values?["futurePreference"] as? String, "preserve")
    }
    @MainActor func testNativeDragMovesPanelWithoutResizingOrClicking() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 378, height: 378),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let view = CharacterInteraction.PointerView(frame: CGRect(x: 0, y: 0, width: 378, height: 378))
        panel.contentView = view
        defer { panel.close() }
        let original = panel.frame
        var clicks = 0, menus = 0, completed = false
        view.onClick = { clicks += 1 }; view.onMenu = { _, _ in menus += 1 }
        view.onDrag = { delta in
            if delta == .zero { completed = true }
            else { panel.setFrameOrigin(CGPoint(x: original.minX+delta.width, y: original.minY-delta.height)) }
        }
        func event(_ type: NSEvent.EventType, _ location: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 0)!
        }
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 10, y: 10)))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 20, y: 25)))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 20, y: 25)))
        XCTAssertEqual(panel.frame.size, original.size)
        XCTAssertEqual(panel.frame.origin, CGPoint(x: original.minX+10, y: original.minY+15))
        XCTAssertTrue(completed); XCTAssertEqual(clicks, 0); XCTAssertEqual(menus, 0)
    }
    @MainActor func testRefreshAndCharacterActionsFollowWindowsBubbleSequence() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let model = WidgetModel(dataDirectory: data, resources: data)
        model.refresh(); XCTAssertFalse(model.bubble)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("refresh.flag").path))
        model.characterClick(); XCTAssertTrue(model.bubble); XCTAssertNil(model.message)
        model.sceneStarted = .distantPast
        model.refresh(); XCTAssertEqual(model.sceneStarted, .distantPast)
        model.refresh(renewBubble: true); XCTAssertNotEqual(model.sceneStarted, .distantPast)
        model.clickBubble(); XCTAssertNotNil(model.message)
        model.characterClick(); XCTAssertNil(model.message); XCTAssertTrue(model.bubble)
        model.bubbleTapAdvance = true
        model.characterClick(); XCTAssertNotNil(model.message)
        model.characterClick(); XCTAssertFalse(model.bubble)
        model.refreshing = false; model.interactionActive = true; XCTAssertFalse(model.updateIdle)
        model.interactionActive = false; XCTAssertTrue(model.updateIdle)
    }
    @MainActor func testResetQuotesBacksUpWeightedCustomData() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let model = WidgetModel(dataDirectory: data, resources: data)
        model.quoteText = "3 | 我的繁體語錄"; model.saveQuotes()
        let file = data.appendingPathComponent("quotes.json")
        let original = try Data(contentsOf: file)
        model.resetQuotes()
        XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("quotes.json.bak")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    @MainActor func testEveryClickCountPreservesFeedbackAndRightClickMenu() async throws {
        let view = CharacterInteraction.PointerView()
        var clicks = 0, settings = 0, presses: [Bool] = []
        view.onClick = { clicks += 1 }; view.onMenu = { _, _ in settings += 1 }; view.onPress = { presses.append($0) }
        for count in 1...4 {
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 0)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 0)!
            view.mouseDown(with: down); view.mouseUp(with: up)
        }
        XCTAssertEqual(clicks, 4); XCTAssertEqual(settings, 0)
        XCTAssertEqual(presses, [true, false, true, false, true, false, true, false])
        let right = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        view.rightMouseDown(with: right); XCTAssertEqual(settings, 1)
    }
    @MainActor func testNativeDisplayPreferencesRoundTripPreservesQuotes() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let model = WidgetModel(dataDirectory: data, resources: data)
        XCTAssertEqual(model.language, .system)
        model.language = .simplified
        model.desktopTopmost = true; model.desktopLeft = -500; model.desktopBottom = 200; model.soundOn = false; model.hideMenu = true
        model.specialQuotes = "我的繁體語錄"; model.volume = 0.4; model.followCodex = false
        model.savePreferences()
        let restored = WidgetModel(dataDirectory: data, resources: data)
        XCTAssertEqual(restored.language, .simplified)
        XCTAssertEqual(restored.specialQuotes, "我的繁體語錄"); XCTAssertEqual(restored.volume, 0.4)
        XCTAssertFalse(restored.followCodex)
        XCTAssertTrue(restored.desktopTopmost); XCTAssertEqual(restored.desktopLeft, -500)
        XCTAssertEqual(restored.desktopBottom, 200); XCTAssertFalse(restored.soundOn); XCTAssertTrue(restored.hideMenu)
    }
    @MainActor func testMalformedSnapshotClearsPreviousBusinessAccount() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let model = WidgetModel(dataDirectory: data, resources: data)
        let file = data.appendingPathComponent("status.json")
        try Data(#"{"ok":true,"planLabel":"Business","windows":[{"kind":"individual","minutes":null,"remaining":48}]}"#.utf8).write(to: file)
        model.readSnapshot(try Data(contentsOf: file)); XCTAssertEqual(model.snapshot.displayWindows.first?.id, "individual")
        try Data("broken".utf8).write(to: file)
        model.readSnapshot(try Data(contentsOf: file)); XCTAssertTrue(model.snapshot.windows.isEmpty); XCTAssertNil(model.snapshot.planLabel)
        XCTAssertNotNil(model.snapshot.error)
        model.stop()
    }
    @MainActor func testNativeSingleDoubleAndRightClickRoutes() async throws {
        // Detached view events exercise routing without posting OS input.
        let view = CharacterInteraction.PointerView()
        var clicks = 0, settings = 0
        var presses: [Bool] = []
        view.onClick = { clicks += 1 }; view.onMenu = { _, _ in settings += 1 }
        view.onPress = { presses.append($0) }
        func event(_ type: NSEvent.EventType, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0)!
        }
        view.mouseDown(with: event(.leftMouseDown, clicks: 1)); view.mouseUp(with: event(.leftMouseUp, clicks: 1))
        XCTAssertEqual(clicks, 1); XCTAssertEqual(settings, 0); XCTAssertEqual(presses, [true, false])
        view.mouseDown(with: event(.leftMouseDown, clicks: 2)); view.mouseUp(with: event(.leftMouseUp, clicks: 2))
        XCTAssertEqual(settings, 0); XCTAssertEqual(clicks, 2)
        view.rightMouseDown(with: event(.rightMouseDown, clicks: 1)); XCTAssertEqual(settings, 1)
    }
    @MainActor func testSpeedHelperEOFMarksStoppedAndCanRestart() async throws {
        let store = ThreadSpeedStore()
        store.start(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        for _ in 0..<30 {
            if store.error != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.rows.isEmpty)
        store.start(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        XCTAssertNil(store.error)
        store.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        // A callback from the previous helper must not clear a new run's state.
        XCTAssertNil(store.error)
    }
}
