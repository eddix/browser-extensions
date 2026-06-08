import AppKit
import NodiaCore

enum DedupeResult {
    case closed(Int)
    case permissionDenied
    case failed
}

/// Closes redundant tabs in Arc via AppleScript. For each `(url, space)` it
/// closes exactly as many matching tabs as there are duplicates there, so the
/// keeper (which is never in `duplicates`) survives. Identical-URL copies are
/// interchangeable, so it doesn't matter which physical tab remains.
enum Deduper {
    static func execute(closing duplicates: [TabEntry]) -> DedupeResult {
        guard !duplicates.isEmpty else { return .closed(0) }

        // Aggregate how many tabs to close per (url, space).
        var counts: [String: Int] = [:]
        var ops: [(url: String, space: String)] = []
        for tab in duplicates {
            let key = tab.url + "\u{0}" + tab.spaceTitle
            if counts[key] == nil { ops.append((tab.url, tab.spaceTitle)) }
            counts[key, default: 0] += 1
        }

        var blocks = ""
        for op in ops {
            let n = counts[op.url + "\u{0}" + op.space] ?? 0
            blocks += """
                repeat \(n) times
                    set didClose to false
                    repeat with w in windows
                        if didClose then exit repeat
                        repeat with sp in spaces of w
                            if didClose then exit repeat
                            try
                                if (title of sp) is "\(escape(op.space))" then
                                    repeat with t in tabs of sp
                                        if (URL of t) is "\(escape(op.url))" then
                                            close t
                                            set closedCount to closedCount + 1
                                            set didClose to true
                                            exit repeat
                                        end if
                                    end repeat
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat

            """
        }

        let source = """
        tell application "Arc"
            set closedCount to 0
        \(blocks)
            return closedCount
        end tell
        """

        var errorInfo: NSDictionary?
        if let script = NSAppleScript(source: source) {
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let code = (errorInfo["NSAppleScriptErrorNumber"] as? Int) ?? 0
                Log.write("dedupe FAILED (code \(code)): \(errorInfo["NSAppleScriptErrorMessage"] ?? "")")
                return code == -1743 ? .permissionDenied : .failed
            }
            let closed = Int(result.int32Value)
            Log.write("dedupe: closed \(closed) duplicate tabs")
            return .closed(closed)
        }
        return .failed
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
