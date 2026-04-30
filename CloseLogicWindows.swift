import Foundation
import ApplicationServices
import AppKit

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else { exit(1) }
let pid = app.processIdentifier
let logic = AXUIElementCreateApplication(pid)
// Keep Logic's own built-in windows — only plugin windows (instrument/effect names) need closing.
// These are the standard Logic Pro window titles that should never be closed.
let keep = [" - Tracks", ".logicx", "Logic Pro", "Choose a Project",
            "Mixer", "Piano Roll", "Score", "Event List", "Step Sequencer",
            "Sample Editor", "Environment", "Tempo Track", "Markers",
            "Loop Browser", "File Browser", "Audio File Browser",
            "Inspector", "Library", "Smart Controls", "Note Pad"]

func axVal(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v
}

func osascript(_ script: String, timeout: Double = 5.0) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    try? p.run()
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if p.isRunning { p.terminate() }
}

func axCloseAll() -> Int {
    var closed = 0
    // "AXAllWindows" works across Spaces — "AXWindows" blocks 30s when Logic is on a different Space
    let wins: [AXUIElement] = (axVal(logic, "AXAllWindows") as? [AXUIElement])
                           ?? (axVal(logic, "AXWindows")    as? [AXUIElement])
                           ?? []
    if !wins.isEmpty {
        for w in wins {
            let t = (axVal(w, "AXTitle") as? String) ?? ""
            if keep.contains(where: { t.contains($0) }) { continue }
            var closeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, "AXCloseButton" as CFString, &closeRef)
            if let btn = closeRef {
                AXUIElementPerformAction(btn as! AXUIElement, "AXPress" as CFString)
                closed += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
    return closed
}

func cgWindowsRemaining() -> [String] {
    var found: [String] = []
    if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
        for info in list {
            guard let wpid = info[kCGWindowOwnerPID as String] as? Int32, wpid == pid else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }
            let name = info[kCGWindowName as String] as? String ?? ""
            if name.isEmpty || keep.contains(where: { name.contains($0) }) { continue }
            found.append(name)
        }
    }
    return found
}

// ── Fast pre-check via CGWindowList only (no AX call — never blocks) ──────────────────
// AXUIElementCopyAttributeValue("AXWindows") blocks 30s when Logic is on a different Space.
// CGWindowListCopyWindowInfo queries the window server directly — always <5ms.
if cgWindowsRemaining().isEmpty {
    print(0)
    exit(0)
}

// ── There are windows to close: run full flow ──────────────────────────────
var totalClosed = 0

// Use Logic's own "Hide All Plug-in Windows" (catches Carbon/legacy AU windows
// like Quantec that don't appear in AXWindows or CGWindowList by name)
osascript("""
tell application "System Events"
    tell process "Logic Pro"
        set frontmost to true
        delay 0.2
        try
            click menu item "Hide All Plug-in Windows" of menu "Window" of menu bar 1
        end try
    end tell
end tell
""")
Thread.sleep(forTimeInterval: 0.3)

for _ in 1...5 {
    totalClosed += axCloseAll()
    let remaining = cgWindowsRemaining()
    if remaining.isEmpty { break }

    // Hide EasyBounce, do all menu clicks, show EasyBounce
    osascript("tell application \"System Events\" to set visible of process \"EasyBounce\" to false")
    Thread.sleep(forTimeInterval: 0.3)

    for name in remaining {
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        osascript("tell application \"System Events\" to tell process \"Logic Pro\"\nset frontmost to true\ntry\nclick menu item \"\(escaped)\" of menu \"Window\" of menu bar 1\nend try\nend tell")
        Thread.sleep(forTimeInterval: 0.5)
        totalClosed += axCloseAll()
        Thread.sleep(forTimeInterval: 0.2)
    }

    osascript("tell application \"System Events\" to set visible of process \"EasyBounce\" to true")
    Thread.sleep(forTimeInterval: 0.2)
}

print(totalClosed)
