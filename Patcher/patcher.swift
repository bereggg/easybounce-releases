import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var progressBar: NSProgressIndicator!
    var statusLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "EasyBounce Patcher"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()

        let bg = GradientView(frame: window.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(bg)

        // Icon
        let iconView = NSImageView(frame: NSRect(x: 155, y: 185, width: 90, height: 90))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        bg.addSubview(iconView)

        // Title
        bg.addSubview(makeLabel("EasyBounce Patcher", size: 18, bold: true, y: 150))

        // Status label
        statusLabel = makeLabel("Preparing EasyBounce for launch…", size: 12, bold: false, y: 122)
        bg.addSubview(statusLabel)

        // Progress bar
        progressBar = NSProgressIndicator(frame: NSRect(x: 60, y: 90, width: 280, height: 6))
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0; progressBar.maxValue = 1; progressBar.doubleValue = 0
        bg.addSubview(progressBar)

        // Note
        let note = makeLabel("You only need to do this once", size: 10, bold: false, y: 32)
        note.alphaValue = 0.5
        bg.addSubview(note)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runPatch() }
    }

    func runPatch() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.8
            progressBar.animator().doubleValue = 0.6
        }
        DispatchQueue.global().async {
            let task = Process()
            task.launchPath = "/usr/bin/xattr"
            task.arguments = ["-cr", "/Applications/EasyBounce.app"]
            task.launch(); task.waitUntilExit()

            DispatchQueue.main.async {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    self.progressBar.animator().doubleValue = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.statusLabel.stringValue = "✅  EasyBounce is ready!"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func makeLabel(_ text: String, size: CGFloat, bold: Bool, y: CGFloat) -> NSTextField {
        let f = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        let lbl = NSTextField(labelWithString: text)
        lbl.font = f; lbl.textColor = .white; lbl.alignment = .center
        lbl.frame = NSRect(x: 20, y: y, width: 360, height: 26)
        return lbl
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

class GradientView: NSView {
    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let colors = [
            CGColor(red: 0.58, green: 0.20, blue: 0.92, alpha: 1),
            CGColor(red: 0.91, green: 0.25, blue: 0.60, alpha: 1),
        ]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: bounds.height),
                               end:   CGPoint(x: bounds.width, y: 0),
                               options: [])
    }
}
