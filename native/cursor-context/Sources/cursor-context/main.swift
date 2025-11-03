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

// MARK: - Diagnostics (light)

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

// MARK: - Extraction Paths

// Path A: Classic Cocoa (kAXValue + kAXSelectedTextRange)
func valueBasedContext(_ element: AXUIElement, maxBefore: Int, maxAfter: Int) -> CursorContextResult? {
    guard let fullText = axCopyAttr(element, CFs(kAXValueAttribute as String)) as? String,
          !fullText.isEmpty else { return nil }

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
        }
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
    guard let docMR_any = documentMarkerRange(element),
          let fullText = axStringForMarkerRange(element, docMR_any),
          let docLen = axLengthForMarkerRange(element, docMR_any),
          let selMR_any = selectedMarkerRange(element) else { return nil }

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
    guard let fullText = axStringForRange(element, location: 0, length: bigLen), !fullText.isEmpty else { return nil }

    var cursorOffset = 0
    var selLen = 0
    if let any = axCopyAttr(element, CFs(kAXSelectedTextRangeAttribute as String)) {
        let axv = any as! AXValue
        var cfRange = CFRange(location: 0, length: 0)
        if AXValueGetValue(axv, .cfRange, &cfRange) {
            cursorOffset = cfRange.location
            selLen = cfRange.length
        }
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
    if let r = rangeBasedContext(element, maxBefore: maxBefore, maxAfter: maxAfter) { return r }
    if let parentAny = axCopyAttr(element, CFs(kAXParentAttribute as String)) {
        let parent = parentAny as! AXUIElement
        if let r = rangeBasedContext(parent, maxBefore: maxBefore, maxAfter: maxAfter) { return r }
    }
    return nil
}

func bestMarkerContextWithParentHop(_ element: AXUIElement, maxBefore: Int, maxAfter: Int) -> (MarkerContext, String)? {
    if let m = markerBasedContext(element, maxBefore: maxBefore, maxAfter: maxAfter) { return (m, "accessibility:marker") }
    if let parentAny = axCopyAttr(element, CFs(kAXParentAttribute as String)) {
        let parent = parentAny as! AXUIElement
        if let m = markerBasedContext(parent, maxBefore: maxBefore, maxAfter: maxAfter) { return (m, "accessibility:marker(parent)") }
    }
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

    return CursorContextResult(success: false, context: nil, error: "Unable to retrieve text via Value, Marker, or Range APIs", method: "accessibility")
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
