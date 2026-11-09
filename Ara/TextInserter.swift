import AppKit
import Carbon.HIToolbox
import os

/// Types text into whichever app has focus by pasting it, then puts the
/// previous clipboard content back.
enum TextInserter {
    private static let logger = Logger(subsystem: "com.erikondra.Ara", category: "insert")

    /// Posting key events to other apps needs the Accessibility permission.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog that points to the Accessibility settings.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    enum Outcome {
        case pasted
        /// The text stays on the clipboard because the Accessibility permission is missing.
        case noPermission
        /// The text stays on the clipboard because no text field has the focus.
        case noTextField
        /// The focused app does not answer accessibility queries, so it is unknown whether the
        /// paste arrived.
        case pastedUnverified
        /// The field can be read but the text never showed up in it, so the paste was lost.
        case pasteFailed
    }

    private enum Focus {
        case textField
        case noTextField
        case unknown
    }

    static func insert(_ text: String) async -> Outcome {
        let pasteboard = NSPasteboard.general

        guard isTrusted else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .noPermission
        }

        // Nothing would receive the paste, so the clipboard is the only place the text can live.
        let focus = focusState()
        logFocus(focus)
        guard focus != .noTextField else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .noTextField
        }

        let previous = snapshot(of: pasteboard)
        let field = focusedElement()
        let before = field.flatMap(value(of:))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Clipboard managers skip entries carrying this marker (nspasteboard.org).
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        let changeCount = pasteboard.changeCount

        postCommandKey(kVK_ANSI_V)

        // The previous clipboard always comes back, so a picture copied before dictating is
        // still there afterwards. A lost paste can be repeated with the paste-again shortcut.
        let restorePrevious = {
            disarmUserPaste()
            // Something else was copied in the meantime; leave it alone.
            guard pasteboard.changeCount == changeCount else { return }
            restore(previous, to: pasteboard)
        }
        // A ⌘V the user presses before the restore would paste the dictation a second time,
        // so it brings the previous clipboard back first.
        armUserPaste(restorePrevious)

        guard focus == .textField, let field, let before else {
            Task {
                // The target app reads the clipboard when it handles the paste, which can lag behind the key event.
                // Some fields (such as an edit box in Warp) take well over 500 ms and then got the old clipboard.
                try? await Task.sleep(for: .milliseconds(1500))
                restorePrevious()
            }
            return .pastedUnverified
        }

        // Some fields (such as the message edit box in Claude) report the focus but drop the paste.
        let occurrences = before.components(separatedBy: text).count
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let now = value(of: field) else { continue }
            if now != before, now.components(separatedBy: text).count > occurrences {
                restorePrevious()
                return .pasted
            }
        }
        logger.notice("paste not seen in the field after 1.5 s")
        restorePrevious()
        return .pasteFailed
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var reference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &reference) == .success,
            let reference, CFGetTypeID(reference) == AXUIElementGetTypeID()
        else { return nil }
        return (reference as! AXUIElement)
    }

    private static func value(of element: AXUIElement) -> String? {
        var reference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &reference) == .success else {
            return nil
        }
        return reference as? String
    }

    /// Records where a paste goes, to trace fields that do not take it.
    private static func logFocus(_ focus: Focus) {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var reference: CFTypeRef?
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &reference) == .success,
            let reference, CFGetTypeID(reference) == AXUIElementGetTypeID()
        {
            let element = reference as! AXUIElement
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        }
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        logger.notice("focus \(String(describing: focus), privacy: .public) in \(app, privacy: .public): role \((role as? String) ?? "-", privacy: .public), subrole \((subrole as? String) ?? "-", privacy: .public), held modifiers \(flags, privacy: .public)")
    }

    /// Which kind of element has the focus. Apps that do not answer
    /// accessibility queries (such as Brave or Warp) are `.unknown`.
    private static func focusState() -> Focus {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &reference)
        if result == .noValue { return .noTextField }
        guard result == .success, let reference, CFGetTypeID(reference) == AXUIElementGetTypeID() else {
            return .unknown
        }
        let element = reference as! AXUIElement

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        // Browsers report the page itself when no field on it has the focus.
        if (role as? String) == "AXWebArea" { return .noTextField }
        let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        if let role = role as? String, textRoles.contains(role) { return .textField }

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return .textField
        }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success {
            return .textField
        }
        // A role that exists but is no text control, such as the desktop or a button.
        return role != nil ? .noTextField : .unknown
    }

    /// Copies whatever is selected in the focused app and puts the previous
    /// clipboard content back. Nil when nothing was selected or the copy did
    /// not arrive in time.
    static func copySelection() async -> String? {
        guard isTrusted else { return nil }
        let pasteboard = NSPasteboard.general
        let previous = snapshot(of: pasteboard)
        pasteboard.clearContents()
        let changeCount = pasteboard.changeCount

        postCommandKey(kVK_ANSI_C)

        var selection: String?
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            if pasteboard.changeCount != changeCount {
                selection = pasteboard.string(forType: .string)
                break
            }
        }
        restore(previous, to: pasteboard)
        return selection
    }

    /// Marks the key events Ara posts, so the tap below can tell them from the user's.
    private static let syntheticMarker: Int64 = 0x4172_6100
    private static var userPasteTap: CFMachPort?
    private static var userPasteSource: CFRunLoopSource?
    private static var onUserPaste: (() -> Void)?

    /// Calls `action` right before the user's next ⌘V reaches the focused app.
    private static func armUserPaste(_ action: @escaping () -> Void) {
        disarmUserPaste()
        onUserPaste = action
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        // An active tap holds the event until the callback returns, so the
        // clipboard is restored before the app reads it.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                MainActor.assumeIsolated {
                    TextInserter.handleTapEvent(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            logger.error("could not create the key tap for ⌘V")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        userPasteTap = tap
        userPasteSource = source
    }

    private static func handleTapEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userPasteTap { CGEvent.tapEnable(tap: userPasteTap, enable: true) }
            return
        }
        guard type == .keyDown,
            event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V),
            event.flags.contains(.maskCommand),
            event.getIntegerValueField(.eventSourceUserData) != syntheticMarker
        else { return }
        let action = onUserPaste
        disarmUserPaste()
        action?()
    }

    private static func disarmUserPaste() {
        onUserPaste = nil
        if let userPasteSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), userPasteSource, .commonModes)
        }
        if let userPasteTap {
            CGEvent.tapEnable(tap: userPasteTap, enable: false)
            CFMachPortInvalidate(userPasteTap)
        }
        userPasteTap = nil
        userPasteSource = nil
    }

    private static func postCommandKey(_ code: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keeps keys that are physically held (such as Option from the
        // shortcut) from mixing into the synthetic Cmd+V.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let key = CGKeyCode(code)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    private typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshot(of pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                contents[type] = item.data(forType: type)
            }
            return contents
        }
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
