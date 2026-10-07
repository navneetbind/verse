import AppKit

/// First-run setup. A browser launches Verse with arguments (Firefox passes the
/// host manifest path and the extension id, Chromium passes the extension
/// origin); opening Verse.app yourself launches it with none. That plain launch
/// registers Verse with every installed browser and explains the remaining step,
/// installing the extension.
enum Setup {
    static let hostName = "verse"
    static let firefoxExtensionID = "verse@local"
    static let chromeExtensionID = "gagjjbmjcifaamdoomimianilfhkiafc" // fixed by the `key` in manifest.json

    /// Browser profile roots under ~/Library/Application Support; a host file is
    /// only written for browsers that are actually installed.
    static let browsers: [(name: String, dir: String, gecko: Bool)] = [
        ("Firefox", "Mozilla", true),
        ("Chrome", "Google/Chrome", false),
        ("Chrome Beta", "Google/Chrome Beta", false),
        ("Chrome Canary", "Google/Chrome Canary", false),
        ("Chromium", "Chromium", false),
        ("Brave", "BraveSoftware/Brave-Browser", false),
        ("Edge", "Microsoft Edge", false),
        ("Vivaldi", "Vivaldi", false),
        ("Arc", "Arc/User Data", false),
    ]

    static var isUserLaunch: Bool {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        return args.isEmpty || args == ["--register"]
    }

    /// Running from the mounted DMG, or from the randomised copy macOS makes of
    /// an app opened in Downloads without being moved (App Translocation) — a
    /// path registered from there stops existing later.
    static var isRunningFromTemporaryLocation: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Writes the native-messaging host file for each installed browser, pointing
    /// at this executable. Returns the browsers registered.
    @discardableResult
    static func register() -> [String] {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        var done: [String] = []
        for b in browsers {
            let base = appSupport.appendingPathComponent(b.dir)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }
            let dir = base.appendingPathComponent("NativeMessagingHosts")
            var host: [String: Any] = [
                "name": hostName,
                "description": "Verse menu-bar lyrics host",
                "path": exe,
                "type": "stdio",
            ]
            if b.gecko {
                host["allowed_extensions"] = [firefoxExtensionID]
            } else {
                host["allowed_origins"] = ["chrome-extension://\(chromeExtensionID)/"]
            }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(
                    withJSONObject: host, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try data.write(to: dir.appendingPathComponent("\(hostName).json"))
                done.append(b.name)
            } catch {
                continue
            }
        }
        return done
    }

    /// Copies the bundled extension to a stable, visible-enough place: browsers
    /// keep pointing at an unpacked extension's folder, so it must not live in a
    /// DMG or move when the app is updated.
    static func installExtensionFolder() -> URL? {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("extension"),
              FileManager.default.fileExists(atPath: bundled.path) else { return nil }
        let dest = appSupport.appendingPathComponent("Verse/extension")
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: bundled, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Run for a plain launch: register, then tell the user what is left to do.
    static func runInteractive() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if isRunningFromTemporaryLocation {
            let alert = NSAlert()
            alert.messageText = "Move Verse to Applications first"
            alert.informativeText = """
            Verse is running from the disk image or a temporary copy, so your browser \
            would lose track of it later.

            Drag Verse into your Applications folder, then open it from there.
            """
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let registered = register()
        let ext = installExtensionFolder()

        let alert = NSAlert()
        alert.messageText = registered.isEmpty ? "No supported browser found" : "Verse is ready"
        let browsersLine = registered.isEmpty
            ? "Install Firefox, Chrome, Brave, Edge, Vivaldi or Arc, then open Verse again."
            : "Connected to: \(registered.joined(separator: ", "))."
        alert.informativeText = """
        \(browsersLine)

        Last step — add the Verse extension to your browser:

        • Chrome, Brave, Edge, Vivaldi, Arc: open the extensions page, turn on Developer mode, click "Load unpacked" and choose the extension folder.

        • Firefox: open about:debugging → This Firefox → "Load Temporary Add-on…" and choose manifest.json in the extension folder. (Firefox drops it on restart.)

        Then play a song on music.youtube.com — Verse appears in the menu bar by itself.
        """
        if ext != nil { alert.addButton(withTitle: "Show Extension Folder") }
        alert.addButton(withTitle: "Done")
        let choice = alert.runModal()
        if let ext, choice == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([ext.appendingPathComponent("manifest.json")])
        }
    }
}
