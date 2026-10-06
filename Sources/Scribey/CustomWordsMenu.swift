import AppKit

/// The "Custom Words" submenu: add a word, click a word to remove it, or open
/// the file for the alias/context-rule formats. Edits `daemon/custom_words.txt`
/// in place, keeping its comments; the daemon re-reads it on every
/// transcription, so changes apply on the next dictation.
final class CustomWordsMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let fileURL = DaemonProcess.daemonDirectory.appendingPathComponent("custom_words.txt")

    override init() {
        super.init()
        menu.delegate = self
    }

    /// Rebuilt on every open, so edits made in a text editor show up too.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let add = NSMenuItem(title: "Add Word…", action: #selector(addWord), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        menu.addItem(.separator())

        let words = entries()
        if words.isEmpty {
            let empty = NSMenuItem(title: "No custom words yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let hint = NSMenuItem(title: "Click a word to remove it", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            for word in words {
                let item = NSMenuItem(title: word, action: #selector(removeWord(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = word
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Word List…", action: #selector(openFile), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    // MARK: File

    private func lines() -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private func write(_ lines: [String]) {
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Scribey: failed to write \(fileURL.path): \(error)")
        }
    }

    /// Every line that isn't blank or a comment, i.e. what the daemon acts on.
    private func entries() -> [String] {
        lines()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: Actions

    @objc private func addWord() {
        let alert = NSAlert()
        alert.messageText = "Add a custom word"
        alert.informativeText = "Type it exactly how it should be spelled. For a known mishearing, use \"Word: mishearing1, mishearing2\"."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "RainFocus"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        // A menu-bar-only app isn't frontmost, so the alert wouldn't get key focus otherwise.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let word = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !word.hasPrefix("#") else { return }
        guard !entries().contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        write(lines() + [word])
        print("Scribey: added custom word \"\(word)\"")
    }

    @objc private func removeWord(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \"\(word)\"?"
        alert.informativeText = "Scribey will stop correcting to this spelling."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        write(lines().filter { $0.trimmingCharacters(in: .whitespaces) != word })
        print("Scribey: removed custom word \"\(word)\"")
    }

    @objc private func openFile() {
        NSWorkspace.shared.open(fileURL)
    }
}
