import AppKit
import Foundation

@main
struct ApplicationMenuCheck {
    static func main() {
        let application = NSApplication.shared
        ApplicationMenu.install(on: application)

        guard let mainMenu = application.mainMenu,
              let editMenu = mainMenu.items
                .compactMap(\.submenu)
                .first(where: { $0.title == "编辑" }) else {
            preconditionFailure("Edit menu was not installed")
        }

        assertCommand(in: editMenu, title: "剪切", key: "x", action: #selector(NSText.cut(_:)))
        assertCommand(in: editMenu, title: "拷贝", key: "c", action: #selector(NSText.copy(_:)))
        assertCommand(in: editMenu, title: "粘贴", key: "v", action: #selector(NSText.paste(_:)))
        assertCommand(in: editMenu, title: "全选", key: "a", action: #selector(NSText.selectAll(_:)))

        print("Application menu checks passed")
    }

    private static func assertCommand(
        in menu: NSMenu,
        title: String,
        key: String,
        action: Selector
    ) {
        guard let item = menu.item(withTitle: title) else {
            preconditionFailure("Missing \(title) command")
        }
        precondition(item.keyEquivalent == key)
        precondition(item.keyEquivalentModifierMask.contains(.command))
        precondition(item.action == action)
    }
}
