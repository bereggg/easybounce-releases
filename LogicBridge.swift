import Foundation
import ApplicationServices
import AppKit
import Carbon

func axVal(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v
}

func axKids(_ e: AXUIElement) -> [AXUIElement] {
    (axVal(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func axRole(_ e: AXUIElement) -> String { (axVal(e, kAXRoleAttribute) as? String) ?? "" }
func axTitle(_ e: AXUIElement) -> String {
    if let s = axVal(e, kAXTitleAttribute) as? String, !s.isEmpty { return s }
    if let s = axVal(e, kAXDescriptionAttribute) as? String, !s.isEmpty { return s }
    if let s = axVal(e, kAXValueAttribute) as? String, !s.isEmpty { return s }
    return ""
}
func axPress(_ e: AXUIElement) { AXUIElementPerformAction(e, kAXPressAction as CFString) }
func axIntValue(_ e: AXUIElement) -> Int {
    if let v = axVal(e, kAXValueAttribute) {
        if let i = v as? Int      { return i }
        if let b = v as? Bool     { return b ? 1 : 0 }
        if let n = v as? NSNumber { return n.intValue }
        // Logic Pro solo/mute buttons (AXSwitch) return "on" / "off" strings
        if let s = v as? String {
            if s == "on" || s == "1" || s == "true" { return 1 }
            return Int(s) ?? 0
        }
    }
    if let v = axVal(e, kAXSelectedAttribute) {
        if let b = v as? Bool     { return b ? 1 : 0 }
        if let n = v as? NSNumber { return n.intValue }
    }
    return 0
}

// ── Intel detection: increase timeouts on x86_64 ──
#if arch(x86_64)
let kTimingMultiplier: Double = 1.5  // Intel Macs need ~50% more time
#else
let kTimingMultiplier: Double = 1.0  // Apple Silicon — normal timing
#endif

func tsleep(_ base: Double) { Thread.sleep(forTimeInterval: base * kTimingMultiplier) }

// ── AppleScript via osascript (avoids registering LogicBridge as separate TCC entity) ──
@discardableResult
func runScript(_ src: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", src]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// ── Mouse safety: clamp coordinates to screen bounds ──
func clampToScreen(_ pt: CGPoint) -> CGPoint {
    guard let screen = NSScreen.main else { return pt }
    let f = screen.frame
    let x = min(max(pt.x, f.origin.x + 5), f.origin.x + f.width - 5)
    let y = min(max(pt.y, 25), f.origin.y + f.height - 5) // 25 = below menu bar
    return CGPoint(x: x, y: y)
}

// Clamp to Logic's own window bounds (more restrictive)
func clampToLogicWindow(_ pt: CGPoint, _ logic: AXUIElement) -> CGPoint {
    guard let wins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement],
          let win = wins.first else { return clampToScreen(pt) }
    var posRef: CFTypeRef?; var szRef: CFTypeRef?
    AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
    AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &szRef)
    var pos = CGPoint.zero; var sz = CGSize.zero
    if let pv = posRef { AXValueGetValue(pv as! AXValue, .cgPoint, &pos) }
    if let sv = szRef  { AXValueGetValue(sv as! AXValue, .cgSize,  &sz) }
    if sz.width < 100 || sz.height < 100 { return clampToScreen(pt) }
    let x = min(max(pt.x, pos.x + 5), pos.x + sz.width - 5)
    let y = min(max(pt.y, pos.y + 5), pos.y + sz.height - 5)
    return CGPoint(x: x, y: y)
}

// ── Track Tree helpers ──

private let kOpenQuotes = CharacterSet(charactersIn: "\"\u{201C}\u{2018}")
private let kCloseQuotes = CharacterSet(charactersIn: "\"\u{201D}\u{2019}")

struct TrackInfo {
    let num: Int
    let name: String
    let muted: Bool
    let hasTriangle: Bool
}

func parseTrackDesc(_ desc: String) -> (num: Int, name: String, muted: Bool)? {
    guard desc.hasPrefix("Track ") else { return nil }
    let rest = desc.dropFirst(6)
    guard let sp = rest.firstIndex(of: " "),
          let num = Int(String(rest[..<sp])) else { return nil }
    var name = String(rest[rest.index(after: sp)...])
    if let ci = name.firstIndex(of: ",") { name = String(name[..<ci]) }
    name = name.trimmingCharacters(in: kOpenQuotes.union(kCloseQuotes))
               .trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return nil }
    let muted = desc.contains(", mute")
    return (num, name, muted)
}

func findTracksHeader(_ logicApp: AXUIElement) -> AXUIElement? {
    let wins = (axVal(logicApp, kAXWindowsAttribute) as? [AXUIElement]) ?? axKids(logicApp)
    func dfs(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
        if depth > 10 { return nil }
        if axRole(el) == "AXScrollArea" {
            for kid in axKids(el) {
                if (axVal(kid, kAXDescriptionAttribute) as? String) == "Tracks contents" { return kid }
            }
        }
        for kid in axKids(el) { if let r = dfs(kid, depth + 1) { return r } }
        return nil
    }
    for win in wins { if let r = dfs(win, 0) { return r } }
    return nil
}

// Detect disclosure triangle — AXDisclosureTriangle on M1/newer Logic,
// or bare AXButton (no title, no desc) on Intel Logic Pro X 10.7
func isDisclosureTriangle(_ el: AXUIElement) -> Bool {
    let role = axRole(el)
    if role == "AXDisclosureTriangle" { return true }
    if role == "AXButton" {
        let desc = (axVal(el, kAXDescriptionAttribute) as? String) ?? ""
        let title = (axVal(el, kAXTitleAttribute) as? String) ?? ""
        if desc.isEmpty && title.isEmpty { return true }
    }
    return false
}

func readTrackInfos(_ header: AXUIElement) -> [TrackInfo] {
    axKids(header).compactMap { item -> TrackInfo? in
        let desc = (axVal(item, kAXDescriptionAttribute) as? String) ?? ""
        guard let t = parseTrackDesc(desc) else { return nil }
        let hasTri = axKids(item).contains { isDisclosureTriangle($0) }
        return TrackInfo(num: t.num, name: t.name, muted: t.muted, hasTriangle: hasTri)
    }
}

// Read which track numbers have disclosure triangles from the header GROUP element
// (triangles are in "Tracks header", not "Tracks contents")
func readTriangleNums(_ headerGroup: AXUIElement) -> Set<Int> {
    var result = Set<Int>()
    for item in axKids(headerGroup) {
        let desc = (axVal(item, kAXDescriptionAttribute) as? String) ?? ""
        guard desc.hasPrefix("Track "), let t = parseTrackDesc(desc) else { continue }
        if axKids(item).contains(where: { isDisclosureTriangle($0) }) {
            result.insert(t.num)
        }
    }
    return result
}

// Send key event directly to Logic Pro process (no focus needed)
func sendKeyToLogic(_ pid: pid_t, keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let dn = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
    dn.flags = flags
    up.flags = []
    dn.postToPid(pid)
    Thread.sleep(forTimeInterval: 0.05)
    up.postToPid(pid)
}

// Click AX button without moving mouse
func axClickDirect(_ e: AXUIElement) {
    AXUIElementPerformAction(e, kAXPressAction as CFString)
}

// Type text directly into Logic process
func typeTextToLogic(_ pid: pid_t, _ text: String) {
    for char in text.unicodeScalars {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let dn = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
        dn.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char.value)])
        up.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char.value)])
        dn.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.02)
        up.postToPid(pid)
    }
}

func findAll(_ e: AXUIElement, role: String, title: String? = nil, depth: Int = 20) -> [AXUIElement] {
    if depth == 0 { return [] }
    var results: [AXUIElement] = []
    if axRole(e) == role && (title == nil || axTitle(e) == title) { results.append(e) }
    for c in axKids(e) { results += findAll(c, role: role, title: title, depth: depth-1) }
    return results
}

// Mixer filter modes:
// Mode 1 (dropdown): AXMenuButton — default Logic Pro mixer
// Mode 2 (inline):   AXGroup with AXCheckBox children — after Forte! or certain Logic configs
enum MixerMode {
    case dropdown(AXUIElement)   // Mode 1: click to open menu
    case inline_(AXUIElement)    // Mode 2: direct checkboxes, no menu needed
}

func findMixerFilterControl(_ logicApp: AXUIElement) -> MixerMode? {
    let filterKeywords: Set<String> = ["All", "Audio", "Inst", "Aux", "Bus", "Input", "Output", "Master", "MIDI",
                                       "Software Instrument", "External Instrument"]

    // Search recursively for filter control inside a mixer element
    func searchInMixer(_ mixer: AXUIElement) -> MixerMode? {
        func search(_ el: AXUIElement, depth: Int) -> MixerMode? {
            if depth == 0 { return nil }
            let role = axRole(el)
            if role == "AXMenuButton" {
                // Filter button title = currently selected filter (e.g. "All", "Audio")
                // Options/View/Edit buttons have their own names — won't match filterKeywords
                let title = (axVal(el, kAXTitleAttribute) as? String) ?? ""
                if filterKeywords.contains(title) { return .dropdown(el) }
            } else if role == "AXGroup" {
                let cbs = axKids(el).filter { axRole($0) == "AXCheckBox" }
                let labels = cbs.map { cb -> String in
                    let t = (axVal(cb, kAXTitleAttribute) as? String) ?? ""
                    return t.isEmpty ? ((axVal(cb, kAXDescriptionAttribute) as? String) ?? "") : t
                }
                if labels.contains(where: { filterKeywords.contains($0) }) { return .inline_(el) }
            }
            for child in axKids(el) {
                if let found = search(child, depth: depth - 1) { return found }
            }
            return nil
        }
        return search(mixer, depth: 5)
    }

    guard let windows = axVal(logicApp, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    for win in windows {
        // Method 1: via AXLayoutArea "Mixer" (same as scanChannels)
        let layouts = findAll(win, role: "AXLayoutArea", title: "Mixer")
        if let mixerLayout = layouts.max(by: { axKids($0).count < axKids($1).count }) {
            if let found = searchInMixer(mixerLayout) { return found }
        }
        // Method 2: fallback — AXGroup with description "Mixer"
        let groups = findAll(win, role: "AXGroup", depth: 6)
        for g in groups where (axVal(g, kAXDescriptionAttribute) as? String) == "Mixer" {
            if let found = searchInMixer(g) { return found }
        }
    }
    return nil
}

// Backward-compat wrapper
func findMixerMenuButton(_ logicApp: AXUIElement) -> AXUIElement? {
    if case .dropdown(let mb) = findMixerFilterControl(logicApp) { return mb }
    return nil
}

// Open mixer filter menu and collect all item states. Closes menu with Escape.
func readMixerFilterStates(_ mb: AXUIElement) -> [String: Bool]? {
    axPress(mb)
    Thread.sleep(forTimeInterval: 0.35)
    guard let m = axKids(mb).first(where: { axRole($0) == "AXMenu" }) else {
        var pid: pid_t = 0; AXUIElementGetPid(mb, &pid)
        let src = CGEventSource(stateID: .hidSystemState)
        if let dn = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) {
            dn.postToPid(pid); up.postToPid(pid)
        }
        return nil
    }
    var filters: [String: Bool] = [:]
    for item in axKids(m) {
        let title = (axVal(item, kAXTitleAttribute) as? String) ?? ""
        guard !title.isEmpty else { continue }
        let mark = axVal(item, "AXMenuItemMarkChar") as? String
        filters[title] = (mark == "✓")
    }
    // Close menu
    var pid: pid_t = 0; AXUIElementGetPid(mb, &pid)
    let src = CGEventSource(stateID: .hidSystemState)
    if let dn = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true),
       let up = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) {
        dn.postToPid(pid); up.postToPid(pid)
    }
    Thread.sleep(forTimeInterval: 0.1)
    return filters
}

func activateLogic() {
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", "tell application id \"com.apple.logic10\" to activate"]
    task.launch()
    task.waitUntilExit()
    Thread.sleep(forTimeInterval: 1.0)
}

func getLogicPid() -> pid_t {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first {
        return app.processIdentifier
    }
    return 0
}

struct Channel {
    let name: String
    let index: Int
    let muteBtn: AXUIElement
    let soloBtn: AXUIElement
    let isBus: Bool
    let hasMonitoring: Bool
    let hasRecord: Bool
    let hasBnc: Bool
}

func scanChannels(_ logicApp: AXUIElement) -> [Channel] {
    var wins: CFTypeRef?
    AXUIElementCopyAttributeValue(logicApp, kAXWindowsAttribute as CFString, &wins)
    guard let windows = wins as? [AXUIElement] else { return [] }

    for win in windows {
        let allLayouts = findAll(win, role: "AXLayoutArea", title: "Mixer")
        guard let mixerLayout = allLayouts.max(by: { axKids($0).count < axKids($1).count }) else { continue }
        
        let items = axKids(mixerLayout).filter { axRole($0) == "AXLayoutItem" }
        guard items.count > 1 else { continue }
        
        var channels: [Channel] = []

        for item in items {
            let kids = axKids(item)
            // Single pass through kids - collect all needed elements at once
            var nameField: AXUIElement? = nil
            var muteBtn: AXUIElement? = nil
            var soloBtn: AXUIElement? = nil
            var hasMonitoring = false
            var hasRecord = false

            var hasBnc = false
            for kid in kids {
                let role = axRole(kid)
                let title = axTitle(kid)
                if role == "AXTextField" && title == "name" { nameField = kid }
                else if role == "AXButton" {
                    switch title {
                    case "mute": muteBtn = kid
                    case "solo": soloBtn = kid
                    case "Bnc": soloBtn = kid; hasBnc = true
                    case "monitoring": hasMonitoring = true
                    case "record": hasRecord = true
                    default: break
                    }
                }
            }

            guard let nf = nameField, let mb = muteBtn, let sb = soloBtn else { continue }

            var nameVal: CFTypeRef?
            AXUIElementCopyAttributeValue(nf, kAXValueAttribute as CFString, &nameVal)
            let name = (nameVal as? String) ?? ""
            guard !name.isEmpty else { continue }
            // Keep original name — duplicates are distinguished by index, not name

            let isBus = !hasMonitoring && !hasRecord
            channels.append(Channel(name: name, index: channels.count,
                                    muteBtn: mb, soloBtn: sb, isBus: isBus,
                                    hasMonitoring: hasMonitoring, hasRecord: hasRecord,
                                    hasBnc: hasBnc))
        }
        if !channels.isEmpty { return channels }
    }
    return []
}

func findLogic() -> AXUIElement? {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10")
    if let a = apps.first { return AXUIElementCreateApplication(a.processIdentifier) }
    for a in NSWorkspace.shared.runningApplications where a.localizedName == "Logic Pro" {
        return AXUIElementCreateApplication(a.processIdentifier)
    }
    return nil
}

func jsonOut(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
       let str = String(data: data, encoding: .utf8) { print(str) }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: LogicBridge scan|soloIndex <n>|unsoloIndex <n>|muteIndex <n>|unmuteIndex <n>|unsoloAll|unmuteAll|bounce\n", stderr)
    exit(1)
}
guard let logic = findLogic() else { jsonOut(["error": "Logic Pro is not running"]); exit(1) }

// Detect actual process name (Logic Pro vs Logic Pro X)
var _logicPid: pid_t = 0; AXUIElementGetPid(logic, &_logicPid)
let logicAppName = NSRunningApplication(processIdentifier: _logicPid)?.localizedName ?? "Logic Pro"

let cmd = args[1]

// ── Find a toolbar checkbox by its title or description ─────────────────────────────────────────
func findCheckboxByLabel(_ el: AXUIElement, label: String, depth: Int = 0) -> AXUIElement? {
    if depth > 6 { return nil }
    if axRole(el) == "AXCheckBox" {
        let t = axVal(el, kAXTitleAttribute) as? String ?? ""
        let d = axVal(el, kAXDescriptionAttribute) as? String ?? ""
        if t == label || d == label { return el }
    }
    for child in axKids(el) {
        if let f = findCheckboxByLabel(child, label: label, depth: depth + 1) { return f }
    }
    return nil
}

// ── Click first visible track in Arrange to select it (so Inspector shows its MASTER output) ────
func clickFirstArrangeTrack(_ logicApp: AXUIElement) -> Bool {
    guard let header = findTracksHeader(logicApp) else { return false }
    let screenH = NSScreen.main?.frame.height ?? 2000
    for item in axKids(header) {
        let desc = axVal(item, kAXDescriptionAttribute) as? String ?? ""
        guard desc.hasPrefix("Track ") else { continue }
        var posRef: CFTypeRef?; var szRef: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &szRef)
        var pt = CGPoint.zero; var sz = CGSize.zero
        if let pv = posRef { AXValueGetValue(pv as! AXValue, .cgPoint, &pt) }
        if let sv = szRef { AXValueGetValue(sv as! AXValue, .cgSize, &sz) }
        guard pt.y > 50 && pt.y < screenH - 50 else { continue }
        let cursor = CGPoint(x: pt.x + sz.width / 2, y: pt.y + sz.height / 2)
        let src = CGEventSource(stateID: .hidSystemState)
        if let dn = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: cursor, mouseButton: .left),
           let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: cursor, mouseButton: .left) {
            dn.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.05)
            up.post(tap: .cghidEventTap)
            return true
        }
    }
    return false
}

// ── Inspector MASTER: read from Arrange window Inspector (no scroll needed) ────────────────────
/// Finds the MASTER AXLayoutItem in Logic's Inspector panel (Arrange window).
/// Inspector always shows the selected track + its output (MASTER), so no Mixer scroll needed.
func findInspectorMaster(_ logic: AXUIElement) -> AXUIElement? {
    guard let wins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    for win in wins {
        for kid in axKids(win) {
            guard axRole(kid) == "AXGroup",
                  (axVal(kid, kAXDescriptionAttribute) as? String ?? "") == "Inspector" else { continue }
            for list in axKids(kid) {
                guard axRole(list) == "AXList" else { continue }
                for section in axKids(list) {
                    for la in axKids(section) {
                        guard axRole(la) == "AXLayoutArea",
                              (axVal(la, kAXDescriptionAttribute) as? String ?? "") == "Mixer" else { continue }
                        for item in axKids(la) {
                            guard axRole(item) == "AXLayoutItem" else { continue }
                            let hasBounce = axKids(item).contains {
                                axRole($0) == "AXButton" &&
                                (axVal($0, kAXDescriptionAttribute) as? String ?? "") == "bounce"
                            }
                            if hasBounce { return item }
                        }
                    }
                }
            }
        }
    }
    return nil
}

/// Returns sorted plugin groups (top→bottom) with bypass state from a MASTER AXLayoutItem
func pluginsFromMasterItem(_ masterItem: AXUIElement) -> [[String: Any]] {
    let groups = axKids(masterItem).filter { kid -> Bool in
        guard axRole(kid) == "AXGroup" else { return false }
        let name = axVal(kid, kAXDescriptionAttribute) as? String ?? ""
        guard !name.isEmpty else { return false }
        return axKids(kid).contains { axRole($0) == "AXCheckBox" && (axVal($0, kAXDescriptionAttribute) as? String ?? "") == "bypass" }
    }
    let sorted = groups.sorted {
        var p1: CFTypeRef?; AXUIElementCopyAttributeValue($0, kAXPositionAttribute as CFString, &p1)
        var p2: CFTypeRef?; AXUIElementCopyAttributeValue($1, kAXPositionAttribute as CFString, &p2)
        var pt1 = CGPoint.zero; var pt2 = CGPoint.zero
        if let av = p1 { AXValueGetValue(av as! AXValue, .cgPoint, &pt1) }
        if let av = p2 { AXValueGetValue(av as! AXValue, .cgPoint, &pt2) }
        return pt1.y < pt2.y
    }
    return sorted.map { g in
        let name = axVal(g, kAXDescriptionAttribute) as? String ?? ""
        let bypassEl = axKids(g).first { axRole($0) == "AXCheckBox" && (axVal($0, kAXDescriptionAttribute) as? String ?? "") == "bypass" }
        let val = bypassEl.map { axIntValue($0) } ?? 0
        return ["name": name, "active": val == 0]
    }
}

// ── Find Stereo Out in Mixer (reliable — tries multiple names + rightmost fallback) ──────────
// Quick find Stereo Out — no scrolling, just check existing AX items (fast for toggle operations)
func findStereoOutQuick(_ logicApp: AXUIElement) -> AXUIElement? {
    guard let wins = axVal(logicApp, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    var mixer: AXUIElement? = nil
    for w in wins {
        if let found = findAll(w, role: "AXLayoutArea", depth: 10).first(where: {
            (axVal($0, kAXDescriptionAttribute) as? String ?? "").contains("Mixer")
        }) { mixer = found; break }
    }
    guard let mixer = mixer else { return nil }
    let items = findAll(mixer, role: "AXLayoutItem", depth: 3)
    // Try by AXDescription
    if let ch = items.first(where: {
        let desc = (axVal($0, kAXDescriptionAttribute) as? String ?? "").uppercased()
        return desc == "MASTER" || desc == "STEREO OUT"
    }) { return ch }
    // Try by channel name text field
    let stereoOutNames = ["Stereo Out", "Stereo Output", "Output", "Output 1-2", "Master"]
    for item in items {
        if let nf = axKids(item).first(where: { axRole($0) == "AXTextField" && axTitle($0) == "name" }) {
            var nameVal: CFTypeRef?
            AXUIElementCopyAttributeValue(nf, kAXValueAttribute as CFString, &nameVal)
            let name = (nameVal as? String ?? "").trimmingCharacters(in: .whitespaces)
            if stereoOutNames.contains(where: { name.localizedCaseInsensitiveCompare($0) == .orderedSame }) {
                return item
            }
        }
    }
    return nil
}

// Full find with scroll — used for scanMasterPlugins when we need to guarantee finding it
func findStereoOutInMixer(_ logicApp: AXUIElement) -> AXUIElement? {
    // Try quick find first (no scroll)
    if let quick = findStereoOutQuick(logicApp) { return quick }
    // Fall back to scroll + search
    guard let wins = axVal(logicApp, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    var mixer: AXUIElement? = nil
    for w in wins {
        if let found = findAll(w, role: "AXLayoutArea", depth: 10).first(where: {
            (axVal($0, kAXDescriptionAttribute) as? String ?? "").contains("Mixer")
        }) { mixer = found; break }
    }
    guard let mixer = mixer else { return nil }

    // Scroll to rightmost to reveal Stereo Out
    var parentRef: CFTypeRef?
    AXUIElementCopyAttributeValue(mixer, kAXParentAttribute as CFString, &parentRef)
    if let scrollArea = parentRef as! AXUIElement? {
        var hBar: CFTypeRef?
        AXUIElementCopyAttributeValue(scrollArea, kAXHorizontalScrollBarAttribute as CFString, &hBar)
        if let bar = hBar as! AXUIElement? {
            AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 1.0 as CFTypeRef)
        }
        var vBar: CFTypeRef?
        AXUIElementCopyAttributeValue(scrollArea, kAXVerticalScrollBarAttribute as CFString, &vBar)
        if let bar = vBar as! AXUIElement? {
            AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 0.0 as CFTypeRef)
        }
    }
    Thread.sleep(forTimeInterval: 0.3)

    let items = findAll(mixer, role: "AXLayoutItem", depth: 3)

    // Try by AXDescription
    if let ch = items.first(where: {
        let desc = (axVal($0, kAXDescriptionAttribute) as? String ?? "").uppercased()
        return desc == "MASTER" || desc == "STEREO OUT"
    }) { return ch }

    // Try by channel name text field
    let stereoOutNames = ["Stereo Out", "Stereo Output", "Output", "Output 1-2", "Master"]
    for item in items {
        if let nf = axKids(item).first(where: { axRole($0) == "AXTextField" && axTitle($0) == "name" }) {
            var nameVal: CFTypeRef?
            AXUIElementCopyAttributeValue(nf, kAXValueAttribute as CFString, &nameVal)
            let name = (nameVal as? String ?? "").trimmingCharacters(in: .whitespaces)
            if stereoOutNames.contains(where: { name.localizedCaseInsensitiveCompare($0) == .orderedSame }) {
                return item
            }
        }
    }

    // Fallback: find by bounce button (reliable regardless of channel name)
    if let bStrip = smpFindBounceStrip(mixer) { return bStrip }

    // Last resort: rightmost channel (Stereo Out is always last)
    return items.max(by: {
        var p1: CFTypeRef?; AXUIElementCopyAttributeValue($0, kAXPositionAttribute as CFString, &p1)
        var p2: CFTypeRef?; AXUIElementCopyAttributeValue($1, kAXPositionAttribute as CFString, &p2)
        var pt1 = CGPoint.zero; var pt2 = CGPoint.zero
        if let av = p1 { AXValueGetValue(av as! AXValue, .cgPoint, &pt1) }
        if let av = p2 { AXValueGetValue(av as! AXValue, .cgPoint, &pt2) }
        return pt1.x < pt2.x
    })
}

// ── Find Stereo Out by bounce button (most reliable — button is unique to Output channel) ──────
func findStereoOutByBounce(_ logicApp: AXUIElement) -> AXUIElement? {
    guard let wins = axVal(logicApp, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    let win = wins.first(where: { (axVal($0, kAXTitleAttribute) as? String ?? "").contains("Tracks") }) ?? wins.first
    guard let w = win else { return nil }
    var layouts: [AXUIElement] = []
    // smpFindAllMixerLayouts defined below — forward call is fine in Swift
    func _findLayouts(_ el: AXUIElement, depth: Int = 0) {
        if depth > 6 { return }
        if axRole(el) == "AXLayoutArea" && (axVal(el, kAXDescriptionAttribute) as? String) == "Mixer" { layouts.append(el) }
        for kid in axKids(el) { _findLayouts(kid, depth: depth + 1) }
    }
    _findLayouts(w)
    guard let mixer = layouts.max(by: { axSize($0).width < axSize($1).width }) else { return nil }
    // bounce button = unique to Output/Stereo Out channel
    for item in axKids(mixer) {
        for kid in axKids(item) {
            if axRole(kid) == "AXButton" {
                let desc  = (axVal(kid, kAXDescriptionAttribute) as? String ?? "").lowercased()
                let title = (axVal(kid, kAXTitleAttribute)       as? String ?? "").lowercased()
                if desc == "bounce" || title == "bnc" || title == "bounce" { return item }
            }
        }
    }
    return nil
}

// ── Mixer-based master plugin scan helpers ────────────────────────────────────────────────────
let MIXER_RATIO: Double = 0.60
func axPos(_ el: AXUIElement) -> CGPoint {
    var p = CGPoint.zero
    if let v = axVal(el, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    return p
}
func axSize(_ el: AXUIElement) -> CGSize {
    var s = CGSize.zero
    if let v = axVal(el, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return s
}

func smpPostScroll(at pt: CGPoint, w1: Int32, w2: Int32) {
    if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                        wheelCount: 2, wheel1: w1, wheel2: w2, wheel3: 0) {
        ev.location = pt
        ev.post(tap: .cghidEventTap)
    }
}
func activateLogicAndFocus(_ win: AXUIElement) {
    // 1. Activate via NSRunningApplication (faster than osascript)
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10")
        .first?.activate(options: .activateIgnoringOtherApps)
    Thread.sleep(forTimeInterval: 0.3)
    // 2. Raise window via AX
    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    Thread.sleep(forTimeInterval: 0.1)
    // 3. Real HID click on toolbar (top center) to steal OS focus
    var posRef: CFTypeRef?; var szRef: CFTypeRef?
    AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
    AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &szRef)
    var pos = CGPoint.zero; var sz = CGSize.zero
    if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    if let s = szRef  { AXValueGetValue(s as! AXValue, .cgSize,  &sz) }
    let safeClick = CGPoint(x: pos.x + sz.width / 2, y: pos.y + 15)
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
            mouseCursorPosition: safeClick, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
            mouseCursorPosition: safeClick, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.2)
}

func smpMoveMouse(_ pt: CGPoint) {
    CGWarpMouseCursorPosition(pt)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
}
func smpDrag(from s: CGPoint, to e: CGPoint) {
    CGWarpMouseCursorPosition(s); Thread.sleep(forTimeInterval: 0.2)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: s, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.15)
    for i in 0...50 {
        let t = Double(i) / 50.0
        let p = CGPoint(x: s.x + (e.x - s.x) * t, y: s.y + (e.y - s.y) * t)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.014)
    }
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: e, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.4)
}
func smpFindMixerGroup(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if depth > 6 { return nil }
    if axRole(el) == "AXGroup" && (axVal(el, kAXDescriptionAttribute) as? String) == "Mixer" { return el }
    for kid in axKids(el) { if let f = smpFindMixerGroup(kid, depth: depth + 1) { return f } }
    return nil
}
func smpFindAllMixerLayouts(_ el: AXUIElement, depth: Int = 0, results: inout [AXUIElement]) {
    if depth > 6 { return }
    if axRole(el) == "AXLayoutArea" && (axVal(el, kAXDescriptionAttribute) as? String) == "Mixer" { results.append(el) }
    for kid in axKids(el) { smpFindAllMixerLayouts(kid, depth: depth + 1, results: &results) }
}
func smpFindBounceStrip(_ mixer: AXUIElement) -> AXUIElement? {
    for item in axKids(mixer) {
        for kid in axKids(item) {
            if axRole(kid) == "AXButton" {
                let desc  = (axVal(kid, kAXDescriptionAttribute) as? String ?? "").lowercased()
                let title = (axVal(kid, kAXTitleAttribute)       as? String ?? "").lowercased()
                if desc == "bounce" || title == "bnc" || title == "bounce" { return item }
            }
        }
    }
    return nil
}

// ── Mixer helpers: find AXLayoutArea + named channel, resize+scroll for plugin reading ─────────
func findMixerAndChannel(_ logicApp: AXUIElement, channelName: String) -> (mixer: AXUIElement, channel: AXUIElement)? {
    var winsRef: CFTypeRef?
    AXUIElementCopyAttributeValue(logicApp, kAXWindowsAttribute as CFString, &winsRef)
    guard let wins = winsRef as? [AXUIElement], !wins.isEmpty else { return nil }
    var mixer: AXUIElement? = nil
    for w in wins {
        if let found = findAll(w, role: "AXLayoutArea", depth: 10).first(where: {
            (axVal($0, kAXDescriptionAttribute) as? String ?? "").contains("Mixer")
        }) { mixer = found; break }
    }
    guard let mixer = mixer else { return nil }
    guard let channel = findAll(mixer, role: "AXLayoutItem", depth: 3).first(where: {
        (axVal($0, kAXDescriptionAttribute) as? String ?? "").uppercased() == channelName.uppercased()
    }) else { return nil }
    return (mixer, channel)
}

func prepareMixerForPluginRead(_ mixer: AXUIElement, _ channel: AXUIElement) {
    // 1. Walk up to find mixer window — only resize if standalone Mixer window (not Logic main window)
    var walkEl: AXUIElement? = mixer
    for _ in 0..<8 {
        guard let el = walkEl else { break }
        if axRole(el) == "AXWindow" {
            // Check current window size: Logic main window is tall (>600px); standalone mixer is smaller
            var szRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &szRef)
            var sz = CGSize.zero
            if let av = szRef as! AXValue? { AXValueGetValue(av, .cgSize, &sz) }
            let isStandaloneMixer = sz.height < 550  // main Logic window is typically 700px+
            if isStandaloneMixer {
                var newSize = CGSize(width: 1100, height: 420)
                if let av = AXValueCreate(.cgSize, &newSize) {
                    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, av)
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            break
        }
        var p: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &p)
        walkEl = p.map { $0 as! AXUIElement }
    }
    // 2. Scroll: horizontal=rightmost(1.0), vertical=topmost(0.0) — show MASTER and inserts
    var parentRef: CFTypeRef?
    AXUIElementCopyAttributeValue(mixer, kAXParentAttribute as CFString, &parentRef)
    if let scrollArea = parentRef as! AXUIElement? {
        var hBar: CFTypeRef?
        AXUIElementCopyAttributeValue(scrollArea, kAXHorizontalScrollBarAttribute as CFString, &hBar)
        if let bar = hBar as! AXUIElement? {
            AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 1.0 as CFTypeRef)
        }
        var vBar: CFTypeRef?
        AXUIElementCopyAttributeValue(scrollArea, kAXVerticalScrollBarAttribute as CFString, &vBar)
        if let bar = vBar as! AXUIElement? {
            AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 0.0 as CFTypeRef)
        }
    }
    // 3. Scroll MASTER into view and select (without AXPress — avoids side effects in Logic)
    AXUIElementPerformAction(channel, "AXScrollToVisible" as CFString)
    Thread.sleep(forTimeInterval: 0.2)
    AXUIElementSetAttributeValue(channel, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    tsleep(0.6)  // Wait for Logic to render plugin names in AX
}

switch cmd {

case "status":
    // Read-only snapshot — never modifies anything
    var info: [String: Any] = [:]
    // Logic running?
    let logicApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10")
    info["logicRunning"] = !logicApps.isEmpty
    guard !logicApps.isEmpty else { jsonOut(info); break }
    // Frontmost app
    info["frontmost"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
    // Windows accessible?
    let wins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement] ?? []
    info["windowCount"] = wins.count
    guard let win = wins.first else { info["note"] = "no window (fullscreen/other space)"; jsonOut(info); break }
    // Window title & size
    info["windowTitle"] = axVal(win, kAXTitleAttribute) as? String ?? ""
    var wSzRef: CFTypeRef?
    AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &wSzRef)
    var wSz = CGSize.zero
    if let sv = wSzRef { AXValueGetValue(sv as! AXValue, .cgSize, &wSz) }
    info["windowSize"] = "\(Int(wSz.width))x\(Int(wSz.height))"
    // Mixer height
    func stFindMixer(_ el: AXUIElement, _ d: Int) -> AXUIElement? {
        if d > 3 { return nil }
        if axRole(el) == "AXGroup" && (axVal(el, kAXDescriptionAttribute) as? String) == "Mixer" {
            var szR: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &szR)
            var s = CGSize.zero; if let sv = szR { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
            if s.height > 100 { return el }
        }
        for kid in axKids(el) { if let f = stFindMixer(kid, d+1) { return f } }
        return nil
    }
    if let mg = stFindMixer(win, 0) {
        var szR: CFTypeRef?; AXUIElementCopyAttributeValue(mg, kAXSizeAttribute as CFString, &szR)
        var s = CGSize.zero; if let sv = szR { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        info["mixerHeight"] = Int(s.height)
        info["mixerOpen"] = true
    } else {
        info["mixerOpen"] = false
        info["mixerHeight"] = 0
    }
    // Inspector width
    for kid in axKids(win) {
        if (axVal(kid, kAXDescriptionAttribute) as? String) == "Inspector" {
            var szR: CFTypeRef?; AXUIElementCopyAttributeValue(kid, kAXSizeAttribute as CFString, &szR)
            var s = CGSize.zero; if let sv = szR { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
            info["inspectorWidth"] = Int(s.width)
            break
        }
    }
    // Fullscreen?
    var fsRef: CFTypeRef?
    AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsRef)
    info["fullscreen"] = (fsRef as? Bool) == true
    jsonOut(info)

case "scan":
    let channels = scanChannels(logic)
    var scanResult: [String: Any] = ["channels": channels.map { ["name": $0.name, "index": $0.index, "isBus": $0.isBus, "hasMonitoring": $0.hasMonitoring, "hasRecord": $0.hasRecord, "isMuted": axIntValue($0.muteBtn) == 1, "hasBnc": $0.hasBnc] }]
    if channels.isEmpty {
        // Debug info: why scan found 0 channels
        var dbg: [String: Any] = [:]
        if let ws = axVal(logic, kAXWindowsAttribute) as? [AXUIElement] {
            dbg["windows"] = ws.count
            var layoutsInfo: [[String: Any]] = []
            for (wi, w) in ws.enumerated() {
                let layouts = findAll(w, role: "AXLayoutArea", title: "Mixer")
                for la in layouts {
                    let kids = axKids(la)
                    let items = kids.filter { axRole($0) == "AXLayoutItem" }
                    layoutsInfo.append(["win": wi, "kids": kids.count, "items": items.count])
                }
            }
            dbg["mixerLayouts"] = layoutsInfo
            if layoutsInfo.isEmpty { dbg["note"] = "no AXLayoutArea with title/desc Mixer found" }
            // Dump first 2 items' children for diagnosis
            if let firstLayout = layoutsInfo.first, let la = {
                () -> AXUIElement? in
                for w in ws {
                    let lays = findAll(w, role: "AXLayoutArea", title: "Mixer")
                    if let best = lays.max(by: { axKids($0).count < axKids($1).count }) { return best }
                }; return nil
            }() {
                let allItems = axKids(la).filter { axRole($0) == "AXLayoutItem" }
                var itemDumps: [[String: Any]] = []
                for (ii, item) in allItems.prefix(2).enumerated() {
                    let ik = axKids(item)
                    var kidInfo: [[String: String]] = []
                    for k in ik {
                        var entry: [String: String] = ["role": axRole(k)]
                        let t = axTitle(k); if !t.isEmpty { entry["title"] = t }
                        let d = (axVal(k, kAXDescriptionAttribute) as? String) ?? ""; if !d.isEmpty { entry["desc"] = d }
                        kidInfo.append(entry)
                    }
                    itemDumps.append(["item": ii, "kidCount": ik.count, "kids": kidInfo])
                }
                dbg["sampleItems"] = itemDumps
            }
        } else { dbg["windows"] = 0 }
        scanResult["debugInfo"] = (try? String(data: JSONSerialization.data(withJSONObject: dbg), encoding: .utf8)) ?? "{}"
    }
    jsonOut(scanResult)

case "soloIndex":
    guard args.count >= 3, let idx = Int(args[2]) else { jsonOut(["error": "index required"]); exit(1) }
    let ch = scanChannels(logic)
    guard idx < ch.count else { jsonOut(["error": "index out of range, total: \(ch.count)"]); exit(1) }
    axPress(ch[idx].soloBtn)
    jsonOut(["ok": true, "action": "solo", "channel": ch[idx].name])

case "unsoloIndex":
    guard args.count >= 3, let idx = Int(args[2]) else { jsonOut(["error": "index required"]); exit(1) }
    let ch = scanChannels(logic)
    guard idx < ch.count else { jsonOut(["error": "index out of range, total: \(ch.count)"]); exit(1) }
    axPress(ch[idx].soloBtn)
    jsonOut(["ok": true, "action": "unsolo", "channel": ch[idx].name])

case "muteIndex":
    guard args.count >= 3, let idx = Int(args[2]) else { jsonOut(["error": "index required"]); exit(1) }
    let ch = scanChannels(logic)
    guard idx < ch.count else { jsonOut(["error": "index out of range, total: \(ch.count)"]); exit(1) }
    axPress(ch[idx].muteBtn)
    jsonOut(["ok": true, "action": "mute", "channel": ch[idx].name])

case "unmuteIndex":
    guard args.count >= 3, let idx = Int(args[2]) else { jsonOut(["error": "index required"]); exit(1) }
    let ch = scanChannels(logic)
    guard idx < ch.count else { jsonOut(["error": "index out of range, total: \(ch.count)"]); exit(1) }
    axPress(ch[idx].muteBtn)
    jsonOut(["ok": true, "action": "unmute", "channel": ch[idx].name])

case "readStates":
    // Read solo/mute state via Tracks header AXDescription — reliable for all channel types
    var rsSoloed: [String] = []
    var rsMuted: [String] = []
    if let header = findTracksHeader(logic) {
        for item in axKids(header) {
            let desc = (axVal(item, kAXDescriptionAttribute) as? String) ?? ""
            guard let t = parseTrackDesc(desc) else { continue }
            if desc.contains(", solo") { rsSoloed.append(t.name) }
            if desc.contains(", mute") { rsMuted.append(t.name) }
        }
    }
    jsonOut(["ok": true, "soloed": rsSoloed, "muted": rsMuted])

case "resetMutes":
    // Option+click on first mute button = unmute ALL channels in Logic
    // This resets mixer to a known state before mix bouncing
    let rmCh = scanChannels(logic)
    guard let firstMute = rmCh.first?.muteBtn else {
        jsonOut(["error": "no channels found"])
        exit(1)
    }
    // Get position of the mute button
    var rmPos = CGPoint.zero
    var rmSz = CGSize.zero
    if let pRef = axVal(firstMute, kAXPositionAttribute) {
        AXValueGetValue(pRef as! AXValue, .cgPoint, &rmPos)
    }
    if let sRef = axVal(firstMute, kAXSizeAttribute) {
        AXValueGetValue(sRef as! AXValue, .cgSize, &rmSz)
    }
    let clickPt = clampToScreen(CGPoint(x: rmPos.x + rmSz.width/2, y: rmPos.y + rmSz.height/2))
    // Option+click = unmute all
    let flagsDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
    flagsDown?.flags = .maskAlternate
    flagsDown?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    let mDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clickPt, mouseButton: .left)
    mDown?.flags = .maskAlternate
    mDown?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    let mUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clickPt, mouseButton: .left)
    mUp?.flags = .maskAlternate
    mUp?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    let flagsUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
    flagsUp?.flags = []
    flagsUp?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.3)
    jsonOut(["ok": true, "action": "resetMutes"])

case "unsoloAll":
    // AXValue unreliable — JS must track and call unsoloByName for each soloed channel
    // This is kept as a no-op for compatibility
    jsonOut(["ok": true, "action": "unsoloAll", "cleared": 0, "note": "use unsoloByName instead"])

case "unmuteAll":
    // AXValue unreliable — JS must track and call unmuteMany for each muted channel
    jsonOut(["ok": true, "action": "unmuteAll", "cleared": 0, "note": "use unmuteMany instead"])

case "bounce":
    let bounceScript = """
tell application id "com.apple.logic10" to activate
delay 0.8
tell application "System Events"
  tell process "\(logicAppName)"
    keystroke "b" using command down
  end tell
end tell
"""
    let btask = Process()
    btask.launchPath = "/usr/bin/osascript"
    btask.arguments = ["-e", bounceScript]
    btask.launch()
    btask.waitUntilExit()
    jsonOut(["ok": true, "action": "bounce"])

case "muteByName":
    guard args.count >= 3 else { jsonOut(["error": "name required"]); exit(1) }
    let targetName = args[2...].joined(separator: " ")
    let ch = scanChannels(logic)
    guard let found = ch.first(where: { $0.name == targetName }) else {
        jsonOut(["error": "channel not found: \(targetName)"]); exit(1)
    }
    axPress(found.muteBtn)
    jsonOut(["ok": true, "action": "mute", "channel": found.name])

case "unmuteByName":
    guard args.count >= 3 else { jsonOut(["error": "name required"]); exit(1) }
    let targetName = args[2...].joined(separator: " ")
    let ch = scanChannels(logic)
    guard let found = ch.first(where: { $0.name == targetName }) else {
        jsonOut(["error": "channel not found: \(targetName)"]); exit(1)
    }
    axPress(found.muteBtn)
    jsonOut(["ok": true, "action": "unmute", "channel": found.name])

case "soloByName":
    guard args.count >= 3 else { jsonOut(["error": "name required"]); exit(1) }
    let targetName = args[2...].joined(separator: " ")
    var chSolo = scanChannels(logic)
    if chSolo.first(where: { $0.name == targetName }) == nil {
        activateLogic()
        Thread.sleep(forTimeInterval: 0.35)
        chSolo = scanChannels(logic)
    }
    guard let foundSolo = chSolo.first(where: { $0.name == targetName }) else {
        jsonOut(["error": "channel not found: \(targetName)"]); exit(1)
    }
    // AXValue is unreliable for Logic's solo buttons — always press
    axPress(foundSolo.soloBtn)
    jsonOut(["ok": true, "action": "solo", "channel": foundSolo.name])

case "unsoloByName":
    guard args.count >= 3 else { jsonOut(["error": "name required"]); exit(1) }
    let targetName = args[2...].joined(separator: " ")
    var chUnsolo = scanChannels(logic)
    if chUnsolo.first(where: { $0.name == targetName }) == nil {
        activateLogic()
        Thread.sleep(forTimeInterval: 0.35)
        chUnsolo = scanChannels(logic)
    }
    if let foundUnsolo = chUnsolo.first(where: { $0.name == targetName }) {
        // AXValue is unreliable — always press to toggle off
        axPress(foundUnsolo.soloBtn)
        jsonOut(["ok": true, "action": "unsolo", "channel": foundUnsolo.name])
    } else {
        jsonOut(["ok": true, "action": "unsolo-skip-not-found", "channel": targetName])
    }

case "muteMany":
    // Scan ONCE, try to detect already-muted state (best effort — AXValue may be unreliable)
    guard args.count >= 3 else { jsonOut(["error": "names required"]); exit(1) }
    let names = args[2].split(separator: "|").map(String.init)
    let ch = scanChannels(logic)
    var muted: [String] = []
    var alreadyMuted: [String] = []
    var notFound: [String] = []
    for name in names {
        if let found = ch.first(where: { $0.name == name }) {
            let currentVal = axIntValue(found.muteBtn)
            if currentVal == 1 {
                // AX says already muted — don't toggle (would unmute!)
                alreadyMuted.append(name)
            } else {
                axPress(found.muteBtn)
                muted.append(name)
            }
        } else {
            notFound.append(name)
        }
    }
    jsonOut(["ok": true, "action": "muteMany", "muted": muted, "alreadyMuted": alreadyMuted, "notFound": notFound])

case "unmuteMany":
    // Scan ONCE, press mute on all specified channels to toggle off
    // AXValue is unreliable — JS tracks which channels need unmuting
    guard args.count >= 3 else { jsonOut(["error": "names required"]); exit(1) }
    let names = args[2].split(separator: "|").map(String.init)
    let ch = scanChannels(logic)
    var unmuted: [String] = []
    for name in names {
        if let found = ch.first(where: { $0.name == name }) {
            axPress(found.muteBtn)
            unmuted.append(name)
        }
    }
    jsonOut(["ok": true, "action": "unmuteMany", "unmuted": unmuted])

case "muteManyByIndex":
    guard args.count >= 3 else { jsonOut(["error": "indices required"]); exit(1) }
    let miIndices = args[2].split(separator: "|").compactMap { Int($0) }
    let miCh = scanChannels(logic)
    var miMuted: [Int] = []; var miNotFound: [Int] = []
    for idx in miIndices {
        if idx < miCh.count { axPress(miCh[idx].muteBtn); miMuted.append(idx) }
        else { miNotFound.append(idx) }
    }
    jsonOut(["ok": true, "action": "muteManyByIndex", "muted": miMuted, "notFound": miNotFound])

case "unmuteManyByIndex":
    guard args.count >= 3 else { jsonOut(["error": "indices required"]); exit(1) }
    let umiIndices = args[2].split(separator: "|").compactMap { Int($0) }
    let umiCh = scanChannels(logic)
    var umiUnmuted: [Int] = []
    for idx in umiIndices {
        if idx < umiCh.count { axPress(umiCh[idx].muteBtn); umiUnmuted.append(idx) }
    }
    jsonOut(["ok": true, "action": "unmuteManyByIndex", "unmuted": umiUnmuted])

case "close-marker-list":
    func findMLClose(_ app: AXUIElement) -> AXUIElement? {
        guard let wins = axVal(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return wins.first { (axVal($0, kAXTitleAttribute) as? String ?? "").contains("Marker List") }
    }
    if let mlWinC = findMLClose(logic) {
        var cBtnRef: CFTypeRef?
        AXUIElementCopyAttributeValue(mlWinC, kAXCloseButtonAttribute as CFString, &cBtnRef)
        if let ref = cBtnRef { axPress(ref as! AXUIElement) }
        Thread.sleep(forTimeInterval: 0.1)
        jsonOut(["ok": true, "closed": true])
    } else {
        jsonOut(["ok": true, "closed": false, "note": "not open"])
    }

case "metronome":
    var wins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &wins)
    guard let windows = wins as? [AXUIElement], let win = windows.first else {
        jsonOut(["on": false, "error": "no window"]); break
    }
    // Search all elements for AXCheckBox with title "Metronome Click" or description containing "metronome"/"click"
    func findMetronome(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 30 { return nil }
        if axRole(el) == "AXCheckBox" {
            var titleVal: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleVal)
            let t = (titleVal as? String) ?? ""
            if t == "Metronome Click" || t == "Click" || t == "Metronome" { return el }
            var descVal: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descVal)
            let d = (descVal as? String) ?? ""
            if d.lowercased().contains("metronome") || d.lowercased().contains("click") { return el }
        }
        // Also check AXButton with AXSwitch subrole (Intel Logic 10.7 uses AXButton/AXSwitch for toggles)
        if axRole(el) == "AXButton" {
            var subRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subRef)
            if (subRef as? String) == "AXSwitch" {
                var descVal: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descVal)
                let d = (descVal as? String) ?? ""
                if d.lowercased().contains("metronome") || d.lowercased() == "click" { return el }
            }
        }
        for child in axKids(el) {
            if let found = findMetronome(child, depth: depth + 1) { return found }
        }
        return nil
    }
    if let metro = findMetronome(win) {
        let val = axIntValue(metro)
        jsonOut(["on": val == 1, "found": true])
    } else {
        jsonOut(["on": false, "found": false])
    }

case "check-cycle":
    var cycleWins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &cycleWins)
    guard let cycleWindows = cycleWins as? [AXUIElement], let cycleWin = cycleWindows.first else {
        jsonOut(["on": false, "found": false, "error": "no window"]); break
    }
    func findCycleBtn(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 30 { return nil }
        let role = axRole(el)
        if role == "AXCheckBox" || role == "AXButton" {
            let d = (axVal(el, kAXDescriptionAttribute) as? String ?? "").lowercased()
            let t = (axVal(el, kAXTitleAttribute) as? String ?? "").lowercased()
            if d == "cycle" || t == "cycle" || d.hasPrefix("cycle ") || t.hasPrefix("cycle ") { return el }
            if role == "AXButton" {
                var subRef: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subRef)
                if (subRef as? String) == "AXSwitch" && (d.contains("cycle") || t.contains("cycle")) { return el }
            }
        }
        for child in axKids(el) {
            if let found = findCycleBtn(child, depth: depth + 1) { return found }
        }
        return nil
    }
    if let cycleBtn = findCycleBtn(cycleWin) {
        let val = axIntValue(cycleBtn)
        jsonOut(["on": val == 1, "found": true])
    } else {
        jsonOut(["on": false, "found": false])
    }

case "metronomeToggle":
    var wins2: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &wins2)
    guard let windows2 = wins2 as? [AXUIElement], let win2 = windows2.first else {
        jsonOut(["ok": false, "error": "no window"]); break
    }
    func findMetronome2(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 30 { return nil }
        if axRole(el) == "AXCheckBox" {
            var titleVal: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleVal)
            let t = (titleVal as? String) ?? ""
            if t == "Metronome Click" || t == "Click" || t == "Metronome" { return el }
            var descVal: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descVal)
            let d = (descVal as? String) ?? ""
            if d.lowercased().contains("metronome") || d.lowercased().contains("click") { return el }
        }
        if axRole(el) == "AXButton" {
            var subRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subRef)
            if (subRef as? String) == "AXSwitch" {
                var descVal: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descVal)
                let d = (descVal as? String) ?? ""
                if d.lowercased().contains("metronome") || d.lowercased() == "click" { return el }
            }
        }
        for child in axKids(el) {
            if let found = findMetronome2(child, depth: depth + 1) { return found }
        }
        return nil
    }
    if let metro = findMetronome2(win2) {
        axPress(metro)
        Thread.sleep(forTimeInterval: 0.1)
        let newVal = axIntValue(metro)
        jsonOut(["ok": true, "on": newVal == 1])
    } else {
        jsonOut(["ok": false, "error": "not found"])
    }

case "switchToEnglish":
    // Switch keyboard input to English (ABC or US) layout
    let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!] as CFDictionary
    let allSources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
    var switched = false
    for src in allSources {
        let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
        guard let idPtr = idPtr else { continue }
        let srcId = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        if srcId.contains("ABC") || srcId.contains(".US") || srcId.contains("USInternational") {
            TISSelectInputSource(src)
            switched = true
            break
        }
    }
    jsonOut(["ok": switched])

case "maximizeLogic":
    // Exit fullscreen (if active), then resize to fill visible screen
    guard let screen = NSScreen.main else { jsonOut(["ok": false, "error": "no screen"]); break }
    let visFrame  = screen.visibleFrame
    let mlScreenH = screen.frame.height
    let axY       = mlScreenH - visFrame.origin.y - visFrame.height
    let targetOrigin = CGPoint(x: visFrame.origin.x, y: axY)
    let targetSize   = CGSize(width: visFrame.width, height: visFrame.height)

    // Helper: get Logic's main window via AX windows list (nil = fullscreen or no window)
    func getLogicWindowList() -> AXUIElement? {
        guard let wins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement], !wins.isEmpty else { return nil }
        return wins.first(where: { (axVal($0, kAXTitleAttribute) as? String ?? "").contains("Tracks") }) ?? wins.first
    }

    // Debug: count windows AX sees
    let mlWinCount = (axVal(logic, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0

    // 1. kAXWindowsAttribute empty → could be fullscreen OR brief Space-transition gap
    var exitedFs = false
    if getLogicWindowList() == nil {
        // Activate first and wait 0.8s — if still no window then it's truly fullscreen
        runScript("tell application id \"com.apple.logic10\" to activate")
        tsleep(0.8)
        if getLogicWindowList() == nil {
        exitedFs = true
        let fsScript = """
        tell application id "com.apple.logic10" to activate
        delay 0.2
        tell application "System Events"
            keystroke "f" using {control down, command down}
        end tell
        delay 0.6
        tell application id "com.apple.logic10" to activate
        """
        runScript(fsScript)
        // Wait for window to appear after fullscreen exit (up to 3s)
        var fsWaited = 0
        while getLogicWindowList() == nil && fsWaited < 8 {
            Thread.sleep(forTimeInterval: 0.3)
            fsWaited += 1
        }
        // Resize to fill screen via AX (targets Tracks window, not front)
        if let fsWin = getLogicWindowList() {
            var fsNewPos = targetOrigin; var fsNewSz = targetSize
            if let p = AXValueCreate(.cgPoint, &fsNewPos) { AXUIElementSetAttributeValue(fsWin, kAXPositionAttribute as CFString, p) }
            if let s = AXValueCreate(.cgSize, &fsNewSz) { AXUIElementSetAttributeValue(fsWin, kAXSizeAttribute as CFString, s) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 0.3)
        if getLogicWindowList() == nil {
            jsonOut(["ok": true, "exitedFullscreen": true, "resized": true,
                     "width": Int(targetSize.width), "height": Int(targetSize.height),
                     "axWindowCount": mlWinCount]); break
        }
        } // end inner if getLogicWindowList() == nil (truly fullscreen)
    }

    // 2. Get window via AX
    guard let mlW = getLogicWindowList() else {
        jsonOut(["ok": false, "error": "no window"]); break
    }

    // 2b. Check if window is in native fullscreen even though AX can see it (we're on its Space)
    var mlFsRef: CFTypeRef?
    AXUIElementCopyAttributeValue(mlW, "AXFullScreen" as CFString, &mlFsRef)
    if (mlFsRef as? Bool) == true {
        // Fullscreen detected on current Space — exit it
        exitedFs = true
        let fsScript2 = """
        tell application id "com.apple.logic10" to activate
        delay 0.3
        tell application "System Events"
            keystroke "f" using {control down, command down}
        end tell
        """
        runScript(fsScript2)
        tsleep(2.5)
        // Resize via AX — target Tracks window specifically
        if let fs2Win = getLogicWindowList() {
            var fs2Pos = targetOrigin; var fs2Sz = targetSize
            if let p = AXValueCreate(.cgPoint, &fs2Pos) { AXUIElementSetAttributeValue(fs2Win, kAXPositionAttribute as CFString, p) }
            if let s = AXValueCreate(.cgSize, &fs2Sz) { AXUIElementSetAttributeValue(fs2Win, kAXSizeAttribute as CFString, s) }
        }
        Thread.sleep(forTimeInterval: 0.3)
        jsonOut(["ok": true, "exitedFullscreen": true, "resized": true,
                 "width": Int(targetSize.width), "height": Int(targetSize.height), "axWindowCount": mlWinCount]); break
    }

    // 3. Un-minimize if needed
    var mlMinRef: CFTypeRef?
    AXUIElementCopyAttributeValue(mlW, kAXMinimizedAttribute as CFString, &mlMinRef)
    if let isMin = mlMinRef as? Bool, isMin {
        AXUIElementSetAttributeValue(mlW, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        Thread.sleep(forTimeInterval: 0.4)
    }

    // 4. Read current position/size
    var mlPosRef: CFTypeRef?; var mlSzRef: CFTypeRef?
    AXUIElementCopyAttributeValue(mlW, kAXPositionAttribute as CFString, &mlPosRef)
    AXUIElementCopyAttributeValue(mlW, kAXSizeAttribute as CFString, &mlSzRef)
    var currentPos = CGPoint.zero; var currentSz = CGSize.zero
    if let pv = mlPosRef { AXValueGetValue(pv as! AXValue, .cgPoint, &currentPos) }
    if let sv = mlSzRef  { AXValueGetValue(sv as! AXValue, .cgSize,  &currentSz) }

    // 5. Resize Logic Tracks window to full screen via AX (targets correct window, not front)
    var axNewPos = targetOrigin
    var axNewSz  = targetSize
    if let posVal = AXValueCreate(.cgPoint, &axNewPos) {
        AXUIElementSetAttributeValue(mlW, kAXPositionAttribute as CFString, posVal)
    }
    if let szVal = AXValueCreate(.cgSize, &axNewSz) {
        AXUIElementSetAttributeValue(mlW, kAXSizeAttribute as CFString, szVal)
    }
    Thread.sleep(forTimeInterval: 0.2)
    jsonOut(["ok": true,
             "width": Int(targetSize.width), "height": Int(targetSize.height),
             "resized": true,
             "axWindowCount": mlWinCount,
             "exitedFullscreen": exitedFs])

// ── closePanels: close Inspector, Library, Browsers etc. + check/resize mixer if already open ──
case "closePanels":
    var cpWins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement]
    if cpWins == nil || cpWins!.isEmpty {
        runScript("tell application id \"com.apple.logic10\" to activate")
        Thread.sleep(forTimeInterval: 0.4)
        cpWins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement]
    }
    let cpWin = cpWins?.first(where: { (axVal($0, kAXTitleAttribute) as? String ?? "").contains("Tracks") })
             ?? cpWins?.first
    guard let cpWin = cpWin else { jsonOut(["ok": false, "error": "no window"]); break }

    func cpFindCheckbox(_ el: AXUIElement, titleVal: String, depth: Int = 0) -> AXUIElement? {
        if depth > 5 { return nil }
        if axRole(el) == "AXCheckBox" {
            let t = axVal(el, kAXTitleAttribute) as? String ?? ""
            let d = axVal(el, kAXDescriptionAttribute) as? String ?? ""
            if t == titleVal || d == titleVal { return el }
        }
        for child in axKids(el) {
            if let found = cpFindCheckbox(child, titleVal: titleVal, depth: depth + 1) { return found }
        }
        return nil
    }

    // Close panels that take horizontal space
    for panelName in ["Inspector", "Library", "Quick Help", "Browsers", "List Editors", "Note Pads", "Loop Browser"] {
        if let panel = cpFindCheckbox(cpWin, titleVal: panelName) {
            if axIntValue(panel) == 1 {
                axPress(panel)
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
    }

    // Check if mixer is already open — openMixer will handle positioning
    var cpMixerWasOpen = false
    if let mixerCb = cpFindCheckbox(cpWin, titleVal: "Mixer") {
        cpMixerWasOpen = axIntValue(mixerCb) == 1
    }

    jsonOut(["ok": true, "mixerWasOpen": cpMixerWasOpen])


case "openMixer":
    // Activate Logic first if its window isn't accessible (different Space)
    var omWins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement]
    if omWins == nil || omWins!.isEmpty {
        runScript("tell application id \"com.apple.logic10\" to activate")
        Thread.sleep(forTimeInterval: 0.4)
        omWins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement]
    }
    let omWin = omWins?.first(where: { (axVal($0, kAXTitleAttribute) as? String ?? "").contains("Tracks") })
             ?? omWins?.first
    guard let omWin = omWin else {
        jsonOut(["ok": false, "error": "no window"]); break
    }

    // Helper: find checkbox by title or description
    func omFindCheckbox(_ el: AXUIElement, titleVal: String, depth: Int = 0) -> AXUIElement? {
        if depth > 5 { return nil }
        if axRole(el) == "AXCheckBox" {
            let t = axVal(el, kAXTitleAttribute) as? String ?? ""
            let d = axVal(el, kAXDescriptionAttribute) as? String ?? ""
            if t == titleVal || d == titleVal { return el }
        }
        for child in axKids(el) {
            if let found = omFindCheckbox(child, titleVal: titleVal, depth: depth + 1) { return found }
        }
        return nil
    }

    // Close Library, Inspector, Browsers, Loop Browser, etc. — free up horizontal space
    for panelName in ["Library", "Inspector", "Quick Help", "Browsers", "List Editors", "Note Pads", "Loop Browser"] {
        if let panel = omFindCheckbox(omWin, titleVal: panelName) {
            if axIntValue(panel) == 1 {
                axPress(panel)
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
    }

    // Enable Mixer if not already open
    var omWasOpen = true
    if let mixerCb = omFindCheckbox(omWin, titleVal: "Mixer") {
        let val = axIntValue(mixerCb)
        if val == 0 {
            axPress(mixerCb)
            Thread.sleep(forTimeInterval: 0.45)
            omWasOpen = false
        }
    } else {
        jsonOut(["ok": false, "error": "Mixer button not found"]); break
    }

    // Click "All" radio button to show all channel types
    func omFindAllRadioBtn(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 8 { return nil }
        if axRole(el) == "AXRadioButton" {
            let desc = (axVal(el, kAXDescriptionAttribute) as? String) ?? ""
            let title = (axVal(el, kAXTitleAttribute) as? String) ?? ""
            if desc == "All" || title == "All" { return el }
        }
        for child in axKids(el) {
            if let found = omFindAllRadioBtn(child, depth: depth + 1) { return found }
        }
        return nil
    }
    if let allBtn = omFindAllRadioBtn(omWin) {
        axPress(allBtn)
        Thread.sleep(forTimeInterval: 0.2)
    }

    // === NEW: Position mixer at 60% of window height ===
    let OM_MIXER_RATIO: Double = 0.60
    let omWinPos = axPos(omWin)
    let omWinSize = axSize(omWin)
    let omSplitterX = omWinPos.x + omWinSize.width / 2

    // Find Mixer group and drag splitter to target height
    func omFindMixerGroup(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 6 { return nil }
        if axRole(el) == "AXGroup" && (axVal(el, kAXDescriptionAttribute) as? String) == "Mixer" { return el }
        for kid in axKids(el) { if let f = omFindMixerGroup(kid, depth: depth + 1) { return f } }
        return nil
    }

    if let omMg = omFindMixerGroup(omWin) {
        let omMgY = axPos(omMg).y
        let omTargetY = omWinPos.y + omWinSize.height * (1.0 - OM_MIXER_RATIO)
        let omDiff = abs(omMgY - omTargetY)
        if omDiff > 20 {
            // Drag splitter to target position
            let omDragFrom = CGPoint(x: omSplitterX, y: omMgY + 2)
            let omDragTo = CGPoint(x: omSplitterX, y: omTargetY)
            CGWarpMouseCursorPosition(omDragFrom); usleep(200_000)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                    mouseCursorPosition: omDragFrom, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(150_000)
            for i in 0...50 {
                let t = Double(i) / 50.0
                let p = CGPoint(x: omDragFrom.x + (omDragTo.x - omDragFrom.x) * t,
                                y: omDragFrom.y + (omDragTo.y - omDragFrom.y) * t)
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                        mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(14_000)
            }
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                    mouseCursorPosition: omDragTo, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(400_000)
        }
    }

    jsonOut(["ok": true, "wasOpen": omWasOpen])


// ── scrollToBnc: scroll mixer to find the channel with Bounce button ──────
case "scrollToBnc":
    guard let stbWins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement],
          let stbWin = stbWins.first(where: { (axVal($0, kAXTitleAttribute) as? String ?? "").contains("Tracks") })
                    ?? stbWins.first else {
        jsonOut(["ok": false, "error": "no window"]); break
    }

    func stbFindAllMixerLayouts(_ el: AXUIElement, depth: Int = 0, results: inout [AXUIElement]) {
        if depth > 6 { return }
        if axRole(el) == "AXLayoutArea" && (axVal(el, kAXDescriptionAttribute) as? String) == "Mixer" { results.append(el) }
        for kid in axKids(el) { stbFindAllMixerLayouts(kid, depth: depth + 1, results: &results) }
    }
    func stbFindBounceStrip(_ mixer: AXUIElement) -> AXUIElement? {
        for item in axKids(mixer) {
            for kid in axKids(item) {
                if axRole(kid) == "AXButton" {
                    let desc = (axVal(kid, kAXDescriptionAttribute) as? String ?? "").lowercased()
                    let title = (axVal(kid, kAXTitleAttribute) as? String ?? "").lowercased()
                    if desc == "bounce" || title == "bnc" || title == "bounce" { return item }
                }
            }
        }
        return nil
    }
    func stbPostScroll(at pt: CGPoint, w1: Int32, w2: Int32) {
        if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                            wheelCount: 2, wheel1: w1, wheel2: w2, wheel3: 0) {
            ev.location = pt; ev.post(tap: .cghidEventTap)
        }
    }

    var stbAllMixers: [AXUIElement] = []
    stbFindAllMixerLayouts(stbWin, results: &stbAllMixers)
    guard let stbMixer = stbAllMixers.max(by: { axSize($0).width < axSize($1).width }) else {
        jsonOut(["ok": false, "error": "Mixer layout not found"]); break
    }
    let stbMixerPos = axPos(stbMixer)
    let stbMixerSize = axSize(stbMixer)
    let stbMixerRight = stbMixerPos.x + stbMixerSize.width
    let stbPt = CGPoint(x: stbMixerPos.x + stbMixerSize.width / 2,
                        y: stbMixerPos.y + stbMixerSize.height / 2)

    // Reset — scroll all the way LEFT
    CGWarpMouseCursorPosition(stbPt)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: stbPt, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(80_000)
    for _ in 0..<15 { stbPostScroll(at: stbPt, w1: 0, w2: 5000); usleep(6_000) }
    usleep(300_000)

    // Find bounce strip (scroll right if needed)
    var stbBounceStrip: AXUIElement? = stbFindBounceStrip(stbMixer)
    if stbBounceStrip == nil {
        for _ in 0..<100 {
            for _ in 0..<3 { stbPostScroll(at: stbPt, w1: 0, w2: -5000); usleep(5_000) }
            usleep(50_000)
            stbBounceStrip = stbFindBounceStrip(stbMixer)
            if stbBounceStrip != nil { break }
        }
    }

    if let stbStrip = stbBounceStrip {
        CGWarpMouseCursorPosition(stbPt)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: stbPt, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(80_000)
        for _ in 0..<8 {
            let stbGap = (axPos(stbStrip).x + axSize(stbStrip).width) - stbMixerRight + 40
            if abs(stbGap) <= 20 { break }
            let stbPulse = Int32(max(-5000, min(5000, stbGap)))
            stbPostScroll(at: stbPt, w1: 0, w2: -stbPulse)
            usleep(150_000)
        }
        for _ in 0..<10 { stbPostScroll(at: stbPt, w1: 5000, w2: 0); usleep(6_000) }
    }

    jsonOut(["ok": true, "hasBnc": stbBounceStrip != nil])


// ── ensureMixer: open mixer if closed, close Library/Inspector for space ──────
// Used before bounce — does NOT change filter states or click All
case "ensureMixer":
    var emWins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &emWins)
    guard let emWindows = emWins as? [AXUIElement], let emWin = emWindows.first else {
        jsonOut(["ok": false, "error": "no window"]); break
    }
    func emFindCheckbox(_ el: AXUIElement, titleVal: String, depth: Int = 0) -> AXUIElement? {
        if depth > 5 { return nil }
        if axRole(el) == "AXCheckBox" {
            var t: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t)
            if let s = t as? String, s == titleVal { return el }
            var d: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &d)
            if let s = d as? String, s == titleVal { return el }
        }
        for child in axKids(el) {
            if let found = emFindCheckbox(child, titleVal: titleVal, depth: depth + 1) { return found }
        }
        return nil
    }
    guard let emMixer = emFindCheckbox(emWin, titleVal: "Mixer") else {
        jsonOut(["ok": false, "error": "Mixer button not found"]); break
    }
    if axIntValue(emMixer) == 1 {
        // Mixer already open — instant return, no side effects on Library/Inspector
        jsonOut(["ok": true, "opened": false]); break
    }
    // Mixer is closed — close Library/Inspector to give it full width, then open
    if let library = emFindCheckbox(emWin, titleVal: "Library"), axIntValue(library) == 1 {
        axPress(library); Thread.sleep(forTimeInterval: 0.25)
    }
    axPress(emMixer); tsleep(0.6)
    if let inspector = emFindCheckbox(emWin, titleVal: "Inspector"), axIntValue(inspector) == 1 {
        axPress(inspector); Thread.sleep(forTimeInterval: 0.25)
    }
    jsonOut(["ok": true, "opened": true])

case "setFormat":
    guard args.count >= 4 else { jsonOut(["error": "need fileFormat bitDepth sampleRate"]); exit(1) }
    let fileFormat = args[2]  // e.g. "WAVE"
    let bitDepth   = args[3]  // e.g. "24 Bit"
    let sampleRate = args.count >= 5 ? args[4] : "48000"
    let enableMp3  = args.count >= 6 ? args[5] == "1" : false
    
    // Map sample rate number to display value
    // Intel Logic 10.7 shows raw numbers like "44100", newer Logic shows "44.1 kHz"
    let srDisplayMap = ["44100": "44.1 kHz", "48000": "48 kHz", "96000": "96 kHz",
                        "44.1 kHz": "44.1 kHz", "48 kHz": "48 kHz", "96 kHz": "96 kHz"]
    let srDisplay = srDisplayMap[sampleRate] ?? sampleRate
    // Also prepare raw number for Intel matching
    let srRawMap = ["44100": "44100", "48000": "48000", "96000": "96000",
                    "44.1 kHz": "44100", "48 kHz": "48000", "96 kHz": "96000"]
    let srRaw = srRawMap[sampleRate] ?? sampleRate
    
    var wins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &wins)
    guard let windows = wins as? [AXUIElement] else { jsonOut(["error": "no windows"]); exit(1) }
    guard let bounceWin = windows.first(where: {
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &t)
        return (t as? String ?? "").contains("Bounce")
    }) else { jsonOut(["error": "Bounce dialog not open"]); exit(1) }
    
    var logicPid: pid_t = 0
    AXUIElementGetPid(bounceWin, &logicPid)

    func pressKey(_ keyCode: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let dn = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            dn.postToPid(logicPid)
            Thread.sleep(forTimeInterval: 0.05)
            up.postToPid(logicPid)
        }
    }

    func selectPopup(_ currentVal: String, _ newVal: String) -> Bool {
        let popups = findAll(bounceWin, role: "AXPopUpButton", depth: 10)
        for popup in popups {
            var val: CFTypeRef?
            AXUIElementCopyAttributeValue(popup, kAXValueAttribute as CFString, &val)
            guard let v = val as? String, v == currentVal else { continue }
            if v == newVal { return true }

            // Click to open popup
            axPress(popup)
            Thread.sleep(forTimeInterval: 0.5)

            // Logic popup menus appear as a separate AXApplication-level menu
            // Search ALL windows of Logic for menu items
            var allWins: CFTypeRef?
            AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &allWins)
            if let wins = allWins as? [AXUIElement] {
                for w in wins {
                    let items = findAll(w, role: "AXMenuItem", depth: 5)
                    for item in items {
                        var tv: CFTypeRef?
                        AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &tv)
                        if let t = tv as? String, t == newVal {
                            axPress(item)
                            Thread.sleep(forTimeInterval: 0.2)
                            return true
                        }
                    }
                }
            }

            // Also check popup's own subtree
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(popup, kAXChildrenAttribute as CFString, &kids)
            if let menu = (kids as? [AXUIElement])?.first {
                for item in findAll(menu, role: "AXMenuItem", depth: 5) {
                    var tv: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &tv)
                    if let t = tv as? String, t == newVal {
                        axPress(item)
                        Thread.sleep(forTimeInterval: 0.2)
                        return true
                    }
                }
            }

            pressKey(53) // Escape
            Thread.sleep(forTimeInterval: 0.2)
            return false
        }
        return false
    }
    
    var results: [String: Any] = [:]
    
    // Get all popups sorted by Y position
    let allPopupsUnsorted = findAll(bounceWin, role: "AXPopUpButton", depth: 10)
    var popupsByY: [(Int, AXUIElement)] = []
    for popup in allPopupsUnsorted {
        var pos: CFTypeRef?
        AXUIElementCopyAttributeValue(popup, kAXPositionAttribute as CFString, &pos)
        if let p = pos as! AXValue? {
            var point = CGPoint.zero
            AXValueGetValue(p, .cgPoint, &point)
            popupsByY.append((Int(point.y), popup))
        }
    }
    popupsByY.sort { $0.0 < $1.0 }
    
    // In Logic Bounce Parameters panel, popups appear in order:
    // y~187: File Format (WAVE/AIFF/CAF)
    // y~217: Resolution (8-bit/16 Bit/24 Bit/32 Bit)
    // y~247: Sample Rate (22.05 kHz/44.1 kHz/48 kHz/96 kHz)
    // y~277: File Type (Interleaved/Split)
    
    for (y, popup) in popupsByY {
        var val: CFTypeRef?
        AXUIElementCopyAttributeValue(popup, kAXValueAttribute as CFString, &val)
        let v = (val as? String) ?? ""
        
        if ["WAVE","AIFF","CAF","WAVE64","MP3"].contains(v) {
            // File Format popup
            if v != fileFormat {
                let r = selectPopup(v, fileFormat)
                results["format"] = r
            } else { results["format"] = true }
        } else if v.lowercased().contains("bit") {
            // Resolution popup - Logic shows "24 Bit" as current but menu items are "24-bit"
            if v.replacingOccurrences(of: " ", with: "-").lowercased() != bitDepth.lowercased() {
                let r = selectPopup(v, bitDepth)
                results["bitDepth"] = r
            } else { results["bitDepth"] = true }
        } else if v.contains("kHz") || v.contains("Hz") {
            // Sample Rate popup (newer Logic: "44.1 kHz")
            if v != srDisplay {
                let r = selectPopup(v, srDisplay)
                results["sampleRate"] = r
            } else { results["sampleRate"] = true }
        } else if ["22050","44100","48000","88200","96000","176400","192000"].contains(v) {
            // Sample Rate popup (Intel Logic 10.7: raw number like "44100")
            if v != srRaw {
                let r = selectPopup(v, srRaw)
                results["sampleRate"] = r
            } else { results["sampleRate"] = true }
        }
    }
    
    // Toggle MP3 checkbox
    let cbs = findAll(bounceWin, role: "AXCheckBox", depth: 10)
    var mp3Found = false
    for cb in cbs {
        var tv: CFTypeRef?
        AXUIElementCopyAttributeValue(cb, kAXTitleAttribute as CFString, &tv)
        if let t = tv as? String, t == "MP3" {
            let v = axIntValue(cb)
            if enableMp3 && v == 0 { axPress(cb) }
            else if !enableMp3 && v == 1 { axPress(cb) }
            results["mp3"] = true
            mp3Found = true
            break
        }
    }
    // Fallback for Intel Logic 10.7 where checkboxes have no title
    // MP3 is the 2nd row in the destination list (PCM=0, MP3=1, M4A=2, Burn=3)
    if !mp3Found {
        let rows = findAll(bounceWin, role: "AXRow", depth: 10)
        if rows.count >= 2 {
            // MP3 row is index 1; find the checkbox inside it
            let mp3Row = rows[1]
            let rowCbs = findAll(mp3Row, role: "AXCheckBox", depth: 5)
            if let mp3Cb = rowCbs.first {
                let v = axIntValue(mp3Cb)
                if enableMp3 && v == 0 { axPress(mp3Cb) }
                else if !enableMp3 && v == 1 { axPress(mp3Cb) }
                results["mp3"] = true
                mp3Found = true
            }
        }
    }
    
    jsonOut(["ok": true, "set": results])

case "sendKey":
    // sendKey <keyCode> [cmd] [shift] [opt] [ctrl]
    guard args.count >= 3, let keyCode = UInt16(args[2]) else {
        jsonOut(["error": "keyCode required"]); exit(1)
    }
    var pid: pid_t = 0
    AXUIElementGetPid(logic, &pid)
    var flags: CGEventFlags = []
    if args.contains("cmd") { flags.insert(.maskCommand) }
    if args.contains("shift") { flags.insert(.maskShift) }
    if args.contains("opt") { flags.insert(.maskAlternate) }
    if args.contains("ctrl") { flags.insert(.maskControl) }
    sendKeyToLogic(pid, keyCode: CGKeyCode(keyCode), flags: flags)
    jsonOut(["ok": true, "keyCode": keyCode])

case "stop-render":
    // Send Cmd+Period via CGEvent post(tap: .cghidEventTap) — works reliably
    // (unlike postToPid which doesn't reach Logic during modal bounce dialog)
    if let logicApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first {
        logicApp.activate()
        Thread.sleep(forTimeInterval: 0.15)
    }
    let stopSrc = CGEventSource(stateID: .hidSystemState)
    // Period key = 0x2F (47)
    if let dn = CGEvent(keyboardEventSource: stopSrc, virtualKey: 0x2F, keyDown: true),
       let up = CGEvent(keyboardEventSource: stopSrc, virtualKey: 0x2F, keyDown: false) {
        dn.flags = .maskCommand
        up.flags = []
        dn.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
    }
    // Send twice for reliability
    Thread.sleep(forTimeInterval: 0.2)
    if let dn2 = CGEvent(keyboardEventSource: stopSrc, virtualKey: 0x2F, keyDown: true),
       let up2 = CGEvent(keyboardEventSource: stopSrc, virtualKey: 0x2F, keyDown: false) {
        dn2.flags = .maskCommand
        up2.flags = []
        dn2.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up2.post(tap: .cghidEventTap)
    }
    jsonOut(["ok": true])

case "typeText":
    // typeText <text>
    guard args.count >= 3 else { jsonOut(["error": "text required"]); exit(1) }
    let text = args[2...].joined(separator: " ")
    var pid: pid_t = 0
    AXUIElementGetPid(logic, &pid)
    typeTextToLogic(pid, text)
    jsonOut(["ok": true, "typed": text])

case "clickWindowButton":
    // clickWindowButton <buttonName> - searches ALL Logic windows for button
    guard args.count >= 3 else { jsonOut(["error": "buttonName required"]); exit(1) }
    let btnName = args[2...].joined(separator: " ")
    var wins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &wins)
    guard let windows = wins as? [AXUIElement] else {
        jsonOut(["error": "no windows"]); exit(1)
    }
    var clicked = false
    for win in windows {
        let btns = findAll(win, role: "AXButton", title: btnName, depth: 15)
        if let btn = btns.first {
            axPress(btn)
            clicked = true
            break
        }
    }
    jsonOut(["ok": clicked, "clicked": clicked ? btnName : "not found"])

case "getWindows":
    var wins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &wins)
    let titles = (wins as? [AXUIElement])?.compactMap { win -> String? in
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t)
        return t as? String
    } ?? []
    jsonOut(["ok": true, "windows": titles])

case "setFilenameAndBounce":
    // Set Save As field and click Bounce - all via AX, no focus needed
    guard args.count >= 3 else { jsonOut(["error": "filename required"]); exit(1) }
    let filename = args[2...].joined(separator: " ")
    var wins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &wins)
    guard let windows = wins as? [AXUIElement] else {
        jsonOut(["error": "no windows"]); exit(1)
    }
    var result: [String: Any] = ["ok": false]
    for win in windows {
        // Find Save As text field
        let textFields = findAll(win, role: "AXTextField", depth: 15)
        for tf in textFields {
            var tv: CFTypeRef?
            AXUIElementCopyAttributeValue(tf, kAXTitleAttribute as CFString, &tv)
            let title = (tv as? String) ?? ""
            // "Save As:" or "name" field
            if title.contains("Save") || title.contains("name") || title.isEmpty {
                // Set value via AX
                AXUIElementSetAttributeValue(tf, kAXValueAttribute as CFString, filename as CFTypeRef)
                Thread.sleep(forTimeInterval: 0.15)
                result["filename"] = true
                break
            }
        }
        // Find and click Bounce button
        let bounceBtns = findAll(win, role: "AXButton", title: "Bounce", depth: 15)
        if let btn = bounceBtns.first {
            axPress(btn)
            result["bounceClicked"] = true
            result["ok"] = true
            break
        }
    }
    if !(result["ok"] as? Bool ?? false) {
        // Fallback: press Enter
        var pid: pid_t = 0
        AXUIElementGetPid(logic, &pid)
        sendKeyToLogic(pid, keyCode: 36) // Enter
        result["ok"] = true
        result["fallback"] = true
    }
    jsonOut(result)

case "getMixerFilters":
    // Retry once if mixer just opened
    var ctrl = findMixerFilterControl(logic)
    if ctrl == nil { Thread.sleep(forTimeInterval: 0.5); ctrl = findMixerFilterControl(logic) }
    guard let ctrl = ctrl else {
        jsonOut(["ok": false, "mixerOpen": false, "filters": [:]]); break
    }
    switch ctrl {
    case .inline_(let grp):
        // Mode 2: read checkboxes directly — no menu, no Logic activation
        var filters: [String: Bool] = [:]
        for cb in axKids(grp) where axRole(cb) == "AXCheckBox" {
            let t = (axVal(cb, kAXTitleAttribute) as? String) ?? ""
            let label = t.isEmpty ? ((axVal(cb, kAXDescriptionAttribute) as? String) ?? "") : t
            guard !label.isEmpty else { continue }
            filters[label] = axIntValue(cb) == 1
        }
        jsonOut(["ok": true, "mixerOpen": true, "mode": "inline", "filters": filters])
    case .dropdown(let mb):
        // Mode 1: open menu, read checkmarks, close
        if let filters = readMixerFilterStates(mb) {
            jsonOut(["ok": true, "mixerOpen": true, "mode": "dropdown", "filters": filters])
        } else {
            jsonOut(["ok": false, "mixerOpen": true, "filters": [:], "error": "menu did not open"])
        }
    }

case "mixerFilterToggle":
    guard args.count >= 3 else { jsonOut(["error": "filter name required"]); exit(1) }
    let filterName = args[2...].joined(separator: " ")
    var ctrl2 = findMixerFilterControl(logic)
    if ctrl2 == nil { Thread.sleep(forTimeInterval: 0.4); ctrl2 = findMixerFilterControl(logic) }
    guard let ctrl2 = ctrl2 else { jsonOut(["ok": false, "error": "Mixer not open"]); break }
    switch ctrl2 {
    case .inline_(let grp):
        // Mode 2: axPress checkbox directly
        guard let cb = axKids(grp).first(where: {
            let t = (axVal($0, kAXTitleAttribute) as? String) ?? ""
            let label = t.isEmpty ? ((axVal($0, kAXDescriptionAttribute) as? String) ?? "") : t
            return label == filterName
        }) else { jsonOut(["ok": false, "error": "checkbox '\(filterName)' not found"]); break }
        let wasOn = axIntValue(cb) == 1
        axPress(cb)
        Thread.sleep(forTimeInterval: 0.05)
        let finalVal = axIntValue(cb) == 1
        jsonOut(["ok": true, "filter": filterName, "wasOn": wasOn, "isNow": finalVal, "mode": "inline"])
    case .dropdown(let mb):
        // Mode 1: open menu, click item, menu closes automatically
        axPress(mb)
        Thread.sleep(forTimeInterval: 0.35)
        guard let m = axKids(mb).first(where: { axRole($0) == "AXMenu" }) else {
            jsonOut(["ok": false, "error": "menu did not open"]); break
        }
        guard let ti = axKids(m).first(where: { (axVal($0, kAXTitleAttribute) as? String) == filterName }) else {
            var pidX: pid_t = 0; AXUIElementGetPid(mb, &pidX)
            let srcX = CGEventSource(stateID: .hidSystemState)
            if let dn = CGEvent(keyboardEventSource: srcX, virtualKey: 53, keyDown: true),
               let up = CGEvent(keyboardEventSource: srcX, virtualKey: 53, keyDown: false) { dn.postToPid(pidX); up.postToPid(pidX) }
            jsonOut(["ok": false, "error": "item '\(filterName)' not found"]); break
        }
        let wasOn2 = (axVal(ti, "AXMenuItemMarkChar") as? String) == "✓"
        axPress(ti)
        Thread.sleep(forTimeInterval: 0.1)
        jsonOut(["ok": true, "filter": filterName, "wasOn": wasOn2, "isNow": !wasOn2, "mode": "dropdown"])
    }

case "enableAllMixerFilters":
    var ctrl3 = findMixerFilterControl(logic)
    if ctrl3 == nil { Thread.sleep(forTimeInterval: 0.6); ctrl3 = findMixerFilterControl(logic) }
    guard let ctrl3 = ctrl3 else {
        jsonOut(["ok": false, "error": "Mixer not open", "enabled": []]); break
    }
    var enabled3: [String] = []
    switch ctrl3 {
    case .inline_(let grp):
        // Mode 2: axPress each OFF checkbox
        for cb in axKids(grp) where axRole(cb) == "AXCheckBox" {
            let t = (axVal(cb, kAXTitleAttribute) as? String) ?? ""
            let label = t.isEmpty ? ((axVal(cb, kAXDescriptionAttribute) as? String) ?? "") : t
            guard !label.isEmpty else { continue }
            if axIntValue(cb) == 0 {
                axPress(cb)
                Thread.sleep(forTimeInterval: 0.08)
                enabled3.append(label)
            }
        }
        jsonOut(["ok": true, "enabled": enabled3, "mode": "inline"])
    case .dropdown(let mb):
        // Mode 1: read states then click each OFF item
        guard let states = readMixerFilterStates(mb) else {
            jsonOut(["ok": false, "error": "menu did not open", "enabled": []]); break
        }
        let offNames = states.filter { !$0.value }.map { $0.key }
        for name in offNames {
            axPress(mb); Thread.sleep(forTimeInterval: 0.3)
            if let m = axKids(mb).first(where: { axRole($0) == "AXMenu" }),
               let ti = axKids(m).first(where: { (axVal($0, kAXTitleAttribute) as? String) == name }) {
                axPress(ti); Thread.sleep(forTimeInterval: 0.25)
                enabled3.append(name)
            } else {
                var pidX: pid_t = 0; AXUIElementGetPid(mb, &pidX)
                let srcX = CGEventSource(stateID: .hidSystemState)
                if let dn = CGEvent(keyboardEventSource: srcX, virtualKey: 53, keyDown: true),
                   let up = CGEvent(keyboardEventSource: srcX, virtualKey: 53, keyDown: false) { dn.postToPid(pidX); up.postToPid(pidX) }
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        jsonOut(["ok": true, "enabled": enabled3, "mode": "dropdown"])
    }

case "applyBouncePreset":
    // Apply format settings to the open Bounce dialog
    guard args.count >= 3 else { jsonOut(["ok": false, "error": "missing args"]); break }
    let abpJsonStr = args[2]
    var abpParams: [String: String] = [:]
    if let abpData = abpJsonStr.data(using: .utf8),
       let abpObj = try? JSONSerialization.jsonObject(with: abpData) as? [String: Any] {
        for (k, v) in abpObj { if let s = v as? String { abpParams[k] = s } else if let n = v as? Int { abpParams[k] = String(n) } }
    }
    // Find Bounce window
    var abpWins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &abpWins)
    guard let abpWindows = abpWins as? [AXUIElement],
          let abpBounceWin = abpWindows.first(where: {
              var t: CFTypeRef?
              AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &t)
              return (t as? String ?? "").contains("Bounce")
          }) else { jsonOut(["ok": false, "error": "Bounce window not found"]); break }
    // Get Logic PID — used for Escape key in abpSetPopup
    var abpLogicPid: pid_t = 0; AXUIElementGetPid(logic, &abpLogicPid)
    // Helper: select a row using AX attribute (no mouse click — safe regardless of window z-order)
    func abpSelectRow(_ row: AXUIElement) {
        AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, true as CFTypeRef)
    }
    // Find destination row checkboxes
    let abpRows = findAll(abpBounceWin, role: "AXRow", depth: 10)
    // WAV / Uncompressed checkbox (row 0, first checkbox)
    var abpWavCB: AXUIElement? = nil
    if !abpRows.isEmpty { abpWavCB = findAll(abpRows[0], role: "AXCheckBox", depth: 5).first }
    // MP3 checkbox (row 1, title "MP3" — or first checkbox in row 1 on Intel where title is empty)
    var abpMp3CB: AXUIElement? = nil
    if abpRows.count > 1 {
        let mp3RowCbs = findAll(abpRows[1], role: "AXCheckBox", depth: 5)
        for cb in mp3RowCbs {
            if axTitle(cb).lowercased().contains("mp3") { abpMp3CB = cb; break }
        }
        // Fallback: Intel Logic 10.7 checkboxes have no title — use first checkbox in MP3 row
        if abpMp3CB == nil, let firstCb = mp3RowCbs.first { abpMp3CB = firstCb }
    }
    let abpWavIsOn = abpWavCB.map { axIntValue($0) == 1 } ?? true
    let abpMp3IsOn = abpMp3CB.map { axIntValue($0) == 1 } ?? false
    // wavEnabled param: "1" = ensure WAV checkbox ON, "0" = OFF, absent = don't touch
    if let wavStr = abpParams["wavEnabled"], let cb = abpWavCB {
        let wantOn = (wavStr == "1" || wavStr == "true")
        if abpWavIsOn != wantOn { axPress(cb); Thread.sleep(forTimeInterval: 0.3) }
    }
    // mp3Enabled param: "1" = ensure MP3 checkbox ON, "0" = OFF, absent = don't touch
    if let mp3Str = abpParams["mp3Enabled"], let cb = abpMp3CB {
        let wantOn = (mp3Str == "1" || mp3Str == "true")
        if abpMp3IsOn != wantOn {
            axPress(cb)
            Thread.sleep(forTimeInterval: 0.5)
            // Auto-dismiss "Enabling this destination disables Split Stereo and Surround. Proceed?"
            var abpAllWinsAfterMp3: CFTypeRef?
            AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &abpAllWinsAfterMp3)
            if let winsArr = abpAllWinsAfterMp3 as? [AXUIElement] {
                for w in winsArr {
                    let btns = findAll(w, role: "AXButton", depth: 5)
                    for btn in btns {
                        let t = axTitle(btn)
                        if t == "Proceed" || t == "OK" {
                            axPress(btn)
                            Thread.sleep(forTimeInterval: 0.3)
                            break
                        }
                    }
                }
            }
        }
    }
    // dest param: which row to display (0=WAV row, 1=MP3 row)
    if let abpDestStr = abpParams["dest"], let abpDestIdx = Int(abpDestStr) {
        let targetRow = (abpDestIdx == 1 || abpDestIdx == 2) ? 1 : 0
        if abpRows.count > targetRow {
            let already = (axVal(abpRows[targetRow], kAXSelectedAttribute as String) as? Bool) ?? false
            if !already { abpSelectRow(abpRows[targetRow]); Thread.sleep(forTimeInterval: targetRow == 1 ? 0.7 : 0.5) }
        }
    }
    // Get bounce window top Y — used to convert absolute → relative Y for popup matching
    var abpWinPos: CFTypeRef?
    AXUIElementCopyAttributeValue(abpBounceWin, kAXPositionAttribute as CFString, &abpWinPos)
    var abpWinPt = CGPoint.zero
    if let av = abpWinPos as! AXValue? { AXValueGetValue(av, .cgPoint, &abpWinPt) }
    let abpWinTop = Int(abpWinPt.y)
    // Get all popup-like controls sorted by relative Y position
    // Logic Bounce dialog uses BOTH AXPopUpButton and AXMenuButton for its dropdowns
    let abpPopupBtns = findAll(abpBounceWin, role: "AXPopUpButton", depth: 10)
    let abpMenuBtns  = findAll(abpBounceWin, role: "AXMenuButton",  depth: 10)
    let abpPopups    = abpPopupBtns + abpMenuBtns
    let abpSortedPopups = abpPopups.sorted {
        var p1: CFTypeRef?; AXUIElementCopyAttributeValue($0, kAXPositionAttribute as CFString, &p1)
        var p2: CFTypeRef?; AXUIElementCopyAttributeValue($1, kAXPositionAttribute as CFString, &p2)
        var pt1 = CGPoint.zero; var pt2 = CGPoint.zero
        if let av = p1 as! AXValue? { AXValueGetValue(av, .cgPoint, &pt1) }
        if let av = p2 as! AXValue? { AXValueGetValue(av, .cgPoint, &pt2) }
        return pt1.y < pt2.y
    }
    // Helper: set popup value by pressing it and finding the menu item
    var abpSetResults: [String: Bool] = [:]
    func abpSetPopup(_ popup: AXUIElement, _ newVal: String) -> Bool {
        let curVal = (axVal(popup, kAXValueAttribute) as? String) ?? ""
        if curVal == newVal { return true }
        axPress(popup)
        // Retry loop: wait for menu to appear (up to 5 attempts)
        var abpMenuWasOpen = false
        let newValLower = newVal.lowercased()
        // Normalize: "24-bit" → "24 bit", "24 Bit" → "24 bit" — handles Intel vs new Logic differences
        let newValNorm = newValLower.replacingOccurrences(of: "-", with: " ")
        func tryItems(_ items: [AXUIElement]) -> Bool {
            // Exact match first
            for item in items { if axTitle(item) == newVal { axPress(item); tsleep(0.6); return true } }
            // Normalized match: "24-bit" == "24 Bit", "32 Bit Float" == "32-bit float"
            for item in items {
                let t = axTitle(item)
                let tNorm = t.lowercased().replacingOccurrences(of: "-", with: " ")
                if tNorm == newValNorm { axPress(item); tsleep(0.6); return true }
            }
            // Partial match fallback (handles "kBit/s" vs "kbit/s", truncated labels, etc.)
            for item in items { let t = axTitle(item); if t.lowercased().contains(newValLower) || newValLower.contains(t.lowercased().prefix(6)) { axPress(item); tsleep(0.6); return true } }
            return false
        }
        for attempt in 0..<5 {
            Thread.sleep(forTimeInterval: attempt == 0 ? 1.0 : 0.5)
            // Method 1: popup's own children (dropdown menu as child element)
            var abpKids: CFTypeRef?
            AXUIElementCopyAttributeValue(popup, kAXChildrenAttribute as CFString, &abpKids)
            if let menu = (abpKids as? [AXUIElement])?.first {
                let items = findAll(menu, role: "AXMenuItem", depth: 3)
                if !items.isEmpty {
                    abpMenuWasOpen = true
                    if tryItems(items) { return true }
                    // Items found but no match — menu is genuinely open with wrong/unexpected items;
                    // fall through to Method 2 in same attempt before giving up
                }
            }
            // Method 2: search all Logic windows (menu appears as a separate floating window)
            var abpAllWins: CFTypeRef?
            AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &abpAllWins)
            if let winsArr = abpAllWins as? [AXUIElement] {
                var allItems: [AXUIElement] = []
                for w in winsArr { allItems += findAll(w, role: "AXMenuItem", depth: 15) }
                if !allItems.isEmpty {
                    abpMenuWasOpen = true
                    if tryItems(allItems) { return true }
                    break // menu open but target genuinely not there
                }
            }
        }
        // Only send Escape if the menu was actually open (prevents accidentally closing Bounce dialog)
        if abpMenuWasOpen {
            let abpSrcEsc = CGEventSource(stateID: .hidSystemState)
            if let dn = CGEvent(keyboardEventSource: abpSrcEsc, virtualKey: 53, keyDown: true),
               let up = CGEvent(keyboardEventSource: abpSrcEsc, virtualKey: 53, keyDown: false) {
                dn.postToPid(abpLogicPid); up.postToPid(abpLogicPid)
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }
    // Identify each popup by its current value content (works across all Logic versions)
    // Also track relative Y for fallback and MP3-specific popups
    for abpPopup in abpSortedPopups {
        Thread.sleep(forTimeInterval: 0.12)
        var abpPos: CFTypeRef?; AXUIElementCopyAttributeValue(abpPopup, kAXPositionAttribute as CFString, &abpPos)
        var abpPt = CGPoint.zero
        if let av = abpPos as! AXValue? { AXValueGetValue(av, .cgPoint, &abpPt) }
        let abpY = Int(abpPt.y) - abpWinTop
        let curVal = (axVal(abpPopup, kAXValueAttribute) as? String) ?? ""
        // Identify popup type by its current value
        let isFileFormat = ["WAVE","Wave","AIFF","CAF","WAVE64","MP3"].contains(curVal)
        let isBitDepth = curVal.lowercased().contains("bit") && !curVal.lowercased().contains("kbit")
        let isSampleRateKHz = curVal.contains("kHz") || curVal.contains("Hz")
        let isSampleRateRaw = ["22050","44100","48000","88200","96000","176400","192000"].contains(curVal)
        let isSampleRate = isSampleRateKHz || isSampleRateRaw
        let isInterleaved = ["Interleaved","Split"].contains(curVal)
        let isDithering = curVal.contains("POW-r") || curVal == "None" || curVal.contains("UV22")
        let isNormalize = ["On","Off","Overload Protection Only"].contains(curVal)
        let isMode = curVal.contains("Realtime") || curVal.contains("Offline") || curVal.contains("Online")
        let isMp3Rate = curVal.lowercased().contains("kbit") || curVal.lowercased().contains("kbps")
        let isMp3Stereo = curVal == "Joint Stereo" || curVal == "Stereo" || curVal == "Mono"
        // Bounce Range popup: "Locators" / "Cycle" / "Song End" / "Project End" / "End of last region"
        let isRange = ["Locators","Cycle","Cycle Area","Song End","Project End",
                       "End of last region","End of Last Region","Sequence End","Project Length"].contains(curVal)
                      || (curVal.lowercased().contains("locator") && !curVal.lowercased().contains("kbit"))

        if isFileFormat, let val = abpParams["fileType"] {
            abpSetResults["fileType"] = abpSetPopup(abpPopup, val)
        } else if isBitDepth, let val = abpParams["bitDepth"] {
            abpSetResults["bitDepth"] = abpSetPopup(abpPopup, val)
        } else if isSampleRate, let val = abpParams["sampleRate"] {
            // Handle both "48 kHz" and "48000" formats
            let srDisplayMap = ["44100": "44.1 kHz", "48000": "48 kHz", "96000": "96 kHz",
                                "44.1 kHz": "44.1 kHz", "48 kHz": "48 kHz", "96 kHz": "96 kHz"]
            let srRawMap = ["44100": "44100", "48000": "48000", "96000": "96000",
                            "44.1 kHz": "44100", "48 kHz": "48000", "96 kHz": "96000"]
            if isSampleRateRaw {
                let target = srRawMap[val] ?? val
                abpSetResults["sampleRate"] = abpSetPopup(abpPopup, target)
            } else {
                let target = srDisplayMap[val] ?? val
                abpSetResults["sampleRate"] = abpSetPopup(abpPopup, target)
            }
        } else if isInterleaved, let val = abpParams["interleaved"] {
            abpSetResults["interleaved"] = abpSetPopup(abpPopup, val)
        } else if isDithering, let val = abpParams["dithering"] {
            abpSetResults["dithering"] = abpSetPopup(abpPopup, val)
        } else if isMode, let val = abpParams["mode"] {
            abpSetResults["mode"] = abpSetPopup(abpPopup, val)
        } else if isRange, let val = abpParams["bounceRange"] {
            abpSetResults["bounceRange"] = abpSetPopup(abpPopup, val)
        } else if isNormalize, let val = abpParams["normalize"] {
            abpSetResults["normalize"] = abpSetPopup(abpPopup, val)
        } else if isMp3Rate {
            // MP3 bit rate — distinguish stereo vs mono by position (stereo first, mono second)
            if abpSetResults["mp3RateStereo"] == nil {
                let val = abpParams["mp3RateStereo"] ?? abpParams["mp3Rate"]
                if let v = val { abpSetResults["mp3RateStereo"] = abpSetPopup(abpPopup, v) }
            } else {
                let val = abpParams["mp3RateMono"] ?? abpParams["mp3Rate"]
                if let v = val { abpSetResults["mp3RateMono"] = abpSetPopup(abpPopup, v) }
            }
        } else if isMp3Stereo, let val = abpParams["mp3Stereo"] {
            abpSetResults["mp3Stereo"] = abpSetPopup(abpPopup, val)
        } else {
            // Fallback: use relative Y position for unrecognized popups
            if let val = abpParams["fileType"],    abs(abpY - 48)  <= 15 { abpSetResults["fileType"]    = abpSetPopup(abpPopup, val) }
            if let val = abpParams["bitDepth"],    abs(abpY - 78)  <= 15 { abpSetResults["bitDepth"]    = abpSetPopup(abpPopup, val) }
            if let val = abpParams["sampleRate"],  abs(abpY - 108) <= 15 { abpSetResults["sampleRate"]  = abpSetPopup(abpPopup, val) }
            if let val = abpParams["interleaved"], abs(abpY - 138) <= 15 { abpSetResults["interleaved"] = abpSetPopup(abpPopup, val) }
            if let val = abpParams["dithering"],   abs(abpY - 168) <= 15 { abpSetResults["dithering"]   = abpSetPopup(abpPopup, val) }
            if let val = abpParams["mode"],        abs(abpY - 240) <= 20 { abpSetResults["mode"]        = abpSetPopup(abpPopup, val) }
            if let val = abpParams["normalize"],   abpY >= 305 && abpY <= 365 { abpSetResults["normalize"] = abpSetPopup(abpPopup, val) }
        }
    }
    // Set Mode via AXRadioButton (Realtime / Offline) — not a popup on any Logic version
    if let modeVal = abpParams["mode"] {
        let radios = findAll(abpBounceWin, role: "AXRadioButton", depth: 10)
        let modeNorm = modeVal.lowercased().replacingOccurrences(of: "-", with: " ")
        for radio in radios {
            let t = axTitle(radio)
            let tNorm = t.lowercased().replacingOccurrences(of: "-", with: " ")
            if tNorm == modeNorm || t.lowercased().contains(modeNorm.prefix(6)) {
                if axIntValue(radio) != 1 { axPress(radio); Thread.sleep(forTimeInterval: 0.2) }
                abpSetResults["mode"] = true
                break
            }
        }
    }
    // Set named checkboxes
    func abpSetCheckbox(_ name: String, _ enabled: Bool) {
        let cbs = findAll(abpBounceWin, role: "AXCheckBox", depth: 10)
        for cb in cbs {
            if axTitle(cb) == name {
                let cur = axIntValue(cb)
                let want = enabled ? 1 : 0
                if cur != want { axPress(cb); Thread.sleep(forTimeInterval: 0.15) }
                abpSetResults[name] = true
                return
            }
        }
    }
    let abpCbMap: [(String, String)] = [
        ("includeTempo",       "Include Tempo Information"),
        ("includeAudioTail",   "Include Audio Tail"),
        ("bounce2ndCyclePass", "Bounce 2nd Cycle Pass"),
        ("mp3VBR",             "Use Variable Bit Rate Encoding (VBR)"),
        ("mp3BestEncoding",    "Use best encoding"),
        ("mp3Filter10hz",      "Filter frequencies below 10 Hz"),
    ]
    for (key, cbName) in abpCbMap {
        if let val = abpParams[key] { abpSetCheckbox(cbName, val == "1" || val == "true") }
    }
    var abpOut: [String: Any] = ["ok": true]
    var abpSetOut: [String: Any] = [:]
    for (k, v) in abpSetResults { abpSetOut[k] = v }
    abpOut["set"] = abpSetOut
    jsonOut(abpOut)

case "getBounceParams":
    // Read current format params from open Bounce dialog
    var gbpWins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &gbpWins)
    guard let gbpWindows = gbpWins as? [AXUIElement],
          let gbpBounceWin = gbpWindows.first(where: {
              var t: CFTypeRef?
              AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &t)
              return (t as? String ?? "").contains("Bounce")
          }) else { jsonOut(["ok": false, "error": "Bounce window not found"]); break }
    // Find selected destination row index
    let gbpRows = findAll(gbpBounceWin, role: "AXRow", depth: 10)
    var gbpDestIdx = 0
    for (i, row) in gbpRows.enumerated() {
        if let sel = axVal(row, kAXSelectedAttribute as String) as? Bool, sel { gbpDestIdx = i; break }
    }
    // Get all popups sorted by Y
    let gbpPopups = findAll(gbpBounceWin, role: "AXPopUpButton", depth: 10)
    let gbpSortedPopups = gbpPopups.sorted {
        var p1: CFTypeRef?; AXUIElementCopyAttributeValue($0, kAXPositionAttribute as CFString, &p1)
        var p2: CFTypeRef?; AXUIElementCopyAttributeValue($1, kAXPositionAttribute as CFString, &p2)
        var pt1 = CGPoint.zero; var pt2 = CGPoint.zero
        if let av = p1 as! AXValue? { AXValueGetValue(av, .cgPoint, &pt1) }
        if let av = p2 as! AXValue? { AXValueGetValue(av, .cgPoint, &pt2) }
        return pt1.y < pt2.y
    }
    var gbpResult: [String: Any] = ["dest": gbpDestIdx]
    for gbpPopup in gbpSortedPopups {
        var gbpPos: CFTypeRef?; AXUIElementCopyAttributeValue(gbpPopup, kAXPositionAttribute as CFString, &gbpPos)
        var gbpPt = CGPoint.zero
        if let av = gbpPos as! AXValue? { AXValueGetValue(av, .cgPoint, &gbpPt) }
        let gbpY = Int(gbpPt.y)
        let gbpVal = (axVal(gbpPopup, kAXValueAttribute) as? String) ?? ""
        // Identify popups by value content (works across Logic versions with different layouts)
        let gbpIsRange = ["Locators","Cycle","Cycle Area","Song End","Project End",
                          "End of last region","End of Last Region","Sequence End","Project Length"].contains(gbpVal)
                         || (gbpVal.lowercased().contains("locator") && !gbpVal.lowercased().contains("kbit"))
                         || gbpVal.lowercased().contains("end of") || gbpVal.lowercased().contains("project end")
        if ["WAVE","AIFF","CAF","WAVE64"].contains(gbpVal) {
            gbpResult["fileFormat"] = gbpVal
        } else if gbpIsRange {
            gbpResult["bounceRange"] = gbpVal
        } else if gbpVal.lowercased().contains("bit") {
            gbpResult["bitDepth"] = gbpVal
        } else if gbpVal.contains("kHz") || gbpVal.contains("Hz") {
            gbpResult["sampleRate"] = gbpVal
        } else if ["22050","44100","48000","88200","96000","176400","192000"].contains(gbpVal) {
            gbpResult["sampleRate"] = gbpVal
        } else if ["Interleaved","Split"].contains(gbpVal) {
            gbpResult["fileType"] = gbpVal
        } else if gbpVal.contains("POW-r") || gbpVal == "None" || gbpVal.contains("UV22") {
            gbpResult["dithering"] = gbpVal
        } else if ["On","Off","Overload Protection Only"].contains(gbpVal) {
            gbpResult["normalize"] = gbpVal
        } else {
            // Log unrecognized popup so we can identify bounceRange value
            fputs("[getBounceParams] UNRECOGNIZED popup y=\(gbpY) val='\(gbpVal)'\n", stderr)
            // Fallback: use Y position
            if abs(gbpY - 187) <= 15 { gbpResult["fileType"]   = gbpVal }
            if abs(gbpY - 217) <= 15 { gbpResult["bitDepth"]   = gbpVal }
            if abs(gbpY - 247) <= 15 { gbpResult["sampleRate"] = gbpVal }
            if abs(gbpY - 307) <= 15 { gbpResult["dithering"]  = gbpVal }
            if abs(gbpY - 277) <= 15 { gbpResult["interleaved"] = gbpVal }
            if abs(gbpY - 379) <= 15 { gbpResult["mode"]       = gbpVal }
            if abs(gbpY - 471) <= 15 { gbpResult["normalize"]  = gbpVal }
        }
    }
    // Read Mode from radio buttons (Realtime / Offline — never a popup)
    let gbpRadios = findAll(gbpBounceWin, role: "AXRadioButton", depth: 10)
    for radio in gbpRadios {
        if axIntValue(radio) == 1 {
            let t = axTitle(radio)
            if !t.isEmpty { gbpResult["mode"] = t; break }
        }
    }
    // Read named checkboxes
    let gbpCbs = findAll(gbpBounceWin, role: "AXCheckBox", depth: 10)
    for cb in gbpCbs {
        let t = axTitle(cb)
        switch t {
        case "Include Tempo Information": gbpResult["includeTempo"]       = axIntValue(cb) == 1
        case "Include Audio Tail":        gbpResult["includeAudioTail"]   = axIntValue(cb) == 1
        case "Bounce 2nd Cycle Pass":     gbpResult["bounce2ndCyclePass"] = axIntValue(cb) == 1
        default: break
        }
    }
    jsonOut(["ok": true, "params": gbpResult])

case "debugBounce":
    // Dump all AX elements inside the Bounce dialog for diagnostics
    var dbWins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &dbWins)
    guard let dbWindows = dbWins as? [AXUIElement],
          let bounceWin = dbWindows.first(where: {
              var t: CFTypeRef?
              AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &t)
              return (t as? String ?? "").contains("Bounce")
          }) else { jsonOut(["error": "Bounce window not found"]); break }
    // Collect all popups with their values
    let dbPopups = findAll(bounceWin, role: "AXPopUpButton", depth: 10)
    var popupInfo: [[String: Any]] = []
    for p in dbPopups {
        var pos: CFTypeRef?; AXUIElementCopyAttributeValue(p, kAXPositionAttribute as CFString, &pos)
        var pt = CGPoint.zero
        if let av = pos as! AXValue? { AXValueGetValue(av, .cgPoint, &pt) }
        let val = (axVal(p, kAXValueAttribute) as? String) ?? ""
        let desc = (axVal(p, kAXDescriptionAttribute) as? String) ?? ""
        let title = (axVal(p, kAXTitleAttribute) as? String) ?? ""
        popupInfo.append(["val": val, "desc": desc, "title": title, "x": Int(pt.x), "y": Int(pt.y)])
    }
    // Collect all checkboxes
    let dbCbs = findAll(bounceWin, role: "AXCheckBox", depth: 10)
    var cbInfo: [[String: Any]] = []
    for c in dbCbs {
        let title = (axVal(c, kAXTitleAttribute) as? String) ?? (axVal(c, kAXDescriptionAttribute) as? String) ?? ""
        let val = axIntValue(c)
        cbInfo.append(["title": title, "val": val])
    }
    // Collect table/list rows (Destination)
    let dbRows = findAll(bounceWin, role: "AXRow", depth: 10)
    var rowInfo: [[String: Any]] = []
    for r in dbRows {
        let title = axTitle(r)
        let sel = (axVal(r, kAXSelectedAttribute) as? Bool) ?? false
        rowInfo.append(["title": title, "selected": sel])
    }
    jsonOut(["ok": true, "popups": popupInfo, "checkboxes": cbInfo, "rows": rowInfo])

case "debugMenuAtY":
    // Press popup at given Y position and dump its menu items
    // Usage: debugMenuAtY <targetY>
    guard args.count >= 3, let dmY = Int(args[2]) else { jsonOut(["error": "need Y arg"]); break }
    var dmWins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &dmWins)
    guard let dmWindows = dmWins as? [AXUIElement],
          let dmBounceWin = dmWindows.first(where: {
              var t: CFTypeRef?; AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &t)
              return (t as? String ?? "").contains("Bounce")
          }) else { jsonOut(["error": "Bounce window not found"]); break }
    let dmPopups = findAll(dmBounceWin, role: "AXPopUpButton", depth: 10)
    var dmTarget: AXUIElement? = nil
    for p in dmPopups {
        var pos: CFTypeRef?; AXUIElementCopyAttributeValue(p, kAXPositionAttribute as CFString, &pos)
        var pt = CGPoint.zero
        if let av = pos as! AXValue? { AXValueGetValue(av, .cgPoint, &pt) }
        if abs(Int(pt.y) - dmY) <= 20 { dmTarget = p; break }
    }
    guard let dmPopup = dmTarget else { jsonOut(["error": "popup not found at y=\(dmY)"]); break }
    let dmCurVal = (axVal(dmPopup, kAXValueAttribute) as? String) ?? ""
    axPress(dmPopup)
    tsleep(0.7)
    var dmKids: CFTypeRef?
    AXUIElementCopyAttributeValue(dmPopup, kAXChildrenAttribute as CFString, &dmKids)
    var dmItems: [[String: Any]] = []
    if let menu = (dmKids as? [AXUIElement])?.first {
        for item in findAll(menu, role: "AXMenuItem", depth: 3) {
            let t = axTitle(item)
            let bytes = Array(t.utf8)
            dmItems.append(["title": t, "bytes": bytes])
        }
    }
    // Also try Method 2: all Logic windows
    var dmWinItems: [[String: Any]] = []
    if dmItems.isEmpty {
        var dmAllWins: CFTypeRef?
        AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &dmAllWins)
        if let wa = dmAllWins as? [AXUIElement] {
            for w in wa {
                for item in findAll(w, role: "AXMenuItem", depth: 15) {
                    let t = axTitle(item)
                    let bytes = Array(t.utf8)
                    dmWinItems.append(["title": t, "bytes": bytes])
                }
            }
        }
    }
    // Method 3: system-wide focused element
    var dmSysItems: [[String: Any]] = []
    if dmItems.isEmpty && dmWinItems.isEmpty {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        if let fe = focused as! AXUIElement? {
            // Walk up to find the menu
            var cur: AXUIElement = fe
            for _ in 0..<5 {
                for item in findAll(cur, role: "AXMenuItem", depth: 5) {
                    let t = axTitle(item)
                    dmSysItems.append(["title": t, "bytes": Array(t.utf8)])
                }
                if !dmSysItems.isEmpty { break }
                var parent: CFTypeRef?
                AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent)
                guard let p = parent as! AXUIElement? else { break }
                cur = p
            }
        }
    }
    var dmPid: pid_t = 0; AXUIElementGetPid(dmPopup, &dmPid)
    if let dn = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
       let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) {
        dn.postToPid(dmPid); up.postToPid(dmPid)
    }
    jsonOut(["ok": true, "currentVal": dmCurVal, "y": dmY, "items": dmItems, "windowItems": dmWinItems, "sysItems": dmSysItems])

case "debugSRMenu":
    // Press the sampleRate popup (y~247) and dump all menu items — diagnostics
    var dsrWins: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &dsrWins)
    guard let dsrWindows = dsrWins as? [AXUIElement],
          let dsrBounceWin = dsrWindows.first(where: {
              var t: CFTypeRef?; AXUIElementCopyAttributeValue($0, kAXTitleAttribute as CFString, &t)
              return (t as? String ?? "").contains("Bounce")
          }) else { jsonOut(["error": "Bounce window not found"]); break }
    let dsrPopups = findAll(dsrBounceWin, role: "AXPopUpButton", depth: 10)
    var dsrSR: AXUIElement? = nil
    for p in dsrPopups {
        var pos: CFTypeRef?; AXUIElementCopyAttributeValue(p, kAXPositionAttribute as CFString, &pos)
        var pt = CGPoint.zero
        if let av = pos as! AXValue? { AXValueGetValue(av, .cgPoint, &pt) }
        if abs(Int(pt.y) - 247) <= 15 { dsrSR = p; break }
    }
    guard let srPopup = dsrSR else { jsonOut(["error": "sampleRate popup not found"]); break }
    axPress(srPopup)
    tsleep(0.6)
    var dsrKids: CFTypeRef?
    AXUIElementCopyAttributeValue(srPopup, kAXChildrenAttribute as CFString, &dsrKids)
    var items: [[String: Any]] = []
    if let menu = (dsrKids as? [AXUIElement])?.first {
        for item in findAll(menu, role: "AXMenuItem", depth: 3) {
            let t = axTitle(item); let e = (axVal(item, kAXEnabledAttribute) as? Bool) ?? true
            items.append(["title": t, "enabled": e])
        }
    }
    // also check all windows
    var dsrWins2: CFTypeRef?
    AXUIElementCopyAttributeValue(logic, kAXWindowsAttribute as CFString, &dsrWins2)
    var winItems: [[String: Any]] = []
    if let wa = dsrWins2 as? [AXUIElement] {
        for w in wa {
            for item in findAll(w, role: "AXMenuItem", depth: 15) {
                winItems.append(["title": axTitle(item)])
            }
        }
    }
    // Press Escape to close menu
    var dsrPid: pid_t = 0; AXUIElementGetPid(srPopup, &dsrPid)
    if let dn = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
       let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) {
        dn.postToPid(dsrPid); up.postToPid(dsrPid)
    }
    jsonOut(["ok": true, "childMenuItems": items, "windowMenuItems": winItems])

case "debugBtn":
    // Dump all AX attributes of solo+mute buttons for first channel — for diagnostics
    let dbCh = scanChannels(logic)
    guard let first = dbCh.first else { jsonOut(["error": "no channels found"]); break }
    func dumpBtn(_ btn: AXUIElement, _ label: String) -> [String: Any] {
        var attrNames: CFArray?
        AXUIElementCopyAttributeNames(btn, &attrNames)
        var result: [String: String] = [:]
        if let names = attrNames as? [String] {
            for attr in names {
                if let v = axVal(btn, attr) {
                    result[attr] = "\(v)"
                }
            }
        }
        return ["label": label, "role": axRole(btn), "attrs": result]
    }
    jsonOut(["ok": true, "channel": first.name,
             "solo": dumpBtn(first.soloBtn, "solo"),
             "mute": dumpBtn(first.muteBtn, "mute")])

case "scan-tree":
    // Find "Tracks header" group (contains AXDisclosureTriangle per track)
    func findTracksHeaderGroup(_ logicApp: AXUIElement) -> AXUIElement? {
        guard let wins = axVal(logicApp, kAXWindowsAttribute) as? [AXUIElement],
              let win = wins.first else { return nil }
        func dfs(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            if depth > 8 { return nil }
            if axRole(el) == "AXScrollArea" {
                for kid in axKids(el) {
                    if (axVal(kid, kAXDescriptionAttribute) as? String) == "Tracks header" { return kid }
                }
            }
            for kid in axKids(el) { if let r = dfs(kid, depth + 1) { return r } }
            return nil
        }
        return dfs(win, 0)
    }

    // Find first disclosure triangle with given expanded state (any position — optClickTriangle scrolls to center)
    // Works on both M1 (AXDisclosureTriangle) and Intel Logic 10.7 (AXButton with empty desc)
    func findTriangle(_ group: AXUIElement, expanded: Bool) -> AXUIElement? {
        for item in axKids(group) {
            guard (axVal(item, kAXDescriptionAttribute) as? String ?? "").hasPrefix("Track ") else { continue }
            for kid in axKids(item) {
                guard isDisclosureTriangle(kid) else { continue }
                // AXDisclosureTriangle has proper value (0/1) — filter by expanded state
                // AXButton on Intel may not have value — accept it regardless of expanded param
                let role = axRole(kid)
                if role == "AXDisclosureTriangle" {
                    if axIntValue(kid) == (expanded ? 1 : 0) { return kid }
                } else {
                    // AXButton fallback: check value if available, otherwise accept any
                    let val = axVal(kid, kAXValueAttribute)
                    if val == nil { return kid }  // no value — can't filter, accept it
                    if axIntValue(kid) == (expanded ? 1 : 0) { return kid }
                }
            }
        }
        return nil
    }

    // Scroll the Arrange tracks to the top so group triangles are visible
    func scrollTracksToTop(_ win: AXUIElement) {
        func dfs(_ el: AXUIElement, _ depth: Int) -> Bool {
            if depth > 6 { return false }
            if axRole(el) == "AXScrollArea" {
                for kid in axKids(el) {
                    if (axVal(kid, kAXDescriptionAttribute) as? String) == "Tracks header" {
                        var sbRef: CFTypeRef?
                        AXUIElementCopyAttributeValue(el, kAXVerticalScrollBarAttribute as CFString, &sbRef)
                        if let sb = sbRef as! AXUIElement? {
                            AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, 0.0 as CFTypeRef)
                        }
                        return true
                    }
                }
            }
            for kid in axKids(el) { if dfs(kid, depth + 1) { return true } }
            return false
        }
        _ = dfs(win, 0)
    }

    // Option+click a disclosure triangle → affects ALL stacks
    // Scroll-to-center only if needed + python CGEvent click
    func optClickTriangle(_ tri: AXUIElement) {
        if let sa = contentScrollArea ?? arrangeScrollArea, let bar = arrangeScrollBar {
            // Read scroll area bounds
            var spRef: CFTypeRef?; var ssRef: CFTypeRef?
            AXUIElementCopyAttributeValue(sa, kAXPositionAttribute as CFString, &spRef)
            AXUIElementCopyAttributeValue(sa, kAXSizeAttribute as CFString, &ssRef)
            var saP = CGPoint.zero; var saS = CGSize.zero
            if let pv = spRef { AXValueGetValue(pv as! AXValue, .cgPoint, &saP) }
            if let sv = ssRef { AXValueGetValue(sv as! AXValue, .cgSize, &saS) }

            // Read triangle position BEFORE any scroll
            var curPosRef: CFTypeRef?
            AXUIElementCopyAttributeValue(tri, kAXPositionAttribute as CFString, &curPosRef)
            var curPt = CGPoint.zero
            if let pv = curPosRef { AXValueGetValue(pv as! AXValue, .cgPoint, &curPt) }

            let triVisible = curPt.y > saP.y + 10 && curPt.y < saP.y + saS.height - 20

            if !triVisible {
                // Not visible — try AXScrollToVisible first
                AXUIElementPerformAction(tri, "AXScrollToVisible" as CFString)
                Thread.sleep(forTimeInterval: 0.20)

                // Re-check visibility after AXScrollToVisible
                var p2Ref: CFTypeRef?
                AXUIElementCopyAttributeValue(tri, kAXPositionAttribute as CFString, &p2Ref)
                var pt2 = CGPoint.zero
                if let pv = p2Ref { AXValueGetValue(pv as! AXValue, .cgPoint, &pt2) }
                let stillInvisible = pt2.y <= saP.y + 10 || pt2.y >= saP.y + saS.height - 20

                if stillInvisible {
                    // Fallback: calibration scroll-to-center
                    let targetY = saP.y + saS.height / 2
                    AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 0.0 as CFTypeRef)
                    Thread.sleep(forTimeInterval: 0.18)
                    var p0Ref: CFTypeRef?
                    AXUIElementCopyAttributeValue(tri, kAXPositionAttribute as CFString, &p0Ref)
                    var y0: CGFloat = 0
                    if let pv = p0Ref { var pt = CGPoint.zero; AXValueGetValue(pv as! AXValue, .cgPoint, &pt); y0 = pt.y }

                    AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 0.1 as CFTypeRef)
                    Thread.sleep(forTimeInterval: 0.18)
                    var p1Ref: CFTypeRef?
                    AXUIElementCopyAttributeValue(tri, kAXPositionAttribute as CFString, &p1Ref)
                    var y1: CGFloat = 0
                    if let pv = p1Ref { var pt = CGPoint.zero; AXValueGetValue(pv as! AXValue, .cgPoint, &pt); y1 = pt.y }

                    let pxPer01 = y0 - y1
                    if pxPer01 > 0 {
                        let needed = max(0.0, min(1.0, (y0 - targetY) / (pxPer01 * 10)))
                        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, needed as CFTypeRef)
                    } else {
                        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 0.0 as CFTypeRef)
                    }
                    Thread.sleep(forTimeInterval: 0.20)
                }
            }
            // If triVisible was true — skip all scrolling, click immediately
        }

        // Re-read position after scroll — wait longer for Logic AX layout to settle
        Thread.sleep(forTimeInterval: 0.20)
        var posRef: CFTypeRef?; var szRef: CFTypeRef?
        AXUIElementCopyAttributeValue(tri, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(tri, kAXSizeAttribute as CFString, &szRef)
        var pt = CGPoint.zero; var sz = CGSize.zero
        if let pv = posRef { AXValueGetValue(pv as! AXValue, .cgPoint, &pt) }
        if let sv = szRef { AXValueGetValue(sv as! AXValue, .cgSize, &sz) }

        // Safety check — if position is invalid (0,0 or tiny), skip click
        guard pt.x > 10 && pt.y > 50 else { return }

        // Save current mouse position to restore after click
        let origMouse = CGPoint(x: NSEvent.mouseLocation.x,
                                y: (NSScreen.main?.frame.height ?? 0) - NSEvent.mouseLocation.y)

        // Use actual size if valid, otherwise assume triangle is ~10x10px
        let triW = sz.width  > 2 ? sz.width  : 10
        let triH = sz.height > 2 ? sz.height : 10
        let cx = Int(pt.x + triW / 2)
        let cy = Int(pt.y + triH / 2)

        // Activate Logic + native Swift CGEvent Option+click
        if let logicApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first {
            logicApp.activate(options: [])
        }
        Thread.sleep(forTimeInterval: 0.12)

        let clickPt = CGPoint(x: cx, y: cy)
        if let eDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clickPt, mouseButton: .left) {
            eDown.flags = .maskAlternate
            eDown.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.05)
        if let eUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clickPt, mouseButton: .left) {
            eUp.flags = .maskAlternate
            eUp.post(tap: .cghidEventTap)
        }

        // Restore mouse to original position
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: origMouse, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // Adaptive stabilization — poll track count via axKids (no scroll needed)
    // maxWait increased to 15s for large projects (100+ tracks, slow machines)
    // stableRuns=3 means count must be stable for 3 consecutive polls (~450ms) before accepting
    func waitStable(reference: Int, expectMore: Bool, maxWait: Double = 15.0) -> Int {
        let start = Date()
        var lastCount = -1; var stableRuns = 0
        while Date().timeIntervalSince(start) < maxWait {
            Thread.sleep(forTimeInterval: 0.15)
            var count = 0
            if let h = hg0 {
                for item in axKids(h) {
                    if (axVal(item, kAXDescriptionAttribute) as? String ?? "").hasPrefix("Track ") { count += 1 }
                }
            }
            if count == 0 { continue }
            let passed = expectMore ? (count > reference) : (count < reference)
            if count == lastCount && count > 0 && passed {
                stableRuns += 1; if stableRuns >= 3 { return count }
            } else { stableRuns = 0; lastCount = count }
        }
        return lastCount
    }

    // ── Timing helper (stderr only) ──
    let _treeStart = Date()
    func _lap(_ msg: String) { fputs(String(format: "[%5.1fs] %@\n", Date().timeIntervalSince(_treeStart), msg), stderr) }

    // Activate Logic (quick, no sleep — it's already active from prior steps)
    if let logicApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first {
        logicApp.activate(options: [])
    }

    // Find window, scroll areas (header + content), header group, and VERTICAL scroll bar
    var treeWin: AXUIElement? = nil
    var arrangeScrollArea: AXUIElement? = nil
    var contentScrollArea: AXUIElement? = nil
    var arrangeScrollBar: AXUIElement? = nil
    var hg0: AXUIElement? = nil
    if let wins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement], let win = wins.first {
        treeWin = win
        func dfsFind(_ el: AXUIElement, _ depth: Int) -> Bool {
            if depth > 8 { return false }
            if axRole(el) == "AXSplitGroup" {
                var headerSA: AXUIElement? = nil
                var headerGroup: AXUIElement? = nil
                var foundContentSA: AXUIElement? = nil
                for kid in axKids(el) {
                    if axRole(kid) == "AXScrollArea" {
                        for sub in axKids(kid) {
                            let d = (axVal(sub, kAXDescriptionAttribute) as? String) ?? ""
                            if d == "Tracks header"   { headerSA = kid; headerGroup = sub }
                            if d == "Tracks contents" { foundContentSA = kid }
                        }
                    }
                }
                if let hsa = headerSA, let h = headerGroup, let csa = foundContentSA {
                    arrangeScrollArea = hsa
                    hg0 = h
                    contentScrollArea = csa
                    // Vertical scroll bar from CONTENT scroll area
                    var vbRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(csa, kAXVerticalScrollBarAttribute as CFString, &vbRef)
                    arrangeScrollBar = vbRef as! AXUIElement?
                    return true
                }
            }
            for kid in axKids(el) { if dfsFind(kid, depth + 1) { return true } }
            return false
        }
        _ = dfsFind(win, 0)
    }
    guard let hg0 = hg0 else {
        jsonOut(["error": "Tracks header not found"]); exit(1)
    }
    _lap("setup done (window + scroll bar + header)")

    // Find first triangle — axKids returns all, no scroll needed
    let firstExpandedTri = findTriangle(hg0, expanded: true)
    let firstCollapsedTri = firstExpandedTri != nil ? nil : findTriangle(hg0, expanded: false)
    let hasTriangles = firstExpandedTri != nil || firstCollapsedTri != nil
    _lap("triangles found: expanded=\(firstExpandedTri != nil) collapsed=\(firstCollapsedTri != nil)")

    // Collect all tracks + triangle nums — axKids returns ALL without scrolling
    func collectAllTracks() -> (tracks: [TrackInfo], triangleNums: Set<Int>) {
        var allTracks: [TrackInfo] = []
        var triNums = Set<Int>()
        for t in readTrackInfos(hg0) {
            allTracks.append(t)
            if t.hasTriangle { triNums.insert(t.num) }
        }
        _lap("  collectAllTracks: \(allTracks.count) tracks, \(triNums.count) tri")
        return (allTracks, triNums)
    }

    if hasTriangles {
        // ── Adaptive 3-step scan: collapse → expand → read → collapse ──
        _lap("Step 1: Collapse all")

        // Count tracks before collapse
        var countBefore = 0
        for item in axKids(hg0) {
            if (axVal(item, kAXDescriptionAttribute) as? String ?? "").hasPrefix("Track ") { countBefore += 1 }
        }

        // Step 1: Collapse all (single Option+click if any are expanded)
        // After collapse, verify count actually decreased — retry once if not
        if let tri = firstExpandedTri {
            optClickTriangle(tri)
            let c = waitStable(reference: countBefore, expectMore: false)
            _lap("Step 1: collapsed to \(c) tracks (was \(countBefore))")

            // Verify collapse worked: count should be less than before
            // If equal, Logic may have ignored the click — retry once
            if c >= countBefore {
                _lap("Step 1: collapse may have failed (count unchanged) — retrying…")
                Thread.sleep(forTimeInterval: 0.4)
                if let tri2 = findTriangle(hg0, expanded: true) {
                    optClickTriangle(tri2)
                    let c2 = waitStable(reference: countBefore, expectMore: false)
                    _lap("Step 1 retry: collapsed to \(c2) tracks")
                } else {
                    _lap("Step 1 retry: no expanded triangle found — already collapsed?")
                }
            }
        } else {
            _lap("Step 1: already collapsed")
        }

        // Read collapsed state (top-level groups + standalone tracks)
        let (beforeTracks, _) = collectAllTracks()
        let summaryNums = Set(beforeTracks.map { $0.num })

        // Step 2: Expand all (single Option+click)
        // After expand, verify count actually increased — retry once if not
        _lap("Step 2: Expand all")
        let collapsedCount = beforeTracks.count
        if let tri = findTriangle(hg0, expanded: false) {
            optClickTriangle(tri)
            let c = waitStable(reference: collapsedCount, expectMore: true)
            _lap("  expanded to \(c) tracks (was \(collapsedCount))")

            // Verify expand worked: count should be greater than collapsed count
            if c <= collapsedCount {
                _lap("  Step 2: expand may have failed (count unchanged) — retrying…")
                Thread.sleep(forTimeInterval: 0.4)
                if let tri2 = findTriangle(hg0, expanded: false) {
                    optClickTriangle(tri2)
                    let c2 = waitStable(reference: collapsedCount, expectMore: true)
                    _lap("  Step 2 retry: expanded to \(c2) tracks")
                } else {
                    _lap("  Step 2 retry: no collapsed triangle found — already expanded or no groups?")
                }
            }
        } else {
            _lap("  WARNING: no collapsed triangle found to expand!")
        }

        // Read fully expanded state + triangle info
        let (afterTracks, triangleNums) = collectAllTracks()
        let after = afterTracks
        _lap("Step 2 done: \(afterTracks.count) tracks, \(triangleNums.count) triangles")

        // Step 3: Collapse back (single Option+click, adaptive wait)
        let expandedCount = afterTracks.count
        _lap("Step 3: Collapse back")
        if let tri = findTriangle(hg0, expanded: true) {
            optClickTriangle(tri)
            let _ = waitStable(reference: expandedCount, expectMore: false)
        }
        _lap("Step 3 done")

        // Build tree — use summaryNums + triangleNums to classify each item
        // parentNum tracks by index (not name) to handle duplicate track names correctly
        var treeResult: [[String: Any]] = []
        var currentGroupNum = -1
        var currentGroupName = ""
        var currentSubgroupNum = -1
        var currentSubgroupName = ""
        for t in after {
            let isSummary = summaryNums.contains(t.num)
            let hasTri = triangleNums.contains(t.num)

            if isSummary && hasTri {
                currentGroupNum = t.num
                currentGroupName = t.name
                currentSubgroupNum = -1
                currentSubgroupName = ""
                treeResult.append(["num": t.num, "name": t.name, "type": "group",
                                   "parent": "", "parentNum": -1, "muted": t.muted ? 1 : 0])
            } else if isSummary && !hasTri {
                currentGroupNum = -1
                currentGroupName = ""
                currentSubgroupNum = -1
                currentSubgroupName = ""
                treeResult.append(["num": t.num, "name": t.name, "type": "track",
                                   "parent": "", "parentNum": -1, "muted": t.muted ? 1 : 0])
            } else if !isSummary && hasTri {
                currentSubgroupNum = t.num
                currentSubgroupName = t.name
                treeResult.append(["num": t.num, "name": t.name, "type": "group",
                                   "parent": currentGroupName, "parentNum": currentGroupNum,
                                   "muted": t.muted ? 1 : 0])
            } else {
                let parentNum = currentSubgroupNum >= 0 ? currentSubgroupNum : currentGroupNum
                let parentName = currentSubgroupName.isEmpty ? currentGroupName : currentSubgroupName
                treeResult.append(["num": t.num, "name": t.name, "type": "track",
                                   "parent": parentName, "parentNum": parentNum,
                                   "muted": t.muted ? 1 : 0])
            }
        }
        jsonOut(["tracks": treeResult])
    } else {
        // ── Project has NO summing stacks — flat list of all tracks ──
        if let sb = arrangeScrollBar { AXUIElementSetAttributeValue(sb, kAXValueAttribute as CFString, 0.0 as CFTypeRef); Thread.sleep(forTimeInterval: 0.05) }
        guard let tc0 = findTracksHeader(logic) else {
            jsonOut(["error": "Tracks not found"]); exit(1)
        }
        let allTracks = readTrackInfos(tc0)
        var treeResult: [[String: Any]] = []
        for t in allTracks {
            treeResult.append(["num": t.num, "name": t.name, "type": "track",
                               "parent": "", "muted": t.muted ? 1 : 0])
        }
        jsonOut(["tracks": treeResult])
    }

case "scanMasterPlugins":
    // Find MASTER plugins. Priority:
    // 0. Mixer direct — scrollToBnc already positioned the BNC strip + scrolled inserts up
    // 1. Inspector — if mixer didn't expose inserts
    // 2. Arrow-key navigation — last resort

    // 0. Mixer direct: find the BNC strip in the visible mixer layout
    var smpMaster: AXUIElement? = nil
    if let smpWins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement] {
        func smpFindLayouts(_ el: AXUIElement, _ d: Int, _ acc: inout [AXUIElement]) {
            if d > 6 { return }
            if axRole(el) == "AXLayoutArea" && (axVal(el, kAXDescriptionAttribute) as? String) == "Mixer" { acc.append(el) }
            for k in axKids(el) { smpFindLayouts(k, d+1, &acc) }
        }
        outerSmp: for win in smpWins {
            var layouts: [AXUIElement] = []
            smpFindLayouts(win, 0, &layouts)
            if let mixer = layouts.max(by: { axKids($0).count < axKids($1).count }) {
                for item in axKids(mixer) {
                    for kid in axKids(item) {
                        if axRole(kid) == "AXButton" {
                            let t = (axVal(kid, kAXTitleAttribute) as? String ?? "")
                            let d2 = (axVal(kid, kAXDescriptionAttribute) as? String ?? "").lowercased()
                            if t == "Bnc" || d2 == "bounce" { smpMaster = item; break outerSmp }
                        }
                    }
                }
            }
        }
    }
    if smpMaster != nil { fputs("[scanMasterPlugins] found BNC strip in Mixer directly\n", stderr) }

    // 1. Inspector fallback
    if smpMaster == nil { smpMaster = findInspectorMaster(logic) }

    // 2. If not found, navigate tracks via Arrange area to find Stereo Out (Bnc button)
    if smpMaster == nil {
        fputs("[scanMasterPlugins] Bounce channel not in Inspector, navigating tracks…\n", stderr)

        // Hide EasyBounce so Logic gets full focus for arrow keys
        let hideEB = Process()
        hideEB.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        hideEB.arguments = ["-e", "tell application \"System Events\" to set visible of process \"EasyBounce\" to false"]
        hideEB.standardOutput = Pipe(); hideEB.standardError = Pipe()
        try? hideEB.run(); hideEB.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.2)

        // Wake Logic after scan-tree AX manipulations
        let pos = CGEvent(source: nil)?.location ?? CGPoint(x: 500, y: 500)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: pos.x + 1, y: pos.y), mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)

        // Activate Logic so it receives keyboard events
        if let logicApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first {
            logicApp.activate()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Raise Arrange window (Tracks) so arrow keys navigate tracks, not Mixer
        if let wins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement] {
            for w in wins {
                let t = (axVal(w, kAXTitleAttribute) as? String) ?? ""
                if t.contains(" - Tracks") || t.hasSuffix(".logicx") {
                    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                    fputs("[scanMasterPlugins] raised Arrange window: \(t)\n", stderr)
                    Thread.sleep(forTimeInterval: 0.2)
                    break
                }
            }
        }

        let src = CGEventSource(stateID: .hidSystemState)

        // Check current track immediately
        if let found = findInspectorMaster(logic) {
            fputs("[scanMasterPlugins] found Bounce channel on current track!\n", stderr)
            smpMaster = found
        }

        // Phase A: arrow DOWN 40 steps
        if smpMaster == nil {
            for attempt in 0..<40 {
                if let ev = CGEvent(keyboardEventSource: src, virtualKey: 0x7D, keyDown: true),
                   let up = CGEvent(keyboardEventSource: src, virtualKey: 0x7D, keyDown: false) {
                    ev.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                }
                Thread.sleep(forTimeInterval: 0.25)
                if let found = findInspectorMaster(logic) {
                    fputs("[scanMasterPlugins] found Bounce channel after \(attempt + 1) DOWN presses\n", stderr)
                    smpMaster = found
                    break
                }
            }
        }

        // Phase B: arrow UP 50 steps (if not found going down)
        if smpMaster == nil {
            fputs("[scanMasterPlugins] not found going down, trying arrow-up…\n", stderr)
            for attempt in 0..<50 {
                if let ev = CGEvent(keyboardEventSource: src, virtualKey: 0x7E, keyDown: true),
                   let up = CGEvent(keyboardEventSource: src, virtualKey: 0x7E, keyDown: false) {
                    ev.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                }
                Thread.sleep(forTimeInterval: 0.25)
                if let found = findInspectorMaster(logic) {
                    fputs("[scanMasterPlugins] found Bounce channel after \(attempt + 1) UP presses\n", stderr)
                    smpMaster = found
                    break
                }
            }
        }
    }

    // 3. Fallback: try direct Mixer search if Inspector didn't find MASTER
    if smpMaster == nil {
        fputs("[scanMasterPlugins] Inspector failed, trying Mixer direct…\n", stderr)
        if let mixerChannel = findStereoOutInMixer(logic) {
            AXUIElementPerformAction(mixerChannel, "AXScrollToVisible" as CFString)
            Thread.sleep(forTimeInterval: 0.2)
            AXUIElementSetAttributeValue(mixerChannel, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.6)
            let mixerPlugins = pluginsFromMasterItem(mixerChannel)
            if !mixerPlugins.isEmpty {
                fputs("[scanMasterPlugins] found via Mixer direct\n", stderr)
                jsonOut(["ok": true, "plugins": mixerPlugins, "channel": "Stereo Out", "source": "mixer"])
                break
            }
            smpMaster = findInspectorMaster(logic)
        }
    }

    // Show EasyBounce back
    let showEB = Process()
    showEB.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    showEB.arguments = ["-e", "tell application \"System Events\" to set visible of process \"EasyBounce\" to true"]
    showEB.standardOutput = Pipe(); showEB.standardError = Pipe()
    try? showEB.run(); showEB.waitUntilExit()

    guard let masterItem = smpMaster else {
        jsonOut(["ok": false, "error": "Master plugins not found — Stereo Output channel with Bnc button not detected"]); break
    }

    // 4. Read plugins from MASTER in Inspector
    let smpPlugins = pluginsFromMasterItem(masterItem)

    if smpPlugins.isEmpty {
        jsonOut(["ok": false, "error": "No plugins found on Stereo Output"])
    } else {
        jsonOut(["ok": true, "plugins": smpPlugins, "channel": "Stereo Out", "source": "inspector"])
    }

case "masterPlugins":
    // Returns list of plugins on Stereo Out / MASTER channel — Mixer direct (reliable)
    if let mpChannel = findStereoOutInMixer(logic) {
        AXUIElementPerformAction(mpChannel, "AXScrollToVisible" as CFString)
        Thread.sleep(forTimeInterval: 0.2)
        AXUIElementSetAttributeValue(mpChannel, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.6)
        let mpList = pluginsFromMasterItem(mpChannel)
        jsonOut(["ok": true, "plugins": mpList, "channel": "Stereo Out", "source": "mixer"])
    } else {
        jsonOut(["ok": false, "error": "Stereo Out not found in Mixer"])
    }

case "masterPluginsQuick":
    // Quick poll — bounce button = unique to Output channel, fastest reliable lookup
    if let mqChannel = findStereoOutByBounce(logic) ?? findStereoOutInMixer(logic) {
        let mqPlugins = pluginsFromMasterItem(mqChannel)
        jsonOut(["ok": true, "plugins": mqPlugins])
    } else {
        jsonOut(["ok": false, "error": "Stereo Out not found"])
    }

case "setMasterPlugin":
    // Toggle bypass on a plugin on Stereo Out / MASTER channel
    // Usage: setMasterPlugin <nameOrIndex> <0|1>  (1=active, 0=bypassed)
    guard args.count >= 4 else { jsonOut(["ok": false, "error": "Usage: setMasterPlugin <name> <0|1>"]); break }
    let smpName = args[2]; let smpActive = args[3] == "1"
    guard let smpChannel = findStereoOutByBounce(logic) ?? findStereoOutInMixer(logic) else {
        jsonOut(["ok": false, "error": "Stereo Out not found in Mixer"]); break
    }
    // Get plugin groups sorted by Y position (same order as pluginsFromMasterItem / UI display)
    let smpGroups = axKids(smpChannel).filter { kid -> Bool in
        guard axRole(kid) == "AXGroup" else { return false }
        let name = axVal(kid, kAXDescriptionAttribute) as? String ?? ""
        guard !name.isEmpty else { return false }
        return axKids(kid).contains { axRole($0) == "AXCheckBox" && (axVal($0, kAXDescriptionAttribute) as? String ?? "") == "bypass" }
    }.sorted {
        var p1: CFTypeRef?; AXUIElementCopyAttributeValue($0, kAXPositionAttribute as CFString, &p1)
        var p2: CFTypeRef?; AXUIElementCopyAttributeValue($1, kAXPositionAttribute as CFString, &p2)
        var pt1 = CGPoint.zero; var pt2 = CGPoint.zero
        if let av = p1 { AXValueGetValue(av as! AXValue, .cgPoint, &pt1) }
        if let av = p2 { AXValueGetValue(av as! AXValue, .cgPoint, &pt2) }
        return pt1.y < pt2.y
    }
    // Try index first (e.g. "3"), then name matching
    var smpTarget: AXUIElement? = nil
    if let idx = Int(smpName), idx >= 0, idx < smpGroups.count {
        smpTarget = smpGroups[idx]
    } else {
        smpTarget = smpGroups.first(where: {
            let desc = axVal($0, kAXDescriptionAttribute) as? String ?? ""
            return desc.lowercased().hasPrefix(smpName.lowercased().prefix(10))
                || smpName.lowercased().hasPrefix(desc.lowercased().prefix(10))
        })
    }
    guard let smpGroup = smpTarget,
          let smpBypass = axKids(smpGroup).first(where: {
              axRole($0) == "AXCheckBox" && (axVal($0, kAXDescriptionAttribute) as? String ?? "") == "bypass"
          }) else {
        jsonOut(["ok": false, "error": "Plugin '\(smpName)' not found (total: \(smpGroups.count))"]); break
    }
    let currentVal = axIntValue(smpBypass)
    let wantVal = smpActive ? 0 : 1
    if currentVal != wantVal { axPress(smpBypass); Thread.sleep(forTimeInterval: 0.15) }
    let newVal = axIntValue(smpBypass)
    jsonOut(["ok": true, "plugin": smpName, "active": newVal == 0, "changed": currentVal != newVal])

case "setAllMasterPlugins":
    // Bypass or restore ALL plugins on Stereo Out / MASTER channel — Mixer direct
    guard args.count >= 3 else { jsonOut(["ok": false, "error": "Usage: setAllMasterPlugins <0|1>"]); break }
    let samAllActive = args[2] == "1"
    guard let samChannel = findStereoOutByBounce(logic) ?? findStereoOutInMixer(logic) else {
        jsonOut(["ok": false, "error": "Stereo Out not found in Mixer"]); break
    }
    let samGroups = axKids(samChannel).filter { kid -> Bool in
        guard axRole(kid) == "AXGroup" else { return false }
        return axKids(kid).contains { axRole($0) == "AXCheckBox" && (axVal($0, kAXDescriptionAttribute) as? String ?? "") == "bypass" }
    }
    var samToggled = 0
    for g in samGroups {
        guard let bypassEl = axKids(g).first(where: {
            axRole($0) == "AXCheckBox" && (axVal($0, kAXDescriptionAttribute) as? String ?? "") == "bypass"
        }) else { continue }
        let val = axIntValue(bypassEl)
        let wantVal = samAllActive ? 0 : 1
        if val != wantVal { axPress(bypassEl); samToggled += 1 }
    }
    jsonOut(["ok": true, "toggled": samToggled, "active": samAllActive])

case "debugScanMaster":
    // Step-by-step diagnostic for scanMasterPlugins
    var diag: [String: Any] = [:]
    guard let dbgWins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement] else {
        jsonOut(["error": "no windows"]); break
    }
    diag["windowCount"] = dbgWins.count
    diag["windowTitles"] = dbgWins.compactMap { axVal($0, kAXTitleAttribute) as? String }
    guard let dbgWin = dbgWins.first(where: {
        let t = axVal($0, kAXTitleAttribute) as? String ?? ""
        return t.contains("Tracks") || t.contains("Logic")
    }) ?? dbgWins.first else { jsonOut(["diag": diag, "error": "no main window"]); break }
    let dbgWinTitle = axVal(dbgWin, kAXTitleAttribute) as? String ?? "?"
    diag["mainWindow"] = dbgWinTitle
    // Inspector checkbox
    let dbgInspCB = findCheckboxByLabel(dbgWin, label: "Inspector")
    diag["inspectorCBFound"] = dbgInspCB != nil
    if let cb = dbgInspCB { diag["inspectorIsOpen"] = axIntValue(cb) == 1 }
    // First track click
    let dbgClicked = clickFirstArrangeTrack(logic)
    diag["clickedFirstTrack"] = dbgClicked
    if dbgClicked { Thread.sleep(forTimeInterval: 0.5) }
    // Find Inspector group in AX tree
    func dbgFindInspGroup(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 6 { return nil }
        if axRole(el) == "AXGroup" && (axVal(el, kAXDescriptionAttribute) as? String ?? "") == "Inspector" { return el }
        for child in axKids(el) { if let f = dbgFindInspGroup(child, depth: depth+1) { return f } }
        return nil
    }
    let dbgInspGroup = dbgFindInspGroup(dbgWin)
    diag["inspectorGroupFound"] = dbgInspGroup != nil
    if let ig = dbgInspGroup {
        // Walk to find AXLayoutArea with Mixer
        var layoutAreas: [String] = []
        var layoutItems: [String] = []
        func dbgWalk(_ el: AXUIElement, d: Int = 0) {
            if d > 8 { return }
            let role = axRole(el)
            let desc = axVal(el, kAXDescriptionAttribute) as? String ?? ""
            if role == "AXLayoutArea" { layoutAreas.append(desc.isEmpty ? "(no desc)" : desc) }
            if role == "AXLayoutItem" { layoutItems.append(desc.isEmpty ? "(no desc)" : desc) }
            for child in axKids(el) { dbgWalk(child, d: d+1) }
        }
        dbgWalk(ig)
        diag["layoutAreas"] = layoutAreas
        diag["layoutItems"] = layoutItems
    }
    // Try findInspectorMaster
    let dbgMaster = findInspectorMaster(logic)
    diag["masterItemFound"] = dbgMaster != nil
    if let m = dbgMaster {
        let plugins = pluginsFromMasterItem(m)
        diag["pluginCount"] = plugins.count
        diag["plugins"] = plugins.map { $0["name"] as? String ?? "?" }
    }
    jsonOut(["ok": true, "diag": diag])

case "dumpMixer":
    // Find Mixer AXGroup and dump all children with role/title/desc
    guard let wins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement],
          let win = wins.first else { jsonOut(["error": "no window"]); break }
    func dmFindMixer(_ el: AXUIElement, _ d: Int) -> AXUIElement? {
        if d > 4 { return nil }
        if axRole(el) == "AXGroup" && (axVal(el, kAXDescriptionAttribute) as? String) == "Mixer" { return el }
        for kid in axKids(el) { if let f = dmFindMixer(kid, d+1) { return f } }
        return nil
    }
    guard let mixer = dmFindMixer(win, 0) else { jsonOut(["error": "mixer not found"]); break }
    func dmDump(_ el: AXUIElement, _ depth: Int) -> [[String: String]] {
        if depth > 4 { return [] }
        let role = axRole(el)
        let title = (axVal(el, kAXTitleAttribute) as? String) ?? ""
        let desc  = (axVal(el, kAXDescriptionAttribute) as? String) ?? ""
        let val   = (axVal(el, kAXValueAttribute) as? String) ?? ""
        var entry: [String: String] = ["role": role, "depth": "\(depth)"]
        if !title.isEmpty { entry["title"] = title }
        if !desc.isEmpty  { entry["desc"]  = desc  }
        if !val.isEmpty   { entry["val"]   = val   }
        var results = [entry]
        for kid in axKids(el) { results += dmDump(kid, depth + 1) }
        return results
    }
    jsonOut(["ok": true, "elements": dmDump(mixer, 0)])

case "dumpMixer":
    guard let wins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement],
          let win = wins.first else { jsonOut(["error": "no window"]); break }
    func dmFindMixer(_ el: AXUIElement, _ d: Int) -> AXUIElement? {
        if d > 4 { return nil }
        if axRole(el) == "AXGroup" && (axVal(el, kAXDescriptionAttribute) as? String) == "Mixer" { return el }
        for kid in axKids(el) { if let f = dmFindMixer(kid, d+1) { return f } }
        return nil
    }
    guard let mixer = dmFindMixer(win, 0) else { jsonOut(["error": "mixer not found"]); break }
    func dmDump(_ el: AXUIElement, _ depth: Int) -> [[String: String]] {
        if depth > 4 { return [] }
        let role = axRole(el)
        let title = (axVal(el, kAXTitleAttribute) as? String) ?? ""
        let desc  = (axVal(el, kAXDescriptionAttribute) as? String) ?? ""
        let val   = (axVal(el, kAXValueAttribute) as? String) ?? ""
        var entry: [String: String] = ["role": role, "depth": "\(depth)"]
        if !title.isEmpty { entry["title"] = title }
        if !desc.isEmpty  { entry["desc"]  = desc  }
        if !val.isEmpty   { entry["val"]   = val   }
        var results = [entry]
        for kid in axKids(el) { results += dmDump(kid, depth + 1) }
        return results
    }
    jsonOut(["ok": true, "elements": dmDump(mixer, 0)])

case "testSetInspectorWidth":
    // Test if AX API allows setting inspector width directly (no mouse drag)
    // Usage: testSetInspectorWidth <width>
    let targetPx = args.count >= 3 ? (CGFloat(Double(args[2]) ?? 160)) : 160
    guard let twWins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement],
          let twWin = twWins.first(where: { (axVal($0, kAXTitleAttribute) as? String ?? "").contains("Tracks") }) ?? twWins.first
    else { jsonOut(["ok": false, "error": "no window"]); break }
    func findInspGrp(_ el: AXUIElement, _ d: Int = 0) -> AXUIElement? {
        if d > 6 { return nil }
        if axRole(el) == "AXGroup" && (axVal(el, kAXDescriptionAttribute) as? String ?? "") == "Inspector" { return el }
        for c in axKids(el) { if let f = findInspGrp(c, d+1) { return f } }
        return nil
    }
    guard let insp = findInspGrp(twWin) else { jsonOut(["ok": false, "error": "inspector not found"]); break }
    // Read current size
    var curSzRef: CFTypeRef?
    AXUIElementCopyAttributeValue(insp, kAXSizeAttribute as CFString, &curSzRef)
    var curSz = CGSize.zero
    if let v = curSzRef { AXValueGetValue(v as! AXValue, .cgSize, &curSz) }
    // Try setting new width via AX
    var newSz = CGSize(width: targetPx, height: curSz.height)
    let axVal2 = AXValueCreate(.cgSize, &newSz)!
    let err = AXUIElementSetAttributeValue(insp, kAXSizeAttribute as CFString, axVal2)
    // Read back result
    var afterRef: CFTypeRef?
    AXUIElementCopyAttributeValue(insp, kAXSizeAttribute as CFString, &afterRef)
    var afterSz = CGSize.zero
    if let v = afterRef { AXValueGetValue(v as! AXValue, .cgSize, &afterSz) }
    jsonOut(["ok": true, "before": Int(curSz.width), "target": Int(targetPx),
             "after": Int(afterSz.width), "axError": Int(err.rawValue),
             "axWritable": err == .success])

case "dumpTrackAX":
    // Diagnostic: dump AX tree of first few track items in "Tracks header"
    // Shows role, description, children for each — to debug missing AXDisclosureTriangle on Intel
    guard let dtWins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement],
          let dtWin = dtWins.first else { jsonOut(["error": "no window"]); break }
    func dtFindHeader(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
        if depth > 8 { return nil }
        if axRole(el) == "AXScrollArea" {
            for kid in axKids(el) {
                if (axVal(kid, kAXDescriptionAttribute) as? String) == "Tracks header" { return kid }
            }
        }
        for kid in axKids(el) { if let r = dtFindHeader(kid, depth + 1) { return r } }
        return nil
    }
    guard let dtHeader = dtFindHeader(dtWin, 0) else { jsonOut(["error": "Tracks header not found"]); break }
    var dtItems: [[String: Any]] = []
    let dtKids = axKids(dtHeader)
    fputs("[dumpTrackAX] header has \(dtKids.count) children\n", stderr)
    for (i, item) in dtKids.prefix(8).enumerated() {
        let role = axRole(item)
        let desc = (axVal(item, kAXDescriptionAttribute) as? String) ?? ""
        let title = (axVal(item, kAXTitleAttribute) as? String) ?? ""
        var children: [[String: String]] = []
        for kid in axKids(item) {
            let kr = axRole(kid)
            let kd = (axVal(kid, kAXDescriptionAttribute) as? String) ?? ""
            let kt = (axVal(kid, kAXTitleAttribute) as? String) ?? ""
            var grandchildren: [[String: String]] = []
            for gk in axKids(kid) {
                grandchildren.append([
                    "role": axRole(gk),
                    "desc": (axVal(gk, kAXDescriptionAttribute) as? String) ?? "",
                    "title": (axVal(gk, kAXTitleAttribute) as? String) ?? ""
                ])
            }
            var childInfo: [String: String] = ["role": kr, "desc": kd, "title": kt]
            if !grandchildren.isEmpty {
                childInfo["grandchildren"] = grandchildren.map { "\($0["role"]!)(\($0["desc"]!))" }.joined(separator: ", ")
            }
            children.append(childInfo)
        }
        dtItems.append([
            "index": i, "role": role, "desc": desc, "title": title,
            "childCount": axKids(item).count,
            "children": children
        ])
    }
    jsonOut(["ok": true, "headerChildCount": dtKids.count, "items": dtItems])

// ─────────────────────────────────────────────
// dump-transport: Find cycle locator fields in Logic transport bar
// ─────────────────────────────────────────────
case "dump-transport":
    guard let wins = axVal(logic, kAXWindowsAttribute) as? [AXUIElement] else {
        jsonOut(["ok": false, "error": "no windows"]); break
    }
    // Find main Tracks/Arrange window
    let mainWin = wins.first(where: { (axVal($0, kAXTitleAttribute) as? String ?? "").contains("Tracks") })
                  ?? wins.first(where: { !(axVal($0, kAXTitleAttribute) as? String ?? "").contains("Marker List") })
                  ?? wins.first!

    // Recursive dump — look for anything that contains "Locator" or "Cycle" or position-like values
    func dtDump(_ el: AXUIElement, _ depth: Int, _ path: String) -> [[String: Any]] {
        if depth > 8 { return [] }
        let role  = axRole(el)
        let title = (axVal(el, kAXDescriptionAttribute) as? String) ?? (axVal(el, kAXTitleAttribute) as? String) ?? ""
        let val   = (axVal(el, kAXValueAttribute) as? String) ?? ""
        var settable = false
        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &isSettable)
        settable = isSettable.boolValue

        var results: [[String: Any]] = []
        let interesting = title.lowercased().contains("locator") || title.lowercased().contains("cycle")
            || title.lowercased().contains("left") || title.lowercased().contains("right")
            || val.contains(" 1 1") || val.contains("bar") || role == "AXTextField"
        if interesting || depth <= 3 {
            results.append(["depth": depth, "role": role, "title": title, "val": val,
                            "settable": settable, "path": path])
        }
        for (i, kid) in axKids(el).enumerated() {
            results += dtDump(kid, depth+1, "\(path).\(i)")
        }
        return results
    }
    jsonOut(["ok": true, "elements": dtDump(mainWin, 0, "root")])

// ─────────────────────────────────────────────
// scan-markers: Read all markers from Marker List window
// Returns JSON: { ok: true, markers: [{name, position, length}] }
// ─────────────────────────────────────────────
case "scan-markers":
    // Open Navigate menu → Marker List to ensure window is open
    func openMarkerList(_ app: AXUIElement) {
        guard let menuBarRaw = axVal(app, kAXMenuBarAttribute) else { return }
        let menuBar = menuBarRaw as! AXUIElement
        for menu in axKids(menuBar) {
            let title = (axVal(menu, kAXTitleAttribute) as? String) ?? ""
            if title == "Navigate" {
                axPress(menu)
                Thread.sleep(forTimeInterval: 0.2)
                let items = findAll(menu, role: "AXMenuItem", depth: 5)
                for item in items {
                    let t = (axVal(item, kAXTitleAttribute) as? String) ?? ""
                    if t.contains("Marker List") {
                        axPress(item)
                        // Poll for window (max 800ms) instead of fixed sleep
                        for _ in 0..<8 {
                            Thread.sleep(forTimeInterval: 0.1)
                            if let wins = axVal(app, kAXWindowsAttribute) as? [AXUIElement],
                               wins.contains(where: { (axVal($0, kAXTitleAttribute) as? String ?? "").contains("Marker List") }) { break }
                        }
                        return
                    }
                }
                // Close menu if Marker List item not found
                let src2 = CGEventSource(stateID: .hidSystemState)
                if let dn = CGEvent(keyboardEventSource: src2, virtualKey: 53, keyDown: true),
                   let up = CGEvent(keyboardEventSource: src2, virtualKey: 53, keyDown: false) {
                    dn.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                }
                break
            }
        }
    }

    // Find Marker List window (title contains "Marker List")
    func findMarkerListWindow(_ app: AXUIElement) -> AXUIElement? {
        guard let wins = axVal(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for w in wins {
            let t = (axVal(w, kAXTitleAttribute) as? String) ?? ""
            if t.contains("Marker List") { return w }
        }
        return nil
    }

    // Try to find window; if not found, open it (and remember we opened it)
    var mlWin = findMarkerListWindow(logic)
    let weOpenedMarkerList = mlWin == nil
    if mlWin == nil {
        openMarkerList(logic)
        mlWin = findMarkerListWindow(logic)
    }

    guard let markerWin = mlWin else {
        jsonOut(["ok": false, "error": "no-marker-list"])
        break
    }

    // Find AXTable in the window
    func findTable(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 8 { return nil }
        if axRole(el) == "AXTable" { return el }
        for kid in axKids(el) { if let f = findTable(kid, depth: depth+1) { return f } }
        return nil
    }

    guard let table = findTable(markerWin, depth: 0) else {
        jsonOut(["ok": false, "error": "No table found in Marker List window"])
        break
    }

    // Expand the window height so ALL marker rows become visible in the AX tree.
    // Logic only renders AX rows for on-screen rows; a small window hides scrolled-off ones.
    var mlOrigSizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(markerWin, kAXSizeAttribute as CFString, &mlOrigSizeRef)
    var mlOrigSize = CGSize(width: 560, height: 320) // fallback
    if let sv = mlOrigSizeRef { AXValueGetValue(sv as! AXValue, .cgSize, &mlOrigSize) }
    var mlBigSize = CGSize(width: max(mlOrigSize.width, 500), height: 1400)
    if let sizeAX = AXValueCreate(.cgSize, &mlBigSize) {
        AXUIElementSetAttributeValue(markerWin, kAXSizeAttribute as CFString, sizeAX)
        Thread.sleep(forTimeInterval: 0.25) // let Logic re-render rows
    }

    // Wait for Logic to populate all marker rows (poll until stable, max 1.5s)
    var prevCount = -1
    for _ in 0..<15 {
        let count = axKids(table).filter { axRole($0) == "AXRow" }.count
        if count > 0 && count == prevCount { break }
        prevCount = count
        Thread.sleep(forTimeInterval: 0.1)
    }

    let rows = axKids(table).filter { axRole($0) == "AXRow" }
    fputs("[scan-markers] found \(rows.count) rows\n", stderr)

    var markers: [[String: String]] = []
    for (i, row) in rows.enumerated() {
        let cells = axKids(row)
        guard cells.count >= 3 else { continue }

        // cell[1]: position — child is AXGroup with description like "9 1 1 1"
        var position = ""
        let cell1Kids = axKids(cells[1])
        if let posEl = cell1Kids.first {
            position = (axVal(posEl, kAXDescriptionAttribute) as? String) ?? ""
        }

        // cell[2]: name — child is AXCell with description = marker name
        var name = ""
        let cell2Kids = axKids(cells[2])
        if let nameEl = cell2Kids.first {
            name = (axVal(nameEl, kAXDescriptionAttribute) as? String) ?? ""
            // Fallback: try value
            if name.isEmpty { name = (axVal(nameEl, kAXValueAttribute) as? String) ?? "" }
        }
        // Also try description directly on cell[2]
        if name.isEmpty { name = (axVal(cells[2], kAXDescriptionAttribute) as? String) ?? "" }

        // cell[3]: length — child is AXGroup with description like "4 0 0 0"
        var length = ""
        if cells.count >= 4 {
            let cell3Kids = axKids(cells[3])
            if let lenEl = cell3Kids.first {
                length = (axVal(lenEl, kAXDescriptionAttribute) as? String) ?? ""
            }
        }

        fputs("[scan-markers] row \(i): name='\(name)' pos='\(position)' len='\(length)'\n", stderr)
        if !name.isEmpty {
            markers.append(["name": name, "position": position, "length": length, "index": "\(i)"])
        }
    }

    // Restore original window size
    if var restoreSize = Optional(mlOrigSize), let sizeAX2 = AXValueCreate(.cgSize, &restoreSize) {
        AXUIElementSetAttributeValue(markerWin, kAXSizeAttribute as CFString, sizeAX2)
    }

    // Close Marker List if we opened it
    if weOpenedMarkerList {
        var closeBtnRef: CFTypeRef?
        AXUIElementCopyAttributeValue(markerWin, kAXCloseButtonAttribute as CFString, &closeBtnRef)
        if let ref = closeBtnRef {
            axPress(ref as! AXUIElement)
        } else {
            let src = CGEventSource(stateID: .hidSystemState)
            var logicPid: pid_t = 0; AXUIElementGetPid(markerWin, &logicPid)
            if let dn = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: false) {
                dn.flags = .maskCommand; up.flags = .maskCommand
                dn.postToPid(logicPid); up.postToPid(logicPid)
            }
        }
        Thread.sleep(forTimeInterval: 0.15)
    }

    jsonOut(["ok": true, "markers": markers])

// ─────────────────────────────────────────────
// set-locators-by-marker: Select a marker row and set cycle region
// Args: marker name (string) or index (int)
// Usage: LogicBridge set-locators-by-marker "60s"
// ─────────────────────────────────────────────
case "set-locators-by-marker":
    let markerTarget = args.count >= 3 ? args[2] : ""
    // Pass "keep-ml" in any arg position to prevent closing Marker List after
    let keepML = args.contains("keep-ml")
    guard !markerTarget.isEmpty else {
        jsonOut(["ok": false, "error": "Usage: set-locators-by-marker <markerName>"])
        break
    }

    // Find Marker List window
    func findMarkerListWin2(_ app: AXUIElement) -> AXUIElement? {
        guard let wins = axVal(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for w in wins {
            let t = (axVal(w, kAXTitleAttribute) as? String) ?? ""
            if t.contains("Marker List") { return w }
        }
        return nil
    }

    // Open if needed
    let weOpenedML2 = findMarkerListWin2(logic) == nil
    if weOpenedML2 {
        guard let menuBar2Raw = axVal(logic, kAXMenuBarAttribute) else {
            jsonOut(["ok": false, "error": "No menu bar"]); break
        }
        let menuBar2 = menuBar2Raw as! AXUIElement
        for menu in axKids(menuBar2) {
            let t = (axVal(menu, kAXTitleAttribute) as? String) ?? ""
            if t == "Navigate" {
                axPress(menu); Thread.sleep(forTimeInterval: 0.2)
                for item in findAll(menu, role: "AXMenuItem", depth: 5) {
                    let it = (axVal(item, kAXTitleAttribute) as? String) ?? ""
                    if it.contains("Marker List") { axPress(item); break }
                }
                break
            }
        }
        // Poll up to 1.5s for ML window to appear
        var mlPollWin: AXUIElement? = nil
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.1)
            if let w = findMarkerListWin2(logic) { mlPollWin = w; break }
        }
        if mlPollWin == nil {
            jsonOut(["ok": false, "error": "Marker List window not found"]); break
        }
    }

    guard let mlWin2 = findMarkerListWin2(logic) else {
        jsonOut(["ok": false, "error": "Marker List window not found"]); break
    }

    // Find table
    func findTable2(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 8 { return nil }
        if axRole(el) == "AXTable" { return el }
        for kid in axKids(el) { if let f = findTable2(kid, depth: depth+1) { return f } }
        return nil
    }

    guard let table2 = findTable2(mlWin2, depth: 0) else {
        jsonOut(["ok": false, "error": "No table in Marker List"]); break
    }

    // Expand window so all rows are visible in AX tree before searching/clicking
    var slbmOrigSizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(mlWin2, kAXSizeAttribute as CFString, &slbmOrigSizeRef)
    var slbmOrigSize = CGSize(width: 560, height: 320)
    if let sv = slbmOrigSizeRef { AXValueGetValue(sv as! AXValue, .cgSize, &slbmOrigSize) }
    var slbmBigSize = CGSize(width: max(slbmOrigSize.width, 500), height: 1400)
    if let sizeAX = AXValueCreate(.cgSize, &slbmBigSize) {
        AXUIElementSetAttributeValue(mlWin2, kAXSizeAttribute as CFString, sizeAX)
        Thread.sleep(forTimeInterval: 0.2)
    }

    let rows2 = axKids(table2).filter { axRole($0) == "AXRow" }

    // Find the row matching the target marker name or index
    var targetRow: AXUIElement? = nil
    let targetIndex = Int(markerTarget)

    for (i, row) in rows2.enumerated() {
        let cells = axKids(row)
        guard cells.count >= 3 else { continue }

        var name = ""
        let cell2Kids = axKids(cells[2])
        if let nameEl = cell2Kids.first {
            name = (axVal(nameEl, kAXDescriptionAttribute) as? String) ?? ""
            if name.isEmpty { name = (axVal(nameEl, kAXValueAttribute) as? String) ?? "" }
        }
        if name.isEmpty { name = (axVal(cells[2], kAXDescriptionAttribute) as? String) ?? "" }

        if let idx = targetIndex {
            if i == idx { targetRow = row; break }
        } else {
            if name == markerTarget { targetRow = row; break }
        }
    }

    guard let rowToClick = targetRow else {
        // Restore size before early exit
        if var restoreSize2 = Optional(slbmOrigSize), let sizeAX2 = AXValueCreate(.cgSize, &restoreSize2) {
            AXUIElementSetAttributeValue(mlWin2, kAXSizeAttribute as CFString, sizeAX2)
        }
        jsonOut(["ok": false, "error": "Marker '\(markerTarget)' not found"]); break
    }

    // Find main Tracks window (not Marker List / Mixer / Bounce)
    func slbmTracksWin(_ app: AXUIElement) -> AXUIElement? {
        guard let wins = axVal(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for w in wins {
            let t = (axVal(w, kAXTitleAttribute) as? String) ?? ""
            if t.isEmpty || t.contains("Marker List") || t.contains("Mixer") || t.contains("Bounce") { continue }
            return w
        }
        return nil
    }

    // Navigate to Global Tracks header (UI element 1 of splitter group 1 of splitter group 1 of group 2 of group 3)
    func slbmGTHeader(_ win: AXUIElement) -> AXUIElement? {
        let g3 = axKids(win).filter { axRole($0) == "AXGroup" }
        guard g3.count >= 3 else { return nil }
        let g2 = axKids(g3[2]).filter { axRole($0) == "AXGroup" }
        guard g2.count >= 2 else { return nil }
        let sg1 = axKids(g2[1]).filter { axRole($0) == "AXSplitGroup" }
        guard let sg = sg1.first else { return nil }
        let sg2 = axKids(sg).filter { axRole($0) == "AXSplitGroup" }
        guard let sg2el = sg2.first else { return nil }
        return axKids(sg2el).first
    }

    // Enable Marker Track via Track → Global Tracks → Marker Track (AX, no focus needed)
    func slbmEnableMarkerTrack(_ app: AXUIElement) {
        guard let mbRaw = axVal(app, kAXMenuBarAttribute) else { return }
        let mb = mbRaw as! AXUIElement
        func escapeMenu() {
            let src = CGEventSource(stateID: .hidSystemState)
            if let dn = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) {
                dn.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            }
        }
        for menu in axKids(mb) {
            guard (axVal(menu, kAXTitleAttribute) as? String) == "Track" else { continue }
            axPress(menu); Thread.sleep(forTimeInterval: 0.3)
            // Find Global Tracks submenu item
            var gti: AXUIElement? = nil
            for item in findAll(menu, role: "AXMenuItem", depth: 5) {
                if (axVal(item, kAXTitleAttribute) as? String) == "Global Tracks" { gti = item; break }
            }
            guard let gt = gti else { escapeMenu(); return }
            // Press Global Tracks to expand submenu (same as AppleScript "click menu item Global Tracks")
            axPress(gt); Thread.sleep(forTimeInterval: 0.35)
            // Get submenu as first AXMenu child of Global Tracks item
            var found = false
            let subMenus = axKids(gt).filter { axRole($0) == "AXMenu" }
            for sm in subMenus {
                for si in axKids(sm).filter({ axRole($0) == "AXMenuItem" }) {
                    if (axVal(si, kAXTitleAttribute) as? String ?? "").contains("Marker") {
                        axPress(si); Thread.sleep(forTimeInterval: 0.25)
                        fputs("[set-locators-by-marker] enabled Marker Track\n", stderr)
                        found = true; break
                    }
                }
                if found { break }
            }
            if !found {
                fputs("[set-locators-by-marker] WARNING: Marker Track not found — closing menu\n", stderr)
                escapeMenu()
            }
            break
        }
    }

    var hadGlobalTracks = false
    if let tw = slbmTracksWin(logic), let ue1 = slbmGTHeader(tw) {
        func markerPopupVisible() -> Bool {
            axKids(ue1).filter { axRole($0) == "AXPopUpButton" }
                .contains { (axVal($0, kAXDescriptionAttribute) as? String ?? "").contains("Marker") }
        }
        // Check Marker popup first — if visible, GT is already open with Marker
        if markerPopupVisible() {
            hadGlobalTracks = true
        } else {
            // GT might be hidden — check checkbox and show if needed
            let cb = axKids(ue1).filter { axRole($0) == "AXCheckBox" }
                .first { (axVal($0, kAXDescriptionAttribute) as? String ?? "").contains("Global Tracks") }
            let cbVal = cb.map { axIntValue($0) } ?? -1
            hadGlobalTracks = cbVal == 1
            if !hadGlobalTracks, let cb = cb {
                axPress(cb); Thread.sleep(forTimeInterval: 0.4)
            }
            // If Marker still not visible after showing GT — enable via Track menu
            if !markerPopupVisible() {
                fputs("[set-locators-by-marker] Marker missing — enabling via Track menu\n", stderr)
                slbmEnableMarkerTrack(logic); Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    // Raise ML window FIRST, then get positions (window may move on raise)
    var lpidML: pid_t = 0; AXUIElementGetPid(rowToClick, &lpidML)
    if let mlWin2raise = findMarkerListWin2(logic) {
        AXUIElementPerformAction(mlWin2raise, kAXRaiseAction as CFString)
    }
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first?
        .activate(options: .activateIgnoringOtherApps)
    Thread.sleep(forTimeInterval: 0.25)
    // Re-fetch table/rows after raise so positions are current
    var clickPt: CGPoint? = nil
    if let mlWin2b = findMarkerListWin2(logic) {
        func findTable2b(_ el: AXUIElement, _ d: Int) -> AXUIElement? {
            if d > 8 { return nil }
            if axRole(el) == "AXTable" { return el }
            for k in axKids(el) { if let f = findTable2b(k, d+1) { return f } }
            return nil
        }
        if let tbl = findTable2b(mlWin2b, 0) {
            let rows2b = axKids(tbl).filter { axRole($0) == "AXRow" }
            for (i, row) in rows2b.enumerated() {
                let cells = axKids(row)
                guard cells.count >= 3 else { continue }
                var name2 = ""
                if let nameEl = axKids(cells[2]).first {
                    name2 = (axVal(nameEl, kAXDescriptionAttribute) as? String) ?? ""
                    if name2.isEmpty { name2 = (axVal(nameEl, kAXValueAttribute) as? String) ?? "" }
                }
                if name2.isEmpty { name2 = (axVal(cells[2], kAXDescriptionAttribute) as? String) ?? "" }
                let matches = (targetIndex != nil) ? (i == targetIndex!) : (name2 == markerTarget)
                if matches {
                    // Get position from name cell (cells[2]) — most reliable
                    func cp(_ el: AXUIElement) -> CGPoint? {
                        var pRef: CFTypeRef?; var sRef: CFTypeRef?
                        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pRef)
                        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sRef)
                        guard let p = pRef, let s = sRef else { return nil }
                        var pt = CGPoint.zero; var sz = CGSize.zero
                        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
                        AXValueGetValue(s as! AXValue, .cgSize, &sz)
                        guard sz.width > 0 && sz.height > 0 else { return nil }
                        return CGPoint(x: pt.x + sz.width/2, y: pt.y + sz.height/2)
                    }
                    // Prefer name cell, then position cell, then row
                    for ci in [2, 1, 3] {
                        if ci < cells.count, let p = cp(cells[ci]) { clickPt = p; break }
                    }
                    if clickPt == nil { clickPt = cp(row) }
                    break
                }
            }
        }
    }
    fputs("[set-locators-by-marker] clickPt=\(String(describing: clickPt)), pid=\(lpidML)\n", stderr)
    // Click the marker row name cell via real HID event (cghidEventTap)
    // Save and restore mouse position so it's non-intrusive
    let hidSrc = CGEventSource(stateID: .hidSystemState)
    let savedMouse = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left)?.location ?? .zero
    var setLocatorsOk = false
    if let cp = clickPt {
        if let ev1 = CGEvent(mouseEventSource: hidSrc, mouseType: .leftMouseDown, mouseCursorPosition: cp, mouseButton: .left),
           let ev2 = CGEvent(mouseEventSource: hidSrc, mouseType: .leftMouseUp,   mouseCursorPosition: cp, mouseButton: .left) {
            ev1.post(tap: .cghidEventTap); ev2.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.2)
        // Navigate menu → "Set Locators by Selection and Enable Cycle"
        if let menuBar3Raw = axVal(logic, kAXMenuBarAttribute) {
            let menuBar3 = menuBar3Raw as! AXUIElement
            for menu in axKids(menuBar3) {
                let t = (axVal(menu, kAXTitleAttribute) as? String) ?? ""
                if t == "Navigate" {
                    axPress(menu); Thread.sleep(forTimeInterval: 0.2)
                    for item in findAll(menu, role: "AXMenuItem", depth: 5) {
                        let it = (axVal(item, kAXTitleAttribute) as? String) ?? ""
                        if it.contains("Set Locators by Selection") && !it.contains("Rounded") {
                            axPress(item); Thread.sleep(forTimeInterval: 0.2)
                            setLocatorsOk = true; break
                        }
                    }
                    if !setLocatorsOk {
                        let src3 = CGEventSource(stateID: .hidSystemState)
                        if let dn = CGEvent(keyboardEventSource: src3, virtualKey: 53, keyDown: true),
                           let up = CGEvent(keyboardEventSource: src3, virtualKey: 53, keyDown: false) {
                            dn.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                        }
                    }
                    break
                }
            }
        }
        // Restore mouse position
        if let mv = CGEvent(mouseEventSource: hidSrc, mouseType: .mouseMoved, mouseCursorPosition: savedMouse, mouseButton: .left) {
            mv.post(tap: .cghidEventTap)
        }
    }

    // Hide Global Tracks again if we showed them
    if !hadGlobalTracks && setLocatorsOk {
        if let tw = slbmTracksWin(logic), let ue1 = slbmGTHeader(tw),
           let cb = axKids(ue1).filter({ axRole($0) == "AXCheckBox" })
               .first(where: { (axVal($0, kAXDescriptionAttribute) as? String ?? "").contains("Global Tracks") }) {
            axPress(cb); Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // Restore Marker List window to original size (if it's still open)
    if !weOpenedML2 || keepML {
        if let mlWin2c = findMarkerListWin2(logic),
           var restoreSize3 = Optional(slbmOrigSize),
           let sizeAX3 = AXValueCreate(.cgSize, &restoreSize3) {
            AXUIElementSetAttributeValue(mlWin2c, kAXSizeAttribute as CFString, sizeAX3)
        }
    }

    // Close Marker List if we opened it (and keepML not requested)
    if weOpenedML2 && !keepML {
        if let mlWin2b = findMarkerListWin2(logic) {
            var closeBtnRef2: CFTypeRef?
            AXUIElementCopyAttributeValue(mlWin2b, kAXCloseButtonAttribute as CFString, &closeBtnRef2)
            if let ref = closeBtnRef2 {
                axPress(ref as! AXUIElement)
            } else {
                let src = CGEventSource(stateID: .hidSystemState)
                var lpid: pid_t = 0; AXUIElementGetPid(mlWin2b, &lpid)
                if let dn = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: true),
                   let up = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: false) {
                    dn.flags = .maskCommand; up.flags = .maskCommand
                    dn.postToPid(lpid); up.postToPid(lpid)
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    // Raise main Logic Arrange window and restore OS-level focus so Bounce works
    // Also do a real HID click on the Tracks window toolbar to steal focus from Marker List
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first?
        .activate(options: .activateIgnoringOtherApps)
    Thread.sleep(forTimeInterval: 0.1)
    if let tw = slbmTracksWin(logic) {
        AXUIElementSetAttributeValue(logic, kAXFocusedWindowAttribute as CFString, tw as CFTypeRef)
        AXUIElementPerformAction(tw, kAXRaiseAction as CFString)
        Thread.sleep(forTimeInterval: 0.1)
        // Click on the toolbar area of the Tracks window to give it real OS focus
        var twPosRef: CFTypeRef?; var twSzRef: CFTypeRef?
        AXUIElementCopyAttributeValue(tw, kAXPositionAttribute as CFString, &twPosRef)
        AXUIElementCopyAttributeValue(tw, kAXSizeAttribute as CFString, &twSzRef)
        if let p = twPosRef, let s = twSzRef {
            var twPt = CGPoint.zero; var twSz = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &twPt)
            AXValueGetValue(s as! AXValue, .cgSize, &twSz)
            // Click at top-center of window (toolbar area) — safe, doesn't change tracks
            let safeClick = CGPoint(x: twPt.x + twSz.width / 2, y: twPt.y + 20)
            let twHidSrc = CGEventSource(stateID: .hidSystemState)
            if let e1 = CGEvent(mouseEventSource: twHidSrc, mouseType: .leftMouseDown, mouseCursorPosition: safeClick, mouseButton: .left),
               let e2 = CGEvent(mouseEventSource: twHidSrc, mouseType: .leftMouseUp,   mouseCursorPosition: safeClick, mouseButton: .left) {
                e1.post(tap: .cghidEventTap); e2.post(tap: .cghidEventTap)
            }
        }
    }
    Thread.sleep(forTimeInterval: 0.25)

    jsonOut(["ok": setLocatorsOk, "marker": markerTarget])

default:
    fputs("Unknown: \(cmd)\n", stderr); exit(1)
}

func setPopupValue(_ win: AXUIElement, currentValue: String, newValue: String) -> Bool {
    // Find popup with current value and click it, then select new value
    let allEls = findAll(win, role: "AXPopUpButton", depth: 10)
    for popup in allEls {
        var val: CFTypeRef?
        AXUIElementCopyAttributeValue(popup, kAXValueAttribute as CFString, &val)
        if let v = val as? String, v == currentValue {
            axPress(popup)
            Thread.sleep(forTimeInterval: 0.3)
            // Find menu item with new value
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(popup, kAXChildrenAttribute as CFString, &kids)
            if let menu = (kids as? [AXUIElement])?.first {
                let items = findAll(menu, role: "AXMenuItem", title: newValue, depth: 3)
                if let item = items.first {
                    axPress(item)
                    return true
                }
                // Try by value
                for item in findAll(menu, role: "AXMenuItem", depth: 3) {
                    var tv: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &tv)
                    if let t = tv as? String, t == newValue {
                        axPress(item)
                        return true
                    }
                }
            }
            // Press Escape to close if not found
            let src = CGEventSource(stateID: .hidSystemState)
            if let dn = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) {
                var pid: pid_t = 0
                AXUIElementGetPid(popup, &pid)
                dn.postToPid(pid); up.postToPid(pid)
            }
        }
    }
    return false
}
