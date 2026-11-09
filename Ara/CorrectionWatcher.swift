import ApplicationServices
import Foundation

/// Watches the text field a dictation was pasted into, to see how the user
/// edits it. The field's text is only compared in memory and never stored.
nonisolated enum CorrectionWatcher {
    private static let pollInterval = Duration.milliseconds(500)
    /// The text must stay unchanged for this many polls before an edit is
    /// reported, so a half-typed word is not taken for a correction.
    private static let pollsUntilSettled = 3

    /// Calls `onEdit` with the pasted span each time the user has edited it
    /// and then paused, and once more with the last state when watching ends.
    ///
    /// Returns the span as the user left it, or nil when the field cannot be
    /// read (some apps do not expose their text to accessibility).
    ///
    /// Watching ends after `duration`, when the pasted span is gone, or when
    /// the task is cancelled because the next dictation starts. It pauses
    /// while the focus is elsewhere, so the right spelling can be copied
    /// from another window and pasted over the wrong one.
    @concurrent
    static func observe(
        inserted: String,
        for duration: Duration = .seconds(120),
        onEdit: @MainActor @Sendable (String) -> Void
    ) async -> String? {
        // The paste needs a moment to land, and slow apps need a few tries.
        var located: (element: AXUIElement, prefix: String, suffix: String)?
        for _ in 0..<4 {
            guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return nil }
            guard let element = focusedElement(), let text = value(of: element),
                // The cursor is usually at the end, so prefer the last match.
                let range = text.range(of: inserted, options: .backwards)
            else { continue }
            located = (element, String(text[..<range.lowerBound]), String(text[range.upperBound...]))
            break
        }
        guard let (element, prefix, suffix) = located else { return nil }

        var last = inserted
        var reported = inserted
        var unchangedPolls = 0
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            guard (try? await Task.sleep(for: pollInterval)) != nil else { break }
            guard let focused = focusedElement(), CFEqual(focused, element) else {
                // Leaving the field ends an edit just like a pause does.
                if last != reported {
                    reported = last
                    await onEdit(last)
                }
                continue
            }
            guard let text = value(of: element) else { break }

            // Only the pasted span is of interest. It is whatever sits
            // between the text that surrounded it when it was pasted.
            guard text.count >= prefix.count + suffix.count, text.hasPrefix(prefix), text.hasSuffix(suffix) else { break }
            let span = String(text.dropFirst(prefix.count).dropLast(suffix.count))
            // A field emptied by sending the message says nothing about corrections.
            guard !span.isEmpty else { break }

            if span == last {
                unchangedPolls += 1
            } else {
                last = span
                unchangedPolls = 0
            }
            if unchangedPolls >= pollsUntilSettled, last != reported {
                reported = last
                await onEdit(last)
            }
        }

        // An edit made just before watching ended has not been reported yet.
        if last != reported {
            await onEdit(last)
        }
        return last
    }

    private static func focusedElement() -> AXUIElement? {
        FocusedElement.current()
    }

    private static func value(of element: AXUIElement) -> String? {
        FocusedElement.value(of: element)
    }
}
