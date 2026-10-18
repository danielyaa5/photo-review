// Investigation only. Not included in either shipping app target.
// Reads metadata with a read-only SQLite connection and no network entitlement.
import AppKit
import SQLite3

func measure(_ library: URL) throws -> [String: Any] {
    let started = Date()
    let file = library.appendingPathComponent("database/Photos.sqlite")
    var db: OpaquePointer?
    let opened = sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil)
    defer { sqlite3_close(db) }
    func failure(_ code: Int32) -> NSError {
        NSError(domain: "SizeProbe", code: Int(code), userInfo: [NSLocalizedDescriptionKey:
            db.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable"])
    }
    guard opened == SQLITE_OK else { throw failure(opened) }
    sqlite3_busy_timeout(db, 1500)
    guard sqlite3_db_readonly(db, "main") == 1 else { throw failure(SQLITE_READONLY) }
    guard sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN", nil, nil, nil) == SQLITE_OK else {
        throw failure(sqlite3_errcode(db))
    }
    defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
    // Deliberately excludes filenames, UUIDs, locations and other personal metadata from the report.
    let query = "SELECT ZORIGINALFILESIZE FROM ZADDITIONALASSETATTRIBUTES ORDER BY ZORIGINALFILESIZE DESC"
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(db, query, -1, &statement, nil)
    defer { sqlite3_finalize(statement) }
    guard prepared == SQLITE_OK else { throw failure(prepared) }
    var count = 0, known = 0
    var largest: [Int64] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
        count += 1
        let bytes = sqlite3_column_int64(statement, 0)
        if bytes > 0 { known += 1 }
        if largest.count < 10 { largest.append(bytes) }
        result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw failure(result) }
    return ["records": count, "knownOriginalSizes": known, "largestOriginalBytes": largest,
            "sqliteReadOnly": true, "seconds": Date().timeIntervalSince(started)]
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let output = NSTextField(wrappingLabelWithString: "Choose a Photos library to test read-only size metadata access.")
    var report: [String: Any] = [:]
    var granted: URL?
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Photo Review Size Investigation"
        let choose = NSButton(title: "Choose Photos Library…", target: self, action: #selector(pick))
        let quit = NSButton(title: "Close", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let stack = NSStackView(views: [output, choose, quit])
        stack.orientation = .vertical; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        let restoreOnly = CommandLine.arguments.contains("--restore-only")
        if !restoreOnly {
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
        if let data = UserDefaults.standard.data(forKey: "libraryBookmark") {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw NSError(domain: "Bookmark", code: 1) }
                granted = url
                report["restoredBookmark"] = true
                run(url)
            } catch { record("Bookmark restore failed: \(error.localizedDescription)") }
        } else if CommandLine.arguments.count > 1 {
            do {
                report["beforeGrant"] = try measure(URL(fileURLWithPath: CommandLine.arguments[1]))
            } catch { report["beforeGrantDenied"] = error.localizedDescription }
            save()
        }
        if restoreOnly { DispatchQueue.main.async { NSApp.terminate(nil) } }
    }
    @objc func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a Photos library. This investigation reads size records only."
        panel.prompt = "Read Sizes"
        do {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(data, forKey: "libraryBookmark")
                self.granted = url
                _ = url.startAccessingSecurityScopedResource()
                self.run(url)
            } catch { self.record(error.localizedDescription) }
        }
    }
    func run(_ url: URL) {
        do {
            let result = try measure(url)
            report["afterGrant"] = result
            output.stringValue = "Read-only query succeeded.\n\(result["knownOriginalSizes"]!) original sizes found.\nLargest sizes (bytes): \(result["largestOriginalBytes"]!)\nTime: \(result["seconds"]!) seconds"
            save()
        } catch { record(error.localizedDescription) }
    }
    func record(_ error: String) { report["error"] = error; output.stringValue = error; save() }
    func save() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("size-probe-result.json"), options: .atomic)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Delegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
