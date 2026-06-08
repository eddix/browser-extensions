import AppKit
import NodiaCore

enum ActivationResult {
    case activated         // found & selected the tab in Arc
    case openedFallback    // not found live → opened the URL (new tab / launches Arc)
    case permissionDenied  // Automation permission missing
    case failed
}

/// Activates a tab in Arc: find it by URL within its Space, `select` it,
/// `focus` the Space, and raise Arc. Falls back to `open <url>` when the tab
/// isn't live (closed/moved) or Arc isn't running.
enum Activator {
    static func activate(_ tab: TabEntry) -> ActivationResult {
        let escaped = tab.url
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
        tell application "Arc"
            activate
            repeat with w in windows
                repeat with s in spaces of w
                    try
                        repeat with t in tabs of s
                            if (URL of t) is "\(escaped)" then
                                tell s to focus
                                select t
                                return "ok"
                            end if
                        end repeat
                    end try
                end repeat
            end repeat
        end tell
        return "notfound"
        """

        if let script = NSAppleScript(source: source) {
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let code = (errorInfo["NSAppleScriptErrorNumber"] as? Int) ?? 0
                if code == -1743 { return .permissionDenied }
                // any other error → fall through to URL fallback
            } else if result.stringValue == "ok" {
                return .activated
            }
        }

        if let url = URL(string: tab.url) {
            NSWorkspace.shared.open(url)
            return .openedFallback
        }
        return .failed
    }
}
