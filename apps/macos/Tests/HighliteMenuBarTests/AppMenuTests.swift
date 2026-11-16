import AppKit
import XCTest
@testable import HighliteMenuBar

final class AppMenuTests: XCTestCase {
    @MainActor
    func testEditingShortcutsUseTheFocusedResponder() throws {
        let menu = AppMenu.makeMainMenu()
        let editMenu = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "Edit" })
        XCTAssertTrue(editMenu.autoenablesItems)

        let commands: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", [.command]),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", [.command]),
            ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
            ("Paste", #selector(NSText.paste(_:)), "v", [.command]),
            ("Select All", #selector(NSText.selectAll(_:)), "a", [.command]),
        ]
        for (title, action, key, modifiers) in commands {
            let item = try XCTUnwrap(editMenu.item(withTitle: title))
            XCTAssertEqual(item.action, action)
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers)
            XCTAssertNil(item.target, "\(title) must use the responder chain, not bypass secure fields")
        }
    }

    @MainActor
    func testApplicationMenuSupportsGracefulQuit() throws {
        let menu = AppMenu.makeMainMenu()
        let applicationMenu = try XCTUnwrap(menu.items.first?.submenu)
        let quit = try XCTUnwrap(applicationMenu.item(withTitle: "Quit Highlite"))
        XCTAssertEqual(quit.action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, [.command])
        XCTAssertNil(quit.target)
    }
}
