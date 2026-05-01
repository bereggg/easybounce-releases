import AppKit
import CoreGraphics
import Foundation

// EasyBounce hides itself before calling this binary, so Logic is already
// the frontmost app. Just activate to be safe, then send Escape immediately.
if let logic = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.logic10").first {
  logic.activate(options: [])
  usleep(100_000) // 100ms
}

let src  = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)!
let up   = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)!
down.post(tap: .cghidEventTap)
usleep(50_000)
up.post(tap: .cghidEventTap)
