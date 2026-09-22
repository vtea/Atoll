import AppKit
import Carbon.HIToolbox
import Defaults
import KeyboardShortcuts
import SwiftUI

/// Captures key events in the focused control instead of letting the text input
/// system interpret them as characters (for example, Option-A as “å”).
struct AreaScreenshotShortcutRecorder: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var shortcut: KeyboardShortcuts.Shortcut?

    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.onShortcutChange = { shortcut in
            KeyboardShortcuts.setShortcut(shortcut, for: .clipboardAreaScreenshot)
            self.shortcut = shortcut
        }
        return button
    }

    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.isEnabled = isEnabled
        button.title = shortcut.map(String.init(describing:)) ?? String(localized: "Set Shortcut")
        button.toolTip = String(localized: "Click, then press a shortcut. Escape cancels; Delete clears it.")
    }

    final class ShortcutButton: NSButton {
        var onShortcutChange: ((KeyboardShortcuts.Shortcut?) -> Void)?
        private var recording = false

        override var acceptsFirstResponder: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            bezelStyle = .rounded
            target = self
            action = #selector(beginRecording)
            setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }

        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width = max(130, size.width)
            return size
        }

        @objc private func beginRecording() {
            recording = true
            KeyboardShortcuts.disable(.clipboardAreaScreenshot)
            window?.makeFirstResponder(self)
            title = String(localized: "Press shortcut…")
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            title = KeyboardShortcuts.getShortcut(for: .clipboardAreaScreenshot)
                .map(String.init(describing:)) ?? String(localized: "Set Shortcut")
            if Defaults[.enableShortcuts] && Defaults[.enableClipboardManager] {
                KeyboardShortcuts.enable(.clipboardAreaScreenshot)
            }
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return }

            if event.keyCode == kVK_Escape {
                recording = false
                window?.makeFirstResponder(nil)
                return
            }
            if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
                onShortcutChange?(nil)
                recording = false
                window?.makeFirstResponder(nil)
                return
            }

            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !modifiers.intersection([.command, .control, .option]).isEmpty,
                  let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
                NSSound.beep()
                return
            }

            onShortcutChange?(shortcut)
            recording = false
            window?.makeFirstResponder(nil)
        }
    }
}
