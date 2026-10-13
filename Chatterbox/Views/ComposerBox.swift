import AppKit
import SwiftUI

/// The message box: a real text view in its own scroll view, which grows with what you type
/// (up to `maxHeight`, then scrolls). SwiftUI's growing TextField draws through AppKit's
/// field editor, which on macOS can leave the previous layout on screen under the new one
/// when the box wraps or scrolls, so the text shows twice. A text view of its own doesn't.
struct ComposerBox: View {
    /// `digit`: 0–9 typed into an empty box (Next Steps picks a suggestion with these).
    enum Key: Equatable { case `return`, up, down, tab, escape, digit(Int) }

    @Binding var text: String
    var placeholder: String
    @Binding var isFocused: Bool
    var font: NSFont = .preferredFont(forTextStyle: .body)
    /// Taller content scrolls inside the box.
    var maxHeight: CGFloat
    /// Keys the chat wants first (the "/" menu, ⌘↩). Return true to take the key; Return not
    /// taken sends the message, Shift- or Option-Return always starts a new line.
    var onKey: (Key, NSEvent.ModifierFlags) -> Bool = { _, _ in false }
    var onSubmit: () -> Void

    var body: some View {
        // Sizes itself from the width it's offered, in one step (see sizeThatFits). Measuring
        // after layout and resizing again could chase its own width and shake.
        ComposerTextView(text: $text, placeholder: placeholder, isFocused: $isFocused, font: font,
                         maxHeight: maxHeight, onKey: onKey, onSubmit: onSubmit)
            .accessibilityLabel("Message")
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFocused: Bool
    var font: NSFont
    var maxHeight: CGFloat
    var onKey: (ComposerBox.Key, NSEvent.ModifierFlags) -> Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none

        let view = TextView()
        view.coordinator = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticLinkDetectionEnabled = false
        view.usesFontPanel = false
        view.font = font
        view.textColor = .labelColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.string = text
        view.placeholder = placeholder
        view.setAccessibilityLabel("Message")
        scroll.documentView = view
        context.coordinator.view = view
        return scroll
    }

    /// The text's height at the offered width, up to `maxHeight` (then it scrolls); one line
    /// at least. Worked out from the width alone, so the same width always gets the same height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let line = ceil(font.ascender - font.descender + font.leading)
        let height = context.coordinator.textHeight(text, font: font, width: width)
        return CGSize(width: width, height: min(max(height, line), maxHeight))
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = coordinator.view else { return }
        if view.string != text {
            // Set from outside (sent, a slash command completed, another chat's draft): keep
            // undo sane and put the caret at the end.
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if view.placeholder != placeholder { view.placeholder = placeholder; view.needsDisplay = true }
        if view.font != font { view.font = font }
        if isFocused, view.window != nil, view.window?.firstResponder !== view {
            // Asked for focus from SwiftUI (a chat opened, a file was added): take it once the
            // view is in its window. Doing it during an update can re-enter layout.
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let coordinator, coordinator.active, coordinator.parent.isFocused,
                      let view, let window = view.window, window.firstResponder !== view else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.active = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var view: TextView?
        var active = true
        /// Its own text system for measuring, so measuring never touches what's on screen.
        private let measureStorage = NSTextStorage()
        private let measureLayout = NSLayoutManager()
        private let measureContainer = NSTextContainer()
        private var measured: (text: String, font: NSFont, width: CGFloat, height: CGFloat)?

        init(_ parent: ComposerTextView) {
            self.parent = parent
            super.init()
            measureContainer.lineFragmentPadding = 0
            measureLayout.addTextContainer(measureContainer)
            measureStorage.addLayoutManager(measureLayout)
        }

        func textDidChange(_ notification: Notification) {
            guard active, let view else { return }
            // The new text re-renders the box, which asks sizeThatFits for its new height.
            if parent.text != view.string { parent.text = view.string }
        }

        /// How tall `text` lays out at `width`, as the text view lays it out (a trailing new
        /// line counts). The last answer is kept: layout asks the same question often.
        func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
            if let measured, measured.text == text, measured.font == font, abs(measured.width - width) < 0.5 { return measured.height }
            measureContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            measureStorage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            measureLayout.ensureLayout(for: measureContainer)
            let height = ceil(measureLayout.usedRect(for: measureContainer).height)
            measured = (text, font, width, height)
            return height
        }

        func focusChanged(_ focused: Bool) {
            guard active else { return }
            if parent.isFocused != focused { parent.isFocused = focused }
        }

        /// Keys the box treats specially; false lets the text view handle the key as usual.
        func handle(_ key: ComposerBox.Key, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            if parent.onKey(key, modifiers) { return true }
            switch key {
            case .return:
                parent.onSubmit()
                return true
            case .tab, .escape:
                // Not a tab character; and Esc shouldn't open the text view's completions.
                return true
            case .up, .down, .digit:
                return false
            }
        }
    }

    final class TextView: NSTextView {
        weak var coordinator: Coordinator?
        var placeholder = ""

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key: ComposerBox.Key?
            switch event.keyCode {
            case 36, 76: key = modifiers.contains(.shift) || modifiers.contains(.option) ? nil : .return   // Return, Enter
            case 126: key = .up
            case 125: key = .down
            case 48: key = .tab
            case 53: key = .escape
            default:
                if string.isEmpty, modifiers.isEmpty, let character = event.characters, character.count == 1,
                   let digit = Int(character) { key = .digit(digit) } else { key = nil }
            }
            if let key, coordinator?.handle(key, modifiers) == true { return }
            super.keyDown(with: event)
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { coordinator?.focusChanged(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { coordinator?.focusChanged(false) }
            return resigned
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty, let font else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.placeholderTextColor]
            placeholder.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attributes)
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true
        }
    }
}
