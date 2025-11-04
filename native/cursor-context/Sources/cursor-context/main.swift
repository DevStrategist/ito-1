import AppKit
import Foundation
import ApplicationServices

// MARK: - Missing AX constants (define as CFString if not exported by SDK)
private let kAXStringForTextMarkerRangeParameterizedAttribute: CFString = "AXStringForTextMarkerRange" as CFString
private let kAXLengthForTextMarkerRangeParameterizedAttribute: CFString = "AXLengthForTextMarkerRange" as CFString
private let kAXTextMarkerRangeForUIElementParameterizedAttribute: CFString = "AXTextMarkerRangeForUIElement" as CFString
private let kAXSelectedTextMarkerRangeAttribute: CFString = "AXSelectedTextMarkerRange" as CFString
private let kAXDocumentRangeAttribute: CFString = "AXDocumentRange" as CFString

// Some SDK constants surface as String; cast to CFString at use-sites.
@inline(__always) func CFs(_ s: String) -> CFString { s as CFString }

// MARK: - Data Structures

struct CursorPosition: Codable { let offset: Int; let line: Int?; let column: Int? }
struct TextRange: Codable { let start: Int; let end: Int; let length: Int }

struct CursorContext: Codable {
    let textBefore: String
    let textAfter: String
    let selectedText: String
    let cursorPosition: CursorPosition
    let selectionRange: TextRange?
    let truncated: Bool
    let totalLength: Int
    let timestamp: String
}

struct CursorContextResult: Codable {
    let success: Bool
    let context: CursorContext?
    let error: String?
    let method: String
}

// MARK: - Utilities

var DEBUG_LOG = false
@inline(__always) func dlog(_ s: String) { if DEBUG_LOG { fputs(s + "\n", stderr) } }

@inline(__always)
func axErrorToString(_ e: AXError) -> String {
    switch e {
    case .success: return "Success"
    case .failure: return "Failure"
    case .illegalArgument: return "IllegalArgument"
    case .invalidUIElement: return "InvalidUIElement"
    case .invalidUIElementObserver: return "InvalidUIElementObserver"
    case .cannotComplete: return "CannotComplete"
    case .attributeUnsupported: return "AttributeUnsupported"
    case .actionUnsupported: return "ActionUnsupported"
    case .notificationUnsupported: return "NotificationUnsupported"
    case .notImplemented: return "NotImplemented"
    case .notificationAlreadyRegistered: return "NotificationAlreadyRegistered"
    case .notificationNotRegistered: return "NotificationNotRegistered"
    case .apiDisabled: return "APIDisabled"
    case .noValue: return "NoValue"
    case .parameterizedAttributeUnsupported: return "ParameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "NotEnoughPrecision"
    @unknown default: return "Unknown(\(e.rawValue))"
    }
}

// Use CFTypeRef? so we control casts explicitly.
@inline(__always)
func axCopyAttr(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var v: CFTypeRef?
    let r = AXUIElementCopyAttributeValue(element, name, &v)
    return r == .success ? v : nil
}

@inline(__always)
func axCopyParam(_ element: AXUIElement, _ name: CFString, _ param: CFTypeRef) -> CFTypeRef? {
    var v: CFTypeRef?
    let r = AXUIElementCopyParameterizedAttributeValue(element, name, param, &v)
    return r == .success ? v : nil
}

@inline(__always)
func axStringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
    var cfRange = CFRange(location: location, length: length)
    guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
    return axCopyParam(element, CFs(kAXStringForRangeParameterizedAttribute as String), axRange) as? String
}

@inline(__always)
func axStringForMarkerRange(_ element: AXUIElement, _ mr: CFTypeRef) -> String? {
    axCopyParam(element, kAXStringForTextMarkerRangeParameterizedAttribute, mr) as? String
}

@inline(__always)
func axLengthForMarkerRange(_ element: AXUIElement, _ mr: CFTypeRef) -> Int? {
    (axCopyParam(element, kAXLengthForTextMarkerRangeParameterizedAttribute, mr) as? NSNumber)?.intValue
}

// Document marker range: attribute or parameterized
func documentMarkerRange(_ element: AXUIElement) -> CFTypeRef? {
    if let v = axCopyAttr(element, kAXDocumentRangeAttribute) { return v }
    if let v = axCopyParam(element, kAXTextMarkerRangeForUIElementParameterizedAttribute, element) { return v }
    return nil
}

func selectedMarkerRange(_ element: AXUIElement) -> CFTypeRef? {
    axCopyAttr(element, kAXSelectedTextMarkerRangeAttribute)
}

// MARK: - Diagnostics

func logElementSnapshot(_ element: AXUIElement, label: String) {
    guard DEBUG_LOG else { return }
    fputs("\n=== \(label) ===\n", stderr)
    let attrs: [(String, CFString)] = [
        ("Role", CFs(kAXRoleAttribute as String)),
        ("Value", CFs(kAXValueAttribute as String)),
        ("SelectedText", CFs(kAXSelectedTextAttribute as String)),
        ("SelectedTextRange", CFs(kAXSelectedTextRangeAttribute as String)),
        ("NumberOfCharacters", CFs(kAXNumberOfCharactersAttribute as String)),
        ("VisibleCharacterRange", CFs(kAXVisibleCharacterRangeAttribute as String)),
        ("InsertionPointLineNumber", CFs(kAXInsertionPointLineNumberAttribute as String)),
        ("DocumentRange", kAXDocumentRangeAttribute),
        ("SelectedTextMarkerRange", kAXSelectedTextMarkerRangeAttribute),
    ]
    for (name, attr) in attrs {
        var v: CFTypeRef?
        let r = AXUIElementCopyAttributeValue(element, attr, &v)
        if r == .success {
            if let s = v as? String {
                let preview = s.count > 80 ? String(s.prefix(80)) + "…" : s
                fputs("  ✓ \(name): \"\(preview)\"\n", stderr)
            } else if let n = v as? NSNumber {
                fputs("  ✓ \(name): \(n)\n", stderr)
            } else if v != nil {
                fputs("  ✓ \(name): <\(type(of: v!))>\n", stderr)
            } else {
                fputs("  ✓ \(name): <nil>\n", stderr)
            }
        } else {
            fputs("  ✗ \(name): \(axErrorToString(r))\n", stderr)
        }
    }
    fputs("=========================\n", stderr)
}

// Inspect element in detail - shows ALL attributes
func inspectElement(_ element: AXUIElement, label: String) {
    guard DEBUG_LOG else { return }

    fputs("\n>>> INSPECTING: \(label)\n", stderr)

    // Get role
    if let role = axCopyAttr(element, CFs(kAXRoleAttribute as String)) as? String {
        fputs("    Role: \(role)\n", stderr)
    }

    // Get all available attribute names
    var attrNames: CFArray?
    if AXUIElementCopyAttributeNames(element, &attrNames) == .success, let names = attrNames as? [String] {
        fputs("    Available attributes (\(names.count)):\n", stderr)
        for name in names.prefix(20) {  // Limit to first 20 to avoid spam
            fputs("      - \(name)\n", stderr)
        }
        if names.count > 20 {
            fputs("      ... (\(names.count - 20) more)\n", stderr)
        }
    }

    // Check for children
    if let childrenAny = axCopyAttr(element, CFs(kAXChildrenAttribute as String)),
       let children = childrenAny as? [AXUIElement] {
        fputs("    Children: \(children.count)\n", stderr)
        if children.count > 0 && children.count <= 5 {
            for (i, child) in children.enumerated() {
                if let role = axCopyAttr(child, CFs(kAXRoleAttribute as String)) as? String {
                    fputs("      [\(i)]: \(role)\n", stderr)
                }
            }
        } else if children.count > 5 {
            fputs("      (first 5 of \(children.count))\n", stderr)
            for i in 0..<5 {
                if let role = axCopyAttr(children[i], CFs(kAXRoleAttribute as String)) as? String {
                    fputs("      [\(i)]: \(role)\n", stderr)
                }
            }
        }
    }

    fputs("<<<\n\n", stderr)
}

// Structured logging helpers
func logMethodStart(_ method: String) {
    dlog("[\(method)] Attempting...")
}

func logMethodSuccess(_ method: String, _ detail: String = "") {
    let msg = detail.isEmpty ? "✓ Success" : "✓ \(detail)"
    dlog("[\(method)] \(msg)")
}

func logMethodFailure(_ method: String, _ reason: String) {
    dlog("[\(method)] ✗ \(reason)")
}

func logMethodSkip(_ method: String, _ reason: String) {
    dlog("[\(method)] → Skipping: \(reason)")
}

// MARK: - Extraction Paths

// Path A: Classic Cocoa (kAXValue + kAXSelectedTextRange)
func valueBasedContext(_ element: AXUIElement, maxBefore: Int, maxAfter: Int) -> CursorContextResult? {
    logMethodStart("VALUE_METHOD")

    // Try to get AXValue
    guard let fullText = axCopyAttr(element, CFs(kAXValueAttribute as String)) as? String else {
        logMethodFailure("VALUE_METHOD", "AXValue attribute not available or not a string")
        logMethodSkip("VALUE_METHOD", "no value attribute")
        return nil
    }

    guard !fullText.isEmpty else {
        logMethodFailure("VALUE_METHOD", "AXValue is empty")
        logMethodSkip("VALUE_METHOD", "value is empty")
        return nil
    }

    logMethodSuccess("VALUE_METHOD", "Got AXValue with \(fullText.count) characters")

    let selectedText = (axCopyAttr(element, CFs(kAXSelectedTextAttribute as String)) as? String) ?? ""
    var cursorOffset = 0
    var selection: TextRange? = nil

    if let any = axCopyAttr(element, CFs(kAXSelectedTextRangeAttribute as String)) {
        let axv = any as! AXValue // CFTypeRef → AXValue (CoreFoundation type; explicit cast)
        var cfRange = CFRange(location: 0, length: 0)
        if AXValueGetValue(axv, .cfRange, &cfRange) {
            cursorOffset = cfRange.location
            if cfRange.length > 0 {
                selection = TextRange(start: cfRange.location,
                                      end: cfRange.location + cfRange.length,
                                      length: cfRange.length)
            }
            logMethodSuccess("VALUE_METHOD", "Got cursor position at offset \(cursorOffset)")
        }
    } else {
        dlog("[VALUE_METHOD] No AXSelectedTextRange (cursor will default to 0)")
    }

    let totalLength = fullText.count
    let startOffset = max(0, cursorOffset - maxBefore)
    let endOffset = min(totalLength, cursorOffset + (selection?.length ?? 0) + maxAfter)

    let startIndex = fullText.index(fullText.startIndex, offsetBy: startOffset)
    let cursorIndex = fullText.index(fullText.startIndex, offsetBy: cursorOffset)
    let endIndex = fullText.index(fullText.startIndex, offsetBy: endOffset)

    let textBefore = String(fullText[startIndex..<cursorIndex])
    let textAfter = String(fullText[cursorIndex..<endIndex])
    let truncated = (startOffset > 0) || (endOffset < totalLength)

    logMethodSuccess("VALUE_METHOD", "Returning context (before: \(textBefore.count), after: \(textAfter.count))")

    let context = CursorContext(
        textBefore: textBefore,
        textAfter: textAfter,
        selectedText: selectedText,
        cursorPosition: CursorPosition(offset: cursorOffset, line: nil, column: nil),
        selectionRange: selection,
        truncated: truncated,
        totalLength: totalLength,
        timestamp: ISO8601DateFormatter().string(from: Date())
    )
    return CursorContextResult(success: true, context: context, error: nil, method: "accessibility:value")
}

// Path B: Marker-based (Chromium/WebKit/Electron).
struct MarkerContext {
    let fullText: String
    let before: String
    let after: String
    let selected: String
    let cursorOffset: Int
    let selectionLength: Int
    let totalLength: Int
}

func markerBasedContext(_ element: AXUIElement, maxBefore: Int, maxAfter: Int) -> MarkerContext? {
    // Try to get document marker range
    guard let docMR_any = documentMarkerRange(element) else {
        logMethodFailure("MARKER_METHOD", "No document marker range available")
        return nil
    }
    logMethodSuccess("MARKER_METHOD", "Got document marker range")

    // Try to get full text from document range
    guard let fullText = axStringForMarkerRange(element, docMR_any) else {
        logMethodFailure("MARKER_METHOD", "Could not extract text from document marker range")
        return nil
    }

    guard let docLen = axLengthForMarkerRange(element, docMR_any) else {
        logMethodFailure("MARKER_METHOD", "Could not get length for document marker range")
        return nil
    }
    logMethodSuccess("MARKER_METHOD", "Got document text with \(docLen) characters")

    // Try to get selected marker range
    guard let selMR_any = selectedMarkerRange(element) else {
        logMethodFailure("MARKER_METHOD", "No selected marker range available")
        return nil
    }
    logMethodSuccess("MARKER_METHOD", "Got selected marker range")

    // CFTypeRef → AXTextMarkerRange (explicit casts)
    let docMR = docMR_any as! AXTextMarkerRange
    let selMR = selMR_any as! AXTextMarkerRange

    // Extract start markers
    let docStartMarker: AXTextMarker = AXTextMarkerRangeCopyStartMarker(docMR)
    let selStartMarker: AXTextMarker = AXTextMarkerRangeCopyStartMarker(selMR)
    // (selEnd available if needed)
    _ = AXTextMarkerRangeCopyEndMarker(selMR)

    // Build [docStart, selStart) to measure caret offset (returns non-optional)
    let startToSelStart: AXTextMarkerRange = AXTextMarkerRangeCreate(kCFAllocatorDefault, docStartMarker, selStartMarker)
    let cursorOffset = axLengthForMarkerRange(element, startToSelStart) ?? 0

    let selectedText = axStringForMarkerRange(element, selMR) ?? ""
    let selLen = axLengthForMarkerRange(element, selMR) ?? 0

    logMethodSuccess("MARKER_METHOD", "Calculated cursor offset: \(cursorOffset), selection length: \(selLen)")

    // Window around caret in Swift
    let safeCursor = max(0, min(cursorOffset, docLen))
    let afterEnd = min(docLen, safeCursor + selLen + maxAfter)
    let beforeStart = max(0, safeCursor - maxBefore)

    let startIdx = fullText.startIndex
    let beforeStartIdx = fullText.index(startIdx, offsetBy: beforeStart)
    let cursorIdx = fullText.index(startIdx, offsetBy: safeCursor)
    let afterEndIdx = fullText.index(startIdx, offsetBy: afterEnd)

    let before = String(fullText[beforeStartIdx..<cursorIdx])
    let after = String(fullText[cursorIdx..<afterEndIdx])

    return MarkerContext(
        fullText: fullText,
        before: before,
        after: after,
        selected: selectedText,
        cursorOffset: safeCursor,
        selectionLength: selLen,
        totalLength: docLen
    )
}

// Path C: Range-based fallback using kAXStringForRange (works in some wrappers)
func rangeBasedContext(_ element: AXUIElement, maxBefore: Int, maxAfter: Int) -> CursorContextResult? {
    let bigLen = 5_000_000

    guard let fullText = axStringForRange(element, location: 0, length: bigLen) else {
        logMethodFailure("RANGE_METHOD", "AXStringForRange not supported or failed")
        return nil
    }

    guard !fullText.isEmpty else {
        logMethodFailure("RANGE_METHOD", "AXStringForRange returned empty text")
        return nil
    }

    logMethodSuccess("RANGE_METHOD", "Got text via AXStringForRange (\(fullText.count) characters)")

    var cursorOffset = 0
    var selLen = 0
    if let any = axCopyAttr(element, CFs(kAXSelectedTextRangeAttribute as String)) {
        let axv = any as! AXValue
        var cfRange = CFRange(location: 0, length: 0)
        if AXValueGetValue(axv, .cfRange, &cfRange) {
            cursorOffset = cfRange.location
            selLen = cfRange.length
            logMethodSuccess("RANGE_METHOD", "Got cursor position at offset \(cursorOffset)")
        }
    } else {
        dlog("[RANGE_METHOD] No AXSelectedTextRange (cursor will default to 0)")
    }

    let totalLength = fullText.count
    let startOffset = max(0, min(cursorOffset, totalLength) - maxBefore)
    let endOffset = min(totalLength, cursorOffset + selLen + maxAfter)

    let startIndex = fullText.index(fullText.startIndex, offsetBy: startOffset)
    let cursorIndex = fullText.index(fullText.startIndex, offsetBy: min(cursorOffset, totalLength))
    let endIndex = fullText.index(fullText.startIndex, offsetBy: endOffset)

    let textBefore = String(fullText[startIndex..<cursorIndex])
    let textAfter = String(fullText[cursorIndex..<endIndex])
    let truncated = (startOffset > 0) || (endOffset < totalLength)

    let selectedText: String = selLen > 0 ? (axStringForRange(element, location: cursorOffset, length: selLen) ?? "") : ""

    let selectionRange: TextRange? = selLen > 0
        ? TextRange(start: cursorOffset, end: cursorOffset + selLen, length: selLen)
        : nil

    logMethodSuccess("RANGE_METHOD", "Returning context (before: \(textBefore.count), after: \(textAfter.count))")

    let context = CursorContext(
        textBefore: textBefore,
        textAfter: textAfter,
        selectedText: selectedText,
        cursorPosition: CursorPosition(offset: min(cursorOffset, totalLength), line: nil, column: nil),
        selectionRange: selectionRange,
        truncated: truncated,
        totalLength: totalLength,
        timestamp: ISO8601DateFormatter().string(from: Date())
    )
    return CursorContextResult(success: true, context: context, error: nil, method: "accessibility:range")
}

// Try focused element, then a single parent hop
func bestRangeContextWithParentHop(_ element: AXUIElement, maxBefore: Int, maxAfter: Int) -> CursorContextResult? {
    logMethodStart("RANGE_METHOD")
    dlog("[RANGE_METHOD] Trying on focused element...")

    if let r = rangeBasedContext(element, maxBefore: maxBefore, maxAfter: maxAfter) {
        logMethodSuccess("RANGE_METHOD", "Succeeded on focused element")
        return r
    }

    dlog("[RANGE_METHOD] Failed on focused element, trying parent...")
    if let parentAny = axCopyAttr(element, CFs(kAXParentAttribute as String)) {
        let parent = parentAny as! AXUIElement
        if let r = rangeBasedContext(parent, maxBefore: maxBefore, maxAfter: maxAfter) {
            logMethodSuccess("RANGE_METHOD", "Succeeded on parent element")
            return r
        }
        dlog("[RANGE_METHOD] Failed on parent element too")
    } else {
        dlog("[RANGE_METHOD] No parent element available")
    }

    logMethodSkip("RANGE_METHOD", "range API not available on element or parent")
    return nil
}

func bestMarkerContextWithParentHop(_ element: AXUIElement, maxBefore: Int, maxAfter: Int) -> (MarkerContext, String)? {
    logMethodStart("MARKER_METHOD")
    dlog("[MARKER_METHOD] Trying on focused element...")

    if let m = markerBasedContext(element, maxBefore: maxBefore, maxAfter: maxAfter) {
        logMethodSuccess("MARKER_METHOD", "Succeeded on focused element")
        return (m, "accessibility:marker")
    }

    dlog("[MARKER_METHOD] Failed on focused element, trying parent...")
    if let parentAny = axCopyAttr(element, CFs(kAXParentAttribute as String)) {
        let parent = parentAny as! AXUIElement
        if let m = markerBasedContext(parent, maxBefore: maxBefore, maxAfter: maxAfter) {
            logMethodSuccess("MARKER_METHOD", "Succeeded on parent element")
            return (m, "accessibility:marker(parent)")
        }
        dlog("[MARKER_METHOD] Failed on parent element too")
    } else {
        dlog("[MARKER_METHOD] No parent element available")
    }

    logMethodSkip("MARKER_METHOD", "marker API not available on element or parent")
    return nil
}

// MARK: - Path D: Electron Tree Traversal

// Recursively search for text-capable elements in the accessibility tree
func findTextElements(_ element: AXUIElement, maxDepth: Int, currentDepth: Int = 0) -> [AXUIElement] {
    var results: [AXUIElement] = []

    if currentDepth >= maxDepth {
        return results
    }

    // Check if current element might have text content
    let textRoles = ["AXTextArea", "AXTextField", "AXWebArea", "AXGroup", "AXScrollArea"]
    if let role = axCopyAttr(element, CFs(kAXRoleAttribute as String)) as? String {
        if textRoles.contains(role) {
            // Check if it has any text-related attributes
            let hasValue = axCopyAttr(element, CFs(kAXValueAttribute as String)) != nil
            let hasMarkerRange = documentMarkerRange(element) != nil
            let hasNumberOfChars = axCopyAttr(element, CFs(kAXNumberOfCharactersAttribute as String)) != nil

            if hasValue || hasMarkerRange || hasNumberOfChars {
                results.append(element)
                dlog("[TREE_TRAVERSAL] Found potential text element: \(role)")
            }
        }
    }

    // Search children
    if let childrenAny = axCopyAttr(element, CFs(kAXChildrenAttribute as String)),
       let children = childrenAny as? [AXUIElement] {
        for child in children {
            results.append(contentsOf: findTextElements(child, maxDepth: maxDepth, currentDepth: currentDepth + 1))
        }
    }

    return results
}

// Try extraction methods on a candidate element
func tryExtractFromElement(_ element: AXUIElement, maxBefore: Int, maxAfter: Int) -> CursorContextResult? {
    // Try value-based first
    if let result = valueBasedContext(element, maxBefore: maxBefore, maxAfter: maxAfter) {
        return result
    }

    // Try marker-based (without parent hop, we're already traversing)
    if let mc = markerBasedContext(element, maxBefore: maxBefore, maxAfter: maxAfter) {
        let truncated = (mc.cursorOffset > maxBefore) || (mc.cursorOffset + mc.selectionLength + maxAfter < mc.totalLength)
        let selRange: TextRange? = mc.selectionLength > 0
            ? TextRange(start: mc.cursorOffset, end: mc.cursorOffset + mc.selectionLength, length: mc.selectionLength)
            : nil

        let context = CursorContext(
            textBefore: mc.before,
            textAfter: mc.after,
            selectedText: mc.selected,
            cursorPosition: CursorPosition(offset: mc.cursorOffset, line: nil, column: nil),
            selectionRange: selRange,
            truncated: truncated,
            totalLength: mc.totalLength,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        return CursorContextResult(success: true, context: context, error: nil, method: "accessibility:marker(tree)")
    }

    // Try range-based
    if let result = rangeBasedContext(element, maxBefore: maxBefore, maxAfter: maxAfter) {
        return result
    }

    return nil
}

// Path D: Electron/Chromium tree traversal fallback
func electronTreeTraversal(_ focusedElement: AXUIElement, maxBefore: Int, maxAfter: Int) -> CursorContextResult? {
    logMethodStart("TREE_TRAVERSAL")
    dlog("[TREE_TRAVERSAL] Searching descendants for text elements (Electron fallback)...")

    inspectElement(focusedElement, label: "Focused Element (Tree Traversal)")

    // Search children up to 4 levels deep
    let candidates = findTextElements(focusedElement, maxDepth: 4)
    dlog("[TREE_TRAVERSAL] Found \(candidates.count) candidate text element(s)")

    // Try extraction on each candidate
    for (index, candidate) in candidates.enumerated() {
        if let role = axCopyAttr(candidate, CFs(kAXRoleAttribute as String)) as? String {
            dlog("[TREE_TRAVERSAL] Trying candidate \(index + 1)/\(candidates.count): \(role)")
        }

        if let result = tryExtractFromElement(candidate, maxBefore: maxBefore, maxAfter: maxAfter) {
            logMethodSuccess("TREE_TRAVERSAL", "Found text in descendant element \(index + 1)")
            return result
        }
    }

    // Also try parent traversal (go up instead of down)
    dlog("[TREE_TRAVERSAL] No success in descendants, trying ancestors...")
    var currentElement = focusedElement
    for level in 1...3 {
        guard let parentAny = axCopyAttr(currentElement, CFs(kAXParentAttribute as String)) else {
            dlog("[TREE_TRAVERSAL] No more ancestors at level \(level)")
            break
        }

        let parent = parentAny as! AXUIElement
        if let role = axCopyAttr(parent, CFs(kAXRoleAttribute as String)) as? String {
            dlog("[TREE_TRAVERSAL] Trying ancestor at level \(level): \(role)")
        }

        if let result = tryExtractFromElement(parent, maxBefore: maxBefore, maxAfter: maxAfter) {
            logMethodSuccess("TREE_TRAVERSAL", "Found text in ancestor at level \(level)")
            return result
        }

        currentElement = parent
    }

    logMethodSkip("TREE_TRAVERSAL", "no text found in tree traversal")
    return nil
}

// MARK: - Core

func getCursorContext(maxCharsBefore: Int, maxCharsAfter: Int) -> CursorContextResult {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
        return CursorContextResult(success: false, context: nil, error: "No frontmost application", method: "accessibility")
    }
    let pid = frontmostApp.processIdentifier
    let appElement = AXUIElementCreateApplication(pid)

    // Help Chromium/Electron
    AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    dlog("✅ Enabled AXEnhancedUserInterface and AXManualAccessibility")
    dlog("🔍 Focused Application: \(frontmostApp.localizedName ?? "Unknown")")

    var focusedElementObj: CFTypeRef?
    let r = AXUIElementCopyAttributeValue(appElement, CFs(kAXFocusedUIElementAttribute as String), &focusedElementObj)
    guard r == .success, let focusedAny = focusedElementObj else {
        return CursorContextResult(success: false, context: nil, error: "No focused text element", method: "accessibility")
    }
    let element = focusedAny as! AXUIElement

    logElementSnapshot(element, label: "Focused Element")

    // 1) Value-based
    if let v = valueBasedContext(element, maxBefore: maxCharsBefore, maxAfter: maxCharsAfter) { return v }

    // 2) Marker-based (+ parent hop)
    if let (mc, methodTag) = bestMarkerContextWithParentHop(element, maxBefore: maxCharsBefore, maxAfter: maxCharsAfter) {
        let truncated = (mc.cursorOffset > maxCharsBefore) || (mc.cursorOffset + mc.selectionLength + maxCharsAfter < mc.totalLength)
        let selRange: TextRange? = mc.selectionLength > 0
            ? TextRange(start: mc.cursorOffset, end: mc.cursorOffset + mc.selectionLength, length: mc.selectionLength)
            : nil

        let context = CursorContext(
            textBefore: mc.before,
            textAfter: mc.after,
            selectedText: mc.selected,
            cursorPosition: CursorPosition(offset: mc.cursorOffset, line: nil, column: nil),
            selectionRange: selRange,
            truncated: truncated,
            totalLength: mc.totalLength,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        return CursorContextResult(success: true, context: context, error: nil, method: methodTag)
    }

    // 3) Range-based fallback (+ parent hop)
    if let r = bestRangeContextWithParentHop(element, maxBefore: maxCharsBefore, maxAfter: maxCharsAfter) { return r }

    // 4) Electron tree traversal (comprehensive fallback)
    dlog("\n⚠️  Standard methods failed, trying Electron tree traversal...")
    if let r = electronTreeTraversal(element, maxBefore: maxCharsBefore, maxAfter: maxCharsAfter) { return r }

    return CursorContextResult(success: false, context: nil, error: "Unable to retrieve text via Value, Marker, Range, or Tree Traversal", method: "accessibility")
}

// MARK: - CLI

var maxCharsBefore = 1000
var maxCharsAfter = 1000

let args = CommandLine.arguments
var i = 1
while i < args.count {
    let a = args[i]
    if a == "--before", i + 1 < args.count {
        maxCharsBefore = Int(args[i + 1]) ?? 1000
        i += 2
    } else if a == "--after", i + 1 < args.count {
        maxCharsAfter = Int(args[i + 1]) ?? 1000
        i += 2
    } else if a == "--debug" {
        DEBUG_LOG = true
        i += 1
    } else {
        i += 1
    }
}

let result = getCursorContext(maxCharsBefore: maxCharsBefore, maxCharsAfter: maxCharsAfter)
let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
if let jsonData = try? encoder.encode(result), let jsonString = String(data: jsonData, encoding: .utf8) {
    print(jsonString)
}
