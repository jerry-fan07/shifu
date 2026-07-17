import ApplicationServices
import Foundation

/// Thin wrappers over the C Accessibility API.
enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let raw: CFArray = attribute(element, kAXChildrenAttribute) else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return attribute(app, kAXFocusedWindowAttribute)
    }

    /// Roles whose values are visible text worth capturing. Secure fields are
    /// deliberately absent — their values are never read.
    private static let textRoles: Set<String> = [
        kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole,
    ]

    /// Breadth-first visible-text extraction from a window's AX tree
    /// (design.md §3.2 rung 2). Bounded by byte cap and node budget so a
    /// pathological tree can't make capture expensive.
    static func extractText(from window: AXUIElement, byteCap: Int, nodeBudget: Int = 1_500) -> String {
        var queue: [AXUIElement] = [window]
        var visited = 0
        var pieces: [String] = []
        var bytes = 0

        while !queue.isEmpty && visited < nodeBudget && bytes < byteCap {
            let element = queue.removeFirst()
            visited += 1

            guard let role: String = string(element, kAXRoleAttribute) else { continue }
            let subrole: String? = string(element, kAXSubroleAttribute)
            if subrole == kAXSecureTextFieldSubrole { continue }

            if textRoles.contains(role), let value: String = string(element, kAXValueAttribute),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces.append(value)
                bytes += value.utf8.count + 1
            }
            queue.append(contentsOf: children(element))
        }
        return pieces.joined(separator: "\n")
    }

    /// Finds the web area's URL in a browser window, if any.
    static func webAreaURL(in window: AXUIElement, nodeBudget: Int = 300) -> String? {
        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty && visited < nodeBudget {
            let element = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == "AXWebArea" {
                if let url: URL = attribute(element, "AXURL") { return url.absoluteString }
                if let str: String = attribute(element, "AXURL") { return str }
                return nil
            }
            queue.append(contentsOf: children(element))
        }
        return nil
    }
}
