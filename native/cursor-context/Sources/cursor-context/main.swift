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

// MARK: - Main

// Get cursor context from focused element
func getCursorContext(maxCharsBefore: Int, maxCharsAfter: Int) -> CursorContextResult {
    // 1. Get the frontmost application
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
        return CursorContextResult(
            success: false,
            context: nil,
            error: "No frontmost application",
            method: "accessibility"
        )
    }

    let pid = frontmostApp.processIdentifier
    let appElement = AXUIElementCreateApplication(pid)

    // 2. Get the focused element
    var focusedElement: AnyObject?
    let result = AXUIElementCopyAttributeValue(
        appElement,
        kAXFocusedUIElementAttribute as CFString,
        &focusedElement
    )

    guard result == .success, let element = focusedElement as! AXUIElement? else {
        return CursorContextResult(
            success: false,
            context: nil,
            error: "No focused text element",
            method: "accessibility"
        )
    }

    // 3. Get the full text value
    var textValue: AnyObject?
    let valueResult = AXUIElementCopyAttributeValue(
        element,
        kAXValueAttribute as CFString,
        &textValue
    )

    guard valueResult == .success, let fullText = textValue as? String else {
        return CursorContextResult(
            success: false,
            context: nil,
            error: "Unable to retrieve text value",
            method: "accessibility"
        )
    }

    // 4. Get selected text and cursor position
    var selectedText = ""
    var cursorOffset = 0
    var selectionRange: TextRange? = nil

    // Try to get selected text
    var selectedTextValue: AnyObject?
    if AXUIElementCopyAttributeValue(
        element,
        kAXSelectedTextAttribute as CFString,
        &selectedTextValue
    ) == .success, let selected = selectedTextValue as? String {
        selectedText = selected
    }

    // Try to get cursor position/range
    var rangeValue: AnyObject?
    if AXUIElementCopyAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        &rangeValue
       ) == .success,
       let axValue = rangeValue as! AXValue? {
        var range = CFRange(location: 0, length: 0)
        if AXValueGetValue(axValue, .cfRange, &range) {
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

    // 5. Extract text before and after cursor
    let totalLength = fullText.count
    let startOffset = max(0, cursorOffset - maxCharsBefore)
    let endOffset = min(totalLength, cursorOffset + (selectionRange?.length ?? 0) + maxCharsAfter)

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

// Parse command line arguments
let args = CommandLine.arguments
var maxCharsBefore = 1000
var maxCharsAfter = 1000

for i in 1..<args.count {
    if args[i] == "--before" && i + 1 < args.count {
        maxCharsBefore = Int(args[i + 1]) ?? 1000
    } else if args[i] == "--after" && i + 1 < args.count {
        maxCharsAfter = Int(args[i + 1]) ?? 1000
    }
}

let result = getCursorContext(maxCharsBefore: maxCharsBefore, maxCharsAfter: maxCharsAfter)

let encoder = JSONEncoder()
if let jsonData = try? encoder.encode(result),
   let jsonString = String(data: jsonData, encoding: .utf8) {
    print(jsonString)
}
