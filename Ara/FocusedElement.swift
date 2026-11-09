import ApplicationServices

/// Reads the element that has the keyboard focus in whichever app is in front.
nonisolated enum FocusedElement {
    /// The focused element, or nil when there is none or the app does not answer.
    static func current() -> AXUIElement? {
        lookup().element
    }

    /// The focused element and what the system answered. `.noValue` means
    /// nothing has the focus at all.
    static func lookup() -> (element: AXUIElement?, result: AXError) {
        let system = AXUIElementCreateSystemWide()
        // Never let an unresponsive app stall the caller.
        AXUIElementSetMessagingTimeout(system, 0.5)
        var reference: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &reference)
        guard result == .success, let reference, CFGetTypeID(reference) == AXUIElementGetTypeID() else {
            return (nil, result == .success ? .failure : result)
        }
        let element = reference as! AXUIElement
        return (element, .success)
    }

    static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var reference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &reference) == .success else {
            return nil
        }
        return reference as? String
    }

    /// The text in the element, or nil when the app does not expose it.
    static func value(of element: AXUIElement) -> String? {
        string(kAXValueAttribute, of: element)
    }
}
