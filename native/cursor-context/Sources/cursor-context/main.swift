import AppKit
import Foundation

// MARK: - Data Structures

struct CursorPosition: Codable {
    let offset: Int
    let line: Int?
    let column: Int?
}

struct TextRange: Codable {
    let start: Int
    let end: Int
    let length: Int
}

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

// MARK: - Accessibility Functions

func getFocusedElement() -> AXUIElement? {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = frontmostApp.processIdentifier
    let appElement = AXUIElementCreateApplication(pid)

    var focusedElement: AnyObject?
    let result = AXUIElementCopyAttributeValue(
        appElement,
        kAXFocusedUIElementAttribute as CFString,
        &focusedElement
    )

    guard result == .success, let element = focusedElement else {
        return nil
    }

    return (element as! AXUIElement)
}

func getAttributeValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
    )

    return result == .success ? value : nil
}

func getCursorContext(maxCharsBefore: Int = 1000, maxCharsAfter: Int = 1000) -> CursorContextResult {
    guard let focusedElement = getFocusedElement() else {
        return CursorContextResult(
            success: false,
            context: nil,
            error: "No focused text element found. Make sure a text field is focused and accessibility permissions are granted.",
            method: "accessibility"
        )
    }

    // Get the role of the focused element for debugging
    var roleDescription = "unknown"
    if let role = getAttributeValue(focusedElement, kAXRoleAttribute as String) as? String {
        roleDescription = role
    }

    // Get the full text value
    guard let fullText = getAttributeValue(focusedElement, kAXValueAttribute as String) as? String else {
        return CursorContextResult(
            success: false,
            context: nil,
            error: "Unable to retrieve text value from focused element (role: \(roleDescription)). Element may not support text input.",
            method: "accessibility"
        )
    }

    // Get selected text range
    var selectedText = ""
    var cursorOffset = 0
    var selectionRange: TextRange? = nil

    if let selectedTextValue = getAttributeValue(focusedElement, kAXSelectedTextAttribute as String) as? String {
        selectedText = selectedTextValue
    }

    if let rangeValue = getAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as String) {
        var range: CFRange = CFRange(location: 0, length: 0)
        if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
            cursorOffset = range.location

            if range.length > 0 {
                selectionRange = TextRange(
                    start: range.location,
                    end: range.location + range.length,
                    length: range.length
                )
            }
        }
    }

    // Extract text before and after cursor
    let totalLength = fullText.count
    let startIndex = fullText.index(fullText.startIndex, offsetBy: max(0, cursorOffset - maxCharsBefore))
    let cursorIndex = fullText.index(fullText.startIndex, offsetBy: cursorOffset)
    let endOffset = min(totalLength, cursorOffset + (selectionRange?.length ?? 0) + maxCharsAfter)
    let endIndex = fullText.index(fullText.startIndex, offsetBy: endOffset)

    let textBefore = String(fullText[startIndex..<cursorIndex])
    let textAfter = String(fullText[cursorIndex..<endIndex])

    let truncated = (cursorOffset > maxCharsBefore) || (endOffset < totalLength)

    let context = CursorContext(
        textBefore: textBefore,
        textAfter: textAfter,
        selectedText: selectedText,
        cursorPosition: CursorPosition(offset: cursorOffset, line: nil, column: nil),
        selectionRange: selectionRange,
        truncated: truncated,
        totalLength: totalLength,
        timestamp: ISO8601DateFormatter().string(from: Date())
    )

    return CursorContextResult(
        success: true,
        context: context,
        error: nil,
        method: "accessibility"
    )
}

// MARK: - Main

// Parse command line arguments for maxCharsBefore and maxCharsAfter
func main() {
    fputs("DEBUG: main() started\n", stderr)
    fflush(stderr)

    let args = CommandLine.arguments
    var maxCharsBefore = 1000
    var maxCharsAfter = 1000

    // Parse arguments: cursor-context --before 500 --after 500
    for i in 1..<args.count {
        if args[i] == "--before" && i + 1 < args.count {
            maxCharsBefore = Int(args[i + 1]) ?? 1000
        } else if args[i] == "--after" && i + 1 < args.count {
            maxCharsAfter = Int(args[i + 1]) ?? 1000
        }
    }

    fputs("DEBUG: About to call getCursorContext\n", stderr)
    fflush(stderr)

    let result = getCursorContext(maxCharsBefore: maxCharsBefore, maxCharsAfter: maxCharsAfter)

    fputs("DEBUG: Got result, encoding JSON\n", stderr)
    fflush(stderr)

    let encoder = JSONEncoder()
    if let jsonData = try? encoder.encode(result),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
    }

    fputs("DEBUG: main() finished\n", stderr)
    fflush(stderr)
}

// Run once and exit
main()
