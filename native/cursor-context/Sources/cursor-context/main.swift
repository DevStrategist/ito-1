import AppKit
import Foundation

// MARK: - Data Structures

struct Command: Codable {
    let command: String
    let options: Options?
    let requestId: String

    struct Options: Codable {
        let maxCharsBefore: Int?
        let maxCharsAfter: Int?
        let timeout: Int?
    }
}

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

struct Response: Codable {
    let type: String
    let requestId: String?
    let result: CursorContextResult?
    let error: String?
    let id: String?
    let timestamp: String?
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
            error: "No focused text element found",
            method: "accessibility"
        )
    }

    // Get the full text value
    guard let fullText = getAttributeValue(focusedElement, kAXValueAttribute as String) as? String else {
        return CursorContextResult(
            success: false,
            context: nil,
            error: "Unable to retrieve text value from focused element",
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

// MARK: - JSON I/O

func sendResponse(_ response: Response) {
    let encoder = JSONEncoder()
    if let jsonData = try? encoder.encode(response),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
        fflush(stdout)
    }
}

func sendHeartbeat(id: Int) {
    let response = Response(
        type: "heartbeat_ping",
        requestId: nil,
        result: nil,
        error: nil,
        id: String(id),
        timestamp: ISO8601DateFormatter().string(from: Date())
    )
    sendResponse(response)
}

// MARK: - Command Processing

func processCommand(_ command: Command) {
    switch command.command {
    case "get-context":
        let maxCharsBefore = command.options?.maxCharsBefore ?? 1000
        let maxCharsAfter = command.options?.maxCharsAfter ?? 1000

        let result = getCursorContext(maxCharsBefore: maxCharsBefore, maxCharsAfter: maxCharsAfter)

        let response = Response(
            type: "context-result",
            requestId: command.requestId,
            result: result,
            error: nil,
            id: nil,
            timestamp: nil
        )
        sendResponse(response)

    default:
        let response = Response(
            type: "error",
            requestId: command.requestId,
            result: nil,
            error: "Unknown command: \(command.command)",
            id: nil,
            timestamp: nil
        )
        sendResponse(response)
    }
}

// MARK: - Main Loop

func main() {
    let decoder = JSONDecoder()

    // Start heartbeat thread
    var heartbeatId = 0
    DispatchQueue.global(qos: .background).async {
        while true {
            Thread.sleep(forTimeInterval: 10.0)
            heartbeatId += 1
            sendHeartbeat(id: heartbeatId)
        }
    }

    // Main command processing loop
    while let line = readLine() {
        guard let data = line.data(using: .utf8) else { continue }

        do {
            let command = try decoder.decode(Command.self, from: data)
            processCommand(command)
        } catch {
            fputs("Error parsing command: \(error)\n", stderr)
            fflush(stderr)
        }
    }
}

// Run the main loop
main()
