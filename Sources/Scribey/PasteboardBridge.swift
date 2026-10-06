import AppKit

enum PasteboardBridge {
    private static let restoreDelay: TimeInterval = 0.4

    static func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let savedItems = capturePasteboardItems(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendKeystroke(keyCode: CGKeyCode(kVK_ANSI_V))

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            pasteboard.clearContents()
            if !savedItems.isEmpty {
                pasteboard.writeObjects(savedItems)
            }
        }
    }

    private static func capturePasteboardItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func sendKeystroke(keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

private let kVK_ANSI_V: Int = 0x09
