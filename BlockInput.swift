import CoreGraphics
import Foundation

// BlockInput — blocks real user mouse/keyboard input for N milliseconds.
// AppleScript / AX events (stateID != 1) pass through freely.
// Usage: BlockInput <milliseconds>   (default: 2000)

let ms = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 2000
let duration = Double(ms) / 1000.0

var tap: CFMachPort? = nil

let callback: CGEventTapCallBack = { _, _, event, _ in
    // stateID == 1  → real hardware/user input → block it
    // stateID != 1  → synthetic (AppleScript, AX, CGEvent from code) → allow
    guard event.getIntegerValueField(.eventSourceStateID) == 1 else {
        return Unmanaged.passRetained(event)
    }
    return nil  // swallow user event
}

let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
    | (1 << CGEventType.leftMouseUp.rawValue)
    | (1 << CGEventType.rightMouseDown.rawValue)
    | (1 << CGEventType.rightMouseUp.rawValue)
    | (1 << CGEventType.mouseMoved.rawValue)
    | (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.keyUp.rawValue)
    | (1 << CGEventType.scrollWheel.rawValue)

tap = CGEvent.tapCreate(
    tap:              .cgSessionEventTap,
    place:            .headInsertEventTap,
    options:          .defaultTap,
    eventsOfInterest: mask,
    callback:         callback,
    userInfo:         nil
)

if let tap = tap {
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    // Block for the requested duration, then stop
    DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
    CFRunLoopRun()
}
