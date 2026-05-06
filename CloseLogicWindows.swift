import Foundation
import ApplicationServices
import AppKit

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first else { exit(1) }
let pid = app.processIdentifier
let logic = AXUIElementCreateApplication(pid)
// Keep ONLY the main Tracks window (which contains the embedded mixer panel).
// Everything else — separate Mixer windows, Piano Roll, plugins, browsers, etc. —
// gets closed so nothing overlaps the embedded mixer during scanning.
let keep = [" - Tracks"]

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
    // Use AXWindows — fast on same Space (we're always there after moveToLogicSpace).
    // AXAllWindows returns 0 for Logic in practice, so it's not a useful fallback.
    let wins: [AXUIElement] = (axVal(logic, "AXWindows") as? [AXUIElement]) ?? []
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

// ── Always try AX close — fast-path removed because cgWindowsRemaining()
//    returns empty without Screen Recording permission, falsely triggering
//    early exit and leaving plugin windows open.
// ── "Hide All Plug-in Windows" toggle removed — it was bringing already-hidden
//    plugin windows back to the front instead of closing them.
var totalClosed = 0

// AX-only iterative close — runs until nothing more closes (max 3 passes).
// Carbon/legacy plugins without AXCloseButton aren't handled (rare).
// Removed osascript "click menu item" fallback that took 5s × N windows = 30s+.
for _ in 1...3 {
    let n = axCloseAll()
    totalClosed += n
    if n == 0 { break }  // nothing left we can close
    Thread.sleep(forTimeInterval: 0.15)
}

print(totalClosed)
