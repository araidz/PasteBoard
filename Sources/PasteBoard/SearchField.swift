import AppKit
import SwiftUI

struct SearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "/ to search…"
        field.setAccessibilityLabel("Search history")
        Self.disableTextAssistance(on: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        Self.disableTextAssistance(on: field)
        DispatchQueue.main.async { context.coordinator.updateFocus(of: field) }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.delegate = nil
    }

    private static func disableTextAssistance(on field: NSTextField) {
        field.isAutomaticTextCompletionEnabled = false
        if #available(macOS 15.2, *) { field.allowsWritingTools = false }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.enabledTextCheckingTypes = 0
        editor.inlinePredictionType = .no
        if #available(macOS 15.0, *) {
            editor.mathExpressionCompletionType = .no
            editor.writingToolsBehavior = .none
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            if let field = notification.object as? NSTextField {
                SearchField.disableTextAssistance(on: field)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func updateFocus(of field: NSTextField) {
            guard let window = field.window else { return }
            if parent.isFocused {
                if window.firstResponder !== field.currentEditor() {
                    window.makeFirstResponder(field)
                }
                SearchField.disableTextAssistance(on: field)
            } else if window.firstResponder === field.currentEditor() {
                window.makeFirstResponder(nil)
            }
        }
    }
}
