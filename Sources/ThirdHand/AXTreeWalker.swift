import ApplicationServices
import Foundation

enum AXTreeWalker {
    static func walk(target: AppTarget, timeBudget: TimeInterval = 0.8) -> [AccessibilityElement] {
        var elements: [AccessibilityElement] = []
        var nextId = 1
        var visited = 0
        var rows = RowTexts()
        let deadline = Date().addingTimeInterval(timeBudget)
        AXUIElementSetMessagingTimeout(target.appElement, 0.1)
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(target.appElement, kAXFocusedWindowAttribute as CFString, &focused)
        let root: AXUIElement
        if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            root = focused as! AXUIElement
        } else { root = target.appElement }

        enumerate(root, depth: 0, maxDepth: 30, row: nil, rows: &rows, elements: &elements, nextId: &nextId, visited: &visited, deadline: deadline, limit: 1200)

        if elements.isEmpty {
            var winVal: AnyObject?
            AXUIElementCopyAttributeValue(target.appElement, kAXWindowsAttribute as CFString, &winVal)
            if let windows = winVal as? [AXUIElement] {
                for win in windows {
                    enumerate(win, depth: 0, maxDepth: 30, row: nil, rows: &rows, elements: &elements, nextId: &nextId, visited: &visited, deadline: deadline, limit: 1200)
                }
            }
        }

        // The text of an element's row or cell tells repeated controls apart, like DOM row context.
        for index in elements.indices {
            guard let row = rows.rowOf[elements[index].id], let text = rows.text[row] else { continue }
            let own = elements[index].displayLabel
            let context = text.filter { $0 != own }.joined(separator: " · ")
            if !context.isEmpty { elements[index].context = String(context.prefix(100)) }
        }

        // Prioritize actual controls over static labels when the model's window is full.
        let beforeFiltering = elements.count
        let window = WindowSnapshot.frontWindow(pid: target.pid)?.frame
        elements = elements.filter { element in
            guard let frame = element.frame, let window else { return true }
            return window.intersects(frame)
        }
        func priority(_ element: AccessibilityElement) -> Int {
            if element.focused || element.isOutcomeEvidence { return 0 }
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(element.role) { return 1 }
            return element.role == "AXStaticText" ? 3 : 2
        }
        elements = Array(elements.sorted {
            let lhs = priority($0), rhs = priority($1)
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }.prefix(500))
        Log.info("AXWalk: \(elements.count) elements for \(target.name) before_filter=\(beforeFiltering) visited=\(visited) budget_exhausted=\(Date() >= deadline)")
        return elements
    }

    struct RowTexts {
        var next = 0
        var text: [Int: [String]] = [:]
        var rowOf: [Int: Int] = [:]
    }

    private static let rowRoles: Set<String> = ["AXRow", "AXCell", "AXOutlineRow", "AXTableRow"]

    private static let skipRoles: Set<String> = [
        "AXScrollArea", "AXSplitGroup", "AXLayoutArea",
        "AXScrollBar", "AXWindow", "AXSheet", "AXDrawer",
    ]

    private static func enumerate(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        row: Int?,
        rows: inout RowTexts,
        elements: inout [AccessibilityElement],
        nextId: inout Int,
        visited: inout Int,
        deadline: Date,
        limit: Int
    ) {
        guard depth < maxDepth, elements.count < limit, visited < 3000, Date() < deadline else { return }
        visited += 1

        // Fetch metadata together instead of making a separate cross-process call per attribute.
        let keys = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                    kAXRoleDescriptionAttribute, kAXValueAttribute, kAXEnabledAttribute, kAXChildrenAttribute, kAXFocusedAttribute]
        var batch: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &batch)
        let values = batch as? [AnyObject]
        func attribute(_ key: String) -> AnyObject? {
            if result == .success, let index = keys.firstIndex(of: key), let values, index < values.count {
                return values[index]
            }
            return attr(element, key)
        }
        let role = attribute(kAXRoleAttribute) as? String ?? ""
        let title = attribute(kAXTitleAttribute) as? String
        let desc = attribute(kAXDescriptionAttribute) as? String
        let roleDesc = attribute(kAXRoleDescriptionAttribute) as? String
        let rawValue = attribute(kAXValueAttribute)
        let value = (rawValue as? String) ?? (rawValue as? NSNumber)?.stringValue
        let enabled = (attribute(kAXEnabledAttribute) as? Bool) ?? true
        let label = [title, desc, roleDesc].compactMap { $0 }.first { !$0.isEmpty }

        var actionNames: CFArray?
        AXUIElementCopyActionNames(element, &actionNames)
        let actions = (actionNames as? [String]) ?? []

        let hasAnyAction = !actions.isEmpty
        let hasLabel = (label != nil && label != "") || (value != nil && value != "")
        let outcomeLabel = label?.lowercased().hasPrefix("now playing") == true
        let shouldSkip = skipRoles.contains(role) || (role == "AXGroup" && !hasAnyAction && !outcomeLabel)
        var row = row
        if rowRoles.contains(role), row == nil { row = rows.next; rows.next += 1 }
        if let row, let text = label ?? value, !text.isEmpty, (rows.text[row]?.count ?? 0) < 6 {
            rows.text[row, default: []].append(String(text.prefix(60)))
        }

        if !shouldSkip && hasLabel && (hasAnyAction || isInteractiveRole(role) || role == "AXStaticText" || outcomeLabel) {
            elements.append(AccessibilityElement(
                id: nextId,
                role: role,
                label: label,
                value: value,
                enabled: enabled,
                actions: actions,
                axElement: element,
                frame: InputController.frame(element),
                focused: (attribute(kAXFocusedAttribute) as? Bool) ?? false
            ))
            if let row { rows.rowOf[nextId] = row }
            nextId += 1
        }

        guard let children = attribute(kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            enumerate(child, depth: depth + 1, maxDepth: maxDepth, row: row, rows: &rows, elements: &elements, nextId: &nextId, visited: &visited, deadline: deadline, limit: limit)
        }
    }

    private static func isInteractiveRole(_ role: String) -> Bool {
        switch role {
        case "AXButton", "AXTextField", "AXTextArea", "AXCheckBox",
             "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXMenuBarItem",
             "AXRow", "AXCell", "AXLink", "AXTab", "AXSlider",
             "AXComboBox", "AXDisclosureTriangle", "AXIncrementor",
             "AXOutlineRow", "AXTableRow", "AXOutline",
             "AXToolbarButton", "AXMenuButton", "AXSwitch",
             "AXWebArea", "AXList", "AXTable":
            return true
        default:
            return false
        }
    }

    private static func attr(_ el: AXUIElement, _ key: String) -> AnyObject? {
        var val: AnyObject?
        AXUIElementCopyAttributeValue(el, key as CFString, &val)
        return val
    }
}
