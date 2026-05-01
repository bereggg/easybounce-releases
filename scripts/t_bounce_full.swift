// Повний bounce flow: folder creation + navigation + naming + bounce
// Використання: /tmp/t_bounce_full <trackName> <outputFolder> <projectName> [template]
// Приклад:      /tmp/t_bounce_full "Kick" "/Users/dbsound/Desktop" "MyProject" "v1"
// Результат:    /Users/dbsound/Desktop/MyProject/STEMS/v1_Kick.wav
import AppKit
import CoreGraphics

// ── CGS private API ──
typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ c: CGSConnectionID) -> CFArray?
typealias CGSCopySpacesForWindowsFn          = @convention(c) (CGSConnectionID, Int32, CFArray) -> CFArray?
typealias CGSManagedDisplaySetCurrentSpaceFn = @convention(c) (CGSConnectionID, CFString, Int) -> Void
let cgLib = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
let CGSCopySpacesForWindows          = unsafeBitCast(dlsym(cgLib, "CGSCopySpacesForWindows"), to: CGSCopySpacesForWindowsFn.self)
let CGSManagedDisplaySetCurrentSpace = unsafeBitCast(dlsym(cgLib, "CGSManagedDisplaySetCurrentSpace"), to: CGSManagedDisplaySetCurrentSpaceFn.self)

// ── AX helpers ──
func axVal(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v
}
func axKids(_ e: AXUIElement) -> [AXUIElement] { (axVal(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axRole(_ e: AXUIElement) -> String { (axVal(e, kAXRoleAttribute) as? String) ?? "" }
func axTit(_ e: AXUIElement)  -> String { (axVal(e, kAXTitleAttribute) as? String) ?? "" }
func axActs(_ e: AXUIElement) -> [String] {
    var n: CFArray?; AXUIElementCopyActionNames(e, &n); return (n as? [String]) ?? []
}
func moveToCorner(_ e: AXUIElement, aggressive: Bool = false) {
    var sizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sizeRef)
    var size = CGSize(width: 800, height: 500)
    if let sv = sizeRef { AXValueGetValue(sv as! AXValue, .cgSize, &size) }
    let screenH = NSScreen.main?.frame.height ?? 900.0
    let visible: CGFloat = aggressive ? 5 : 30
    var p = CGPoint(x: -(size.width - visible), y: screenH - visible)
    if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v) }
}
func findBtn(_ e: AXUIElement, _ name: String, d: Int = 0) -> AXUIElement? {
    if d > 8 { return nil }
    if axRole(e) == "AXButton" && axTit(e) == name { return e }
    for k in axKids(e) { if let f = findBtn(k, name, d: d+1) { return f } }
    return nil
}
func hasBtnWithTitle(_ e: AXUIElement, _ name: String, d: Int = 0) -> Bool {
    if d > 6 { return false }
    if axRole(e) == "AXButton" && axTit(e) == name { return true }
    return axKids(e).contains { hasBtnWithTitle($0, name, d: d+1) }
}

// ── Fullscreen detection ──
func isCurrentSpaceFullscreen() -> Bool {
    let cid = CGSMainConnectionID()
    guard let raw = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return false }
    for display in raw {
        if let current = display["Current Space"] as? [String: Any],
           let type = current["type"] as? Int { return type == 4 }
    }
    return false
}

// ── CGS switch + activate ──
func switchToLogicSpace(logicPID: pid_t) -> Bool {
    let cid = CGSMainConnectionID()
    let wins = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]])
        .compactMap { w -> Int? in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == logicPID else { return nil }
            return w[kCGWindowNumber as String] as? Int
        }
    guard !wins.isEmpty,
          let spaces = CGSCopySpacesForWindows(cid, 7, wins as CFArray) as? [Int],
          let sid = spaces.first,
          let raw = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]],
          let uuid = raw.first?["Display Identifier"] as? String else { return false }
    CGSManagedDisplaySetCurrentSpace(cid, uuid as CFString, sid)
    Thread.sleep(forTimeInterval: 0.15)
    if let s = NSAppleScript(source: "tell application id \"com.apple.logic10\" to activate") {
        var e: NSDictionary?; s.executeAndReturnError(&e)
    }
    let dl = Date().addingTimeInterval(3.0)
    while Date() < dl {
        Thread.sleep(forTimeInterval: 0.05)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.logic10" { return true }
    }
    return false
}

// ── postToPid helpers ──
func postKey(_ vk: CGKeyCode, flags: CGEventFlags = [], pid: pid_t) {
    let src = CGEventSource(stateID: .hidSystemState)
    if let dn = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true),
       let up = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false) {
        dn.flags = flags; up.flags = flags
        dn.postToPid(pid); Thread.sleep(forTimeInterval: 0.04); up.postToPid(pid)
    }
}

func postText(_ text: String, pid: pid_t) {
    for ch in text.utf16 {
        let src = CGEventSource(stateID: .hidSystemState)
        if let dn = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
            dn.keyboardSetUnicodeString(stringLength: 1, unicodeString: [ch])
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: [ch])
            dn.postToPid(pid); Thread.sleep(forTimeInterval: 0.018); up.postToPid(pid)
        }
    }
}

// ── AppleScript helper ──
@discardableResult
func runAS(_ src: String) -> String {
    var err: NSDictionary?
    let res = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let e = err { print("  AS err: \(e["NSAppleScriptErrorMessage"] ?? e)") }
    return res?.stringValue ?? ""
}

// ── Navigate via AppleScript `set value` + key code 36 (перевірений робочий підхід) ──
// Після CGS switch → Logic frontmost → window 1 = NSSavePanel → sheet 1 of window 1 = Go-to-folder
func navigateToFolder(_ folder: String, panel: AXUIElement, pid: pid_t) {
    print("  📁 Навігація до: \(folder)")
    let safe = folder
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")

    // Крок 1: Відкриваємо Go-to-folder sheet
    runAS("""
    tell application "System Events"
      tell (first process whose bundle identifier is "com.apple.logic10")
        key code 5 using {command down, shift down}
      end tell
    end tell
    """)

    // Крок 2: Знаходимо sheet → ховаємо sheet + panel
    for _ in 0..<50 {
        Thread.sleep(forTimeInterval: 0.02)
        if let s = axKids(panel).first(where: { axRole($0) == "AXSheet" }) {
            moveToCorner(s, aggressive: true)
            moveToCorner(panel)
            print("  🫥 Go-to-folder sheet + панель приховані")
            break
        }
    }
    Thread.sleep(forTimeInterval: 0.25)

    // Крок 3: AppleScript `set value` — не залежить від key window чи позиції вікна
    // window 1 = NSSavePanel (frontmost window процесу Logic після CGS switch)
    // sheet 1 of window 1 = Go-to-folder sheet на NSSavePanel
    let result = runAS("""
    tell application "System Events"
      tell (first process whose bundle identifier is "com.apple.logic10")
        try
          if (count of sheets of window 1) > 0 then
            set value of text field 1 of sheet 1 of window 1 to "\(safe)"
            return "ok-sheet"
          end if
        end try
        return "not-found"
      end tell
    end tell
    """)
    print("  📁 Навігація result: \(result)")

    // Крок 4: Return → підтверджуємо навігацію
    // `tell process ... key code 36` іде до key window процесу = Go-to-folder sheet
    runAS("""
    tell application "System Events"
      tell (first process whose bundle identifier is "com.apple.logic10")
        key code 36
      end tell
    end tell
    """)
    Thread.sleep(forTimeInterval: 0.6)
}

// ── Set filename via AppleScript `set value` (як в app) ──
// Прямо встановлює значення — не залежить від key window чи позиції вікна
func setFilenameAppleScript(_ name: String) -> Bool {
    print("  ✏️  Встановлюємо filename: '\(name)'")
    let safe = name
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "")

    let result = runAS("""
    tell application "System Events"
      tell (first process whose bundle identifier is "com.apple.logic10")
        try
          if (count of sheets of window 1) > 0 then
            set value of text field "Save As:" of sheet 1 of window 1 to "\(safe)"
            return "ok-sheet"
          end if
        end try
        try
          set value of text field "Save As:" of first splitter group of window 1 to "\(safe)"
          return "ok-splitter"
        end try
        try
          set value of text field "Save As:" of window 1 to "\(safe)"
          return "ok-window"
        end try
        return "not-found"
      end tell
    end tell
    """)
    print("  filename result: '\(result)'")
    return result.hasPrefix("ok")
}

// ── Sanitize filename (як в app) ──
func sanitize(_ s: String) -> String {
    s.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
}

// ── Args ──
let cliArgs    = CommandLine.arguments
guard cliArgs.count >= 4 else {
    print("Використання: t_bounce_full <trackName> <outputFolder> <projectName> [template]")
    print("Приклад: t_bounce_full \"Kick\" \"/Users/dbsound/Desktop\" \"MyProject\" \"v1\"")
    exit(1)
}
let trackName    = cliArgs[1]
let outputFolder = cliArgs[2]
let projectName  = cliArgs[3]
let template     = cliArgs.count >= 5 ? cliArgs[4] : ""

// Будуємо filename і шлях папки
let rawFilename   = template.isEmpty ? trackName : template + "_" + trackName
let safeFilename  = sanitize(rawFilename)
let stemsFolder   = outputFolder + "/" + sanitize(projectName) + "/STEMS"

print("Track:    \(trackName)")
print("Filename: \(safeFilename)")
print("Folder:   \(stemsFolder)")

// Створюємо папку
do {
    try FileManager.default.createDirectory(atPath: stemsFolder, withIntermediateDirectories: true)
    print("✅ Папка створена: \(stemsFolder)")
} catch {
    print("⚠️  Папка вже існує або помилка: \(error)")
}

// ── Logic ──
guard let logicApp = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == "com.apple.logic10" }) else {
    print("❌ Logic не запущено"); exit(1)
}
let axApp    = AXUIElementCreateApplication(logicApp.processIdentifier)
let logicPid = logicApp.processIdentifier
let prevApp  = NSWorkspace.shared.frontmostApplication
print("Ти в: \(prevApp?.localizedName ?? "?"), fullscreen=\(isCurrentSpaceFullscreen())")

class BounceCtx {
    var dialogCount = 0
    var done        = false
    var isFirst     = true
    var observer: AXObserver? = nil  // for registering per-window sheet notifications
    var panel: AXUIElement?   = nil  // NSSavePanel element
}

func bounceObserverCB(_ obs: AXObserver, _ el: AXUIElement, _ notif: CFString, _ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    let state = Unmanaged<BounceCtx>.fromOpaque(ctx).takeUnretainedValue()
    let title = axTit(el)

    if state.done {
        // Ховаємо і панель і будь-який child sheet (Replace dialog)
        moveToCorner(el, aggressive: true)
        for kid in axKids(el) where axRole(kid) == "AXSheet" {
            moveToCorner(kid, aggressive: true)
        }
        // Шукаємо Replace кнопку у el та його дітях (sheet на NSSavePanel)
        if let btn = findBtn(el, "Replace") {
            let r = AXUIElementPerformAction(btn, kAXPressAction as CFString)
            print("  AXPress Replace (file exists): \(r.rawValue == 0 ? "✅" : "⚠️ \(r.rawValue)")")
        }
        return
    }
    guard title.contains("Bounce") || title.contains("Replace") else { return }
    state.dialogCount += 1
    print("  🔔 #\(state.dialogCount): '\(title)'")

    if state.dialogCount == 1 {
        // Dialog #1: ховаємо + OK
        moveToCorner(el)
        Thread.sleep(forTimeInterval: 0.1)
        if let btn = findBtn(el, "OK") ?? findBtn(el, "Bounce") {
            let r = AXUIElementPerformAction(btn, kAXPressAction as CFString)
            print("  AXPress OK: \(r.rawValue == 0 ? "✅" : "⚠️ \(r.rawValue)")")
        }
    } else {
        // Dialog #2: NSSavePanel
        // 1. Ховаємо панель одразу
        moveToCorner(el)
        Thread.sleep(forTimeInterval: 0.15)

        // 1b. Реєструємо kAXSheetCreatedNotification на самій NSSavePanel
        // (на axApp рівні воно не спрацьовує для sheets — тільки для windows)
        state.panel = el
        if let obs = state.observer {
            AXObserverAddNotification(obs, el, kAXSheetCreatedNotification as CFString, ctx)
        }

        // 2. Fullscreen — CGS switch ДО навігації (AppleScript не бачить Logic UI з іншого Space)
        let fullscreen = isCurrentSpaceFullscreen()
        if fullscreen {
            let ok = switchToLogicSpace(logicPID: logicPid)
            print("  Logic frontmost (CGS, pre-nav): \(ok ? "✅" : "⚠️")")
        }

        // 3. Navigate to folder (тільки перший bounce)
        if state.isFirst {
            navigateToFolder(stemsFolder, panel: el, pid: logicPid)
            state.isFirst = false
        }

        // 4. Встановлюємо filename через AppleScript
        setFilenameAppleScript(safeFilename)

        // 5. Ховаємо знову (навігація/sheet могла змістити вікно назад)
        moveToCorner(el)
        Thread.sleep(forTimeInterval: 0.1)

        // 5b. Перевіряємо filename field — юзер міг вписати щось своє під час навігації
        func readFilenameField() -> String {
            let r = runAS("""
            tell application "System Events"
              tell (first process whose bundle identifier is "com.apple.logic10")
                try
                  return value of text field "Save As:" of first splitter group of window 1
                end try
                try
                  return value of text field "Save As:" of window 1
                end try
                return ""
              end tell
            end tell
            """)
            return r
        }
        for attempt in 1...3 {
            let current = readFilenameField()
            if current == safeFilename { print("  ✅ filename OK: '\(current)'"); break }
            print("  ⚠️ filename mismatch (\(attempt)/3): got '\(current)', re-setting...")
            setFilenameAppleScript(safeFilename)
            Thread.sleep(forTimeInterval: 0.15)
            if attempt == 3 { print("  ⚠️ filename still wrong: '\(readFilenameField())'") }
        }
        moveToCorner(el)

        // 6. Non-fullscreen — activate перед AXPress
        if !fullscreen {
            runAS("tell application id \"com.apple.logic10\" to activate")
            Thread.sleep(forTimeInterval: 0.25)
            print("  Logic activated (non-fullscreen)")
        }

        // 7. AXPress Bounce з retry (якщо юзер взаємодіяв з іншим вікном)
        let btnName = title.contains("Replace") ? "Replace" : "Bounce"
        if let btn = findBtn(el, btnName) {
            var r = AXUIElementPerformAction(btn, kAXPressAction as CFString)
            if r.rawValue != 0 {
                print("  AXPress \(btnName): ⚠️ \(r.rawValue) — retry...")
                if fullscreen {
                    let ok = switchToLogicSpace(logicPID: logicPid)
                    print("  Re-activate (CGS): \(ok ? "✅" : "⚠️")")
                    // Після CGS switch панель може з'явитись — ховаємо знову
                    moveToCorner(el)
                    Thread.sleep(forTimeInterval: 0.1)
                    // Повторно виставляємо folder+filename (CGS switch міг скинути стан панелі)
                    navigateToFolder(stemsFolder, panel: el, pid: logicPid)
                    setFilenameAppleScript(safeFilename)
                    moveToCorner(el)
                    Thread.sleep(forTimeInterval: 0.1)
                } else {
                    runAS("tell application id \"com.apple.logic10\" to activate")
                    Thread.sleep(forTimeInterval: 0.3)
                }
                r = AXUIElementPerformAction(btn, kAXPressAction as CFString)
            }
            // -25202 = ActionUnsupported = dialog вже закритий = bounce стартував від першого press
            let ok = r.rawValue == 0 || r.rawValue == -25202
            print("  AXPress \(btnName): \(ok ? "✅" : "⚠️ \(r.rawValue)")")
        }
        state.done = true
    }
}

let ctx    = BounceCtx()
let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
var obs: AXObserver?
AXObserverCreate(logicPid, bounceObserverCB, &obs)
guard let observer = obs else { print("❌ Observer"); exit(1) }
ctx.observer = observer  // зберігаємо для реєстрації sheet notifications на NSSavePanel
for n in [kAXWindowCreatedNotification, kAXSheetCreatedNotification] {
    AXObserverAddNotification(observer, axApp, n as CFString, ctxPtr)
}
CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

// 5с щоб перейти в YouTube fullscreen
print("⏳ 5с — перейди в YouTube fullscreen...")
Thread.sleep(forTimeInterval: 5.0)

// Activate Logic + Cmd+B
if let s = NSAppleScript(source: "tell application id \"com.apple.logic10\" to activate") {
    var e: NSDictionary?; s.executeAndReturnError(&e)
}
Thread.sleep(forTimeInterval: 0.4)
let src = CGEventSource(stateID: .combinedSessionState)
if let dn = CGEvent(keyboardEventSource: src, virtualKey: 0x0B, keyDown: true),
   let up = CGEvent(keyboardEventSource: src, virtualKey: 0x0B, keyDown: false) {
    dn.flags = .maskCommand; up.flags = .maskCommand
    dn.post(tap: .cgSessionEventTap); Thread.sleep(forTimeInterval: 0.06); up.post(tap: .cgSessionEventTap)
}

let deadline = Date().addingTimeInterval(30)
while !ctx.done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
let hideDl = Date().addingTimeInterval(1.5)
while Date() < hideDl { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

for n in [kAXWindowCreatedNotification, kAXSheetCreatedNotification] {
    AXObserverRemoveNotification(observer, axApp, n as CFString)
}
// Прибираємо sheet notification з NSSavePanel (якщо була зареєстрована)
if let panel = ctx.panel {
    AXObserverRemoveNotification(observer, panel, kAXSheetCreatedNotification as CFString)
}
CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
Unmanaged<BounceCtx>.fromOpaque(ctxPtr).release()

if ctx.done {
    print("\n✅ Bounce! Рендер 5с...")
    Thread.sleep(forTimeInterval: 5.0)
    // Перевіряємо чи файл з'явився
    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(atPath: stemsFolder)) ?? []
    let found = files.filter { $0.hasPrefix(safeFilename) }
    print(found.isEmpty ? "⚠️  Файл не знайдено в \(stemsFolder)" : "✅ Файл: \(found)")
    prevApp?.activate()
    print("✅ Назад до '\(prevApp?.localizedName ?? "?")'")
} else {
    print("\n❌ Timeout")
}
