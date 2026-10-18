import AVFoundation
import AppKit
import CoreImage
import ImageIO
import Network
import Photos
import QuickLookThumbnailing
import UniformTypeIdentifiers
import UserNotifications
import VideoToolbox
import WebKit

/// 8377 unless started with `--port N`.
let port: UInt16 = {
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--port"), flag + 1 < arguments.count, let value = UInt16(arguments[flag + 1]) {
        return value
    }
    return 8377
}()
// Sent back by the page on every state-changing request, so other sites can't drive the server.
let token = UUID().uuidString

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Where the app keeps a file between runs: ~/Library/Application Support/Photo Review, unless the given
/// command-line flag names another path (used for testing).
func dataFile(_ name: String, flag: String) -> URL {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[index + 1])
    }
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Photo Review")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(name)
}

// MARK: - Distribution

#if APP_STORE
/// Folder grants come only from NSOpenPanel and are restored through app-scoped bookmarks.
final class FolderAccess {
    static let shared = FolderAccess()
    private var urls: [URL] = []
    private let defaults = UserDefaults.standard
    private let key = "folderBookmarks"

    private init() {
        let bookmarks = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        for data in bookmarks.values {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource()
            else { continue }
            urls.append(url)
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope],
                includingResourceValuesForKeys: nil, relativeTo: nil) {
                var saved = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
                saved[url.path] = fresh
                defaults.set(saved, forKey: key)
            }
        }
    }

    func remember(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var saved = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        saved[url.path] = data
        defaults.set(saved, forKey: key)
        if !urls.contains(url), url.startAccessingSecurityScopedResource() { urls.append(url) }
    }
}
#endif

/// Prefer public PhotoKit sizes, then the explicitly selected read-only metadata index.
func resourceBytes(_ resource: PHAssetResource, asset: PHAsset? = nil) -> Int64? {
    #if APP_STORE
    #if DEBUG
    if CommandLine.arguments.contains("--database-sizes") { return PhotosSizeAccess.shared.bytes(resource, asset: asset) }
    #endif
    if #available(macOS 27, *), let bytes = resource.dataSize { return Int64(bytes) }
    return PhotosSizeAccess.shared.bytes(resource, asset: asset)
    #else
    return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    #endif
}

// MARK: - Updates

/// Asks GitHub whether a newer release is out. The request is the same as opening the releases page in a
/// browser, and nothing about the library is sent. The app checks when it opens and once a day while it stays open,
/// unless that's switched off.
#if !APP_STORE
final class UpdateChecker {
    private let lock = NSLock()
    private var latest: (version: String, page: URL)?
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let releasesPage = URL(string: "https://github.com/danielyaa5/photo-review/releases/latest")!
    /// `--update-url URL` points the check somewhere else, for testing.
    private let endpoint: URL = {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--update-url"), flag + 1 < arguments.count, let url = URL(string: arguments[flag + 1]) {
            return url
        }
        return URL(string: "https://api.github.com/repos/danielyaa5/photo-review/releases/latest")!
    }()

    /// Calls back with the newer version and its page, nil for both when this one is current, or a problem.
    func check(_ completion: ((_ newer: (version: String, page: URL)?, _ problem: String?) -> Void)? = nil) {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Photo Review/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let tag = json["tag_name"] as? String
            else {
                log("update check failed: \(error?.localizedDescription ?? "no release in the answer")")
                completion?(nil, error?.localizedDescription ?? "GitHub didn't say which version is the latest.")
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? UpdateChecker.releasesPage
            self.lock.lock()
            self.latest = (version, page)
            self.lock.unlock()
            log("update check: latest \(version), this is \(self.current)")
            completion?(UpdateChecker.isNewer(version, than: self.current) ? (version, page) : nil, nil)
        }.resume()
    }

    /// Compares dotted version numbers part by part: 0.5.10 is newer than 0.5.9.
    static func isNewer(_ version: String, than other: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = other.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// What the page needs for its "a new version is out" note.
    var json: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let available = latest.map { UpdateChecker.isNewer($0.version, than: current) } ?? false
        return [
            "current": current, "latest": latest?.version ?? NSNull(), "url": latest?.page.absoluteString ?? NSNull(),
            "available": available,
        ]
    }
}

let updates = UpdateChecker()
#endif

// MARK: - Library

struct Item {
    let id: String
    let name: String
    let bytes: Int64
    var sizeKnown: Bool = true
    let date: String
    let year: Int
    let isVideo: Bool
    /// A photo whose original is a camera RAW file, which can be compressed into a 10-bit HEIC copy.
    let isRaw: Bool
    /// A Live Photo: a still with a short video. A copy of the still alone drops the video.
    let isLive: Bool
    /// A photo stored as JPEG, which a HEIC copy can make about half the size.
    let isJPEG: Bool
    /// Bytes taken by a Live Photo's video, original and edited, so the page can say what dropping it saves.
    let motionBytes: Int64
    let width: Int
    let height: Int
    let duration: Double
    let favorite: Bool
    /// Slo-mo, time-lapse, edited and similar, for display.
    let tags: [String]

    var json: [String: Any] {
        [
            "id": id, "name": name, "bytes": bytes, "sizeKnown": sizeKnown, "date": date, "year": year, "video": isVideo, "raw": isRaw,
            "live": isLive, "jpeg": isJPEG, "motion": motionBytes, "w": width, "h": height, "dur": duration,
            "fav": favorite, "tags": tags,
        ]
    }

    /// What a smaller copy can be made of: a video re-encoded, a RAW or JPEG photo saved as HEIC, or the
    /// still of a Live Photo without its video. Other photos are already compact.
    var isCompressible: Bool { sizeKnown && (isVideo || isRaw || isLive || isJPEG) }

    /// Camera RAW files by name, for measurements cached before the app recorded RAW separately.
    static func looksRaw(_ name: String) -> Bool {
        let rawExtensions: Set<String> = [
            "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "3fr",
            "iiq", "erf", "kdc", "dcr", "mos", "mrw", "x3f", "rwl", "gpr",
        ]
        return rawExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

extension Item {
    /// Rebuilds an item from `json`, as stored in the measurement cache.
    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String,
            let bytes = (json["bytes"] as? NSNumber)?.int64Value
        else { return nil }
        let isVideo = json["video"] as? Bool ?? false
        let isRaw = json["raw"] as? Bool ?? (!isVideo && Item.looksRaw(name))
        var tags = json["tags"] as? [String] ?? []
        if isRaw && !tags.contains("RAW") { tags.insert("RAW", at: 0) }
        // Measurements saved before these were recorded fall back to the tags and the file name.
        let isLive = json["live"] as? Bool ?? (!isVideo && tags.contains("live"))
        let isJPEG = json["jpeg"] as? Bool ?? (!isVideo && !isRaw && ["jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased()))
        self.init(
            id: id, name: name, bytes: bytes, sizeKnown: json["sizeKnown"] as? Bool ?? true, date: json["date"] as? String ?? "", year: json["year"] as? Int ?? 0,
            isVideo: isVideo, isRaw: isRaw, isLive: isLive, isJPEG: isJPEG,
            motionBytes: (json["motion"] as? NSNumber)?.int64Value ?? 0, width: json["w"] as? Int ?? 0, height: json["h"] as? Int ?? 0,
            duration: (json["dur"] as? NSNumber)?.doubleValue ?? 0, favorite: json["fav"] as? Bool ?? false,
            tags: tags)
    }
}

final class Library {
    private let lock = NSLock()
    private var items: [String: Item] = [:]
    /// starting, scanning (first measurement), updating (re-measuring while the old list stays usable),
    /// ready, denied or limited.
    private var status = "starting"
    private var total = 0
    private var scanned = 0
    /// When the list was last measured from Photos.
    private var measuredAt: Date?
    /// Items added or removed by the app while a re-measure is running, applied once it finishes.
    private var changedDuringUpdate: [(id: String, item: Item?)] = []
    private var saveQueued = false

    /// Measuring a big library takes about a minute, so the result is kept and reused for a day.
    private let cacheFile = dataFile("library.json", flag: "--cache")
    #if APP_STORE
    private static let cacheVersion = 2
    #else
    private static let cacheVersion = 1
    #endif
    private static let cacheLifetime: TimeInterval = 24 * 60 * 60

    func start() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { auth in
            switch auth {
            case .authorized:
                #if APP_STORE
                var needsSizeLibrary = true
                if #available(macOS 27, *) { needsSizeLibrary = false }
                #if DEBUG
                if CommandLine.arguments.contains("--database-sizes") { needsSizeLibrary = true }
                #endif
                if needsSizeLibrary, PhotosSizeAccess.shared.state["sizeLibrarySelected"] as? Bool != true {
                    self.setStatus("needsLibrary")
                    return
                }
                PhotosSizeAccess.shared.reload()
                #endif
                if self.loadCache() {
                    self.setStatus("ready")
                } else {
                    self.setStatus("scanning")
                    DispatchQueue.global(qos: .userInitiated).async { self.scan(replacing: false) }
                }
            case .limited:
                self.setStatus("limited")
            default:
                self.setStatus("denied")
            }
        }
    }

    var canChooseSizeLibrary: Bool {
        lock.lock(); defer { lock.unlock() }
        return status == "ready" || status == "needsLibrary"
    }

    private func setStatus(_ value: String) {
        lock.lock()
        status = value
        lock.unlock()
        log("status: \(value)")
    }

    /// Measures the library again, keeping the current list in place until the new one is complete.
    /// Returns false if there is nothing to update yet or a measurement is already running.
    @discardableResult
    func update() -> Bool {
        lock.lock()
        let idle = status == "ready" || status == "needsLibrary"
        let replacing = status == "ready"
        if idle {
            status = replacing ? "updating" : "scanning"
            scanned = 0
        }
        lock.unlock()
        if idle { DispatchQueue.global(qos: .userInitiated).async { self.scan(replacing: replacing) } }
        return idle
    }

    private func scan(replacing: Bool) {
        #if APP_STORE
        PhotosSizeAccess.shared.reload()
        #endif
        // Videos first: they hold most of the space, so the top of the list settles quickly.
        let groups = [PHAsset.fetchAssets(with: .video, options: nil), PHAsset.fetchAssets(with: .image, options: nil)]
        lock.lock()
        total = groups.reduce(0) { $0 + $1.count }
        scanned = 0
        changedDuringUpdate = []
        lock.unlock()
        let calendar = Calendar.current
        var fresh: [String: Item] = [:]
        for group in groups {
            group.enumerateObjects { asset, _, _ in
                autoreleasepool {
                    let item = Library.makeItem(asset, calendar)
                    self.lock.lock()
                    // A first measurement fills the visible list as it goes; an update swaps in at the end.
                    if replacing { fresh[item.id] = item } else { self.items[item.id] = item }
                    self.scanned += 1
                    self.lock.unlock()
                }
            }
        }
        lock.lock()
        if replacing {
            items = fresh
            for change in changedDuringUpdate { items[change.id] = change.item }
        }
        changedDuringUpdate = []
        measuredAt = Date()
        lock.unlock()
        saveCache()
        setStatus("ready")
    }

    /// Loads the saved measurement if there is one from the last day. Returns false otherwise.
    private func loadCache() -> Bool {
        guard let data = try? Data(contentsOf: cacheFile),
            let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            saved["version"] as? Int == Library.cacheVersion,
            let stamp = (saved["measuredAt"] as? NSNumber)?.doubleValue,
            let list = saved["items"] as? [[String: Any]]
        else { return false }
        let measured = Date(timeIntervalSince1970: stamp)
        let age = Date().timeIntervalSince(measured)
        guard age >= 0, age < Library.cacheLifetime else { return false }
        var loaded: [String: Item] = [:]
        for entry in list {
            if let item = Item(entry) { loaded[item.id] = item }
        }
        guard !loaded.isEmpty else { return false }
        lock.lock()
        items = loaded
        measuredAt = measured
        total = loaded.count
        scanned = loaded.count
        lock.unlock()
        log("loaded \(loaded.count) items measured \(Int(age / 60)) min ago")
        return true
    }

    private func saveCache() {
        lock.lock()
        saveQueued = false
        let list = items.values.map { $0.json }
        let stamp = measuredAt?.timeIntervalSince1970
        lock.unlock()
        guard let stamp = stamp else { return }
        let saved: [String: Any] = ["version": Library.cacheVersion, "measuredAt": stamp, "items": list]
        guard let data = try? JSONSerialization.data(withJSONObject: saved) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }

    /// Saves shortly, folding together changes that arrive in a burst (a batch delete, say).
    private func saveCacheSoon() {
        lock.lock()
        let already = saveQueued
        saveQueued = true
        lock.unlock()
        if already { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { self.saveCache() }
    }

    /// Records a change the app itself made to the library. Call with the lock held.
    private func noteChange(_ id: String, _ item: Item?) {
        items[id] = item
        if status == "updating" { changedDuringUpdate.append((id, item)) }
    }

    private static func makeItem(_ asset: PHAsset, _ calendar: Calendar) -> Item {
        let resources = PHAssetResource.assetResources(for: asset)
        // Everything stored for the item counts: original, edited version, Live Photo video.
        var bytes: Int64 = 0
        var motionBytes: Int64 = 0
        var sizeKnown = true
        for resource in resources {
            let known = resourceBytes(resource, asset: asset)
            if known == nil { sizeKnown = false }
            let size = known ?? 0
            bytes += size
            if resource.type == .pairedVideo || resource.type == .fullSizePairedVideo { motionBytes += size }
        }
        let primary = resources.first { $0.type == .video || $0.type == .photo } ?? resources.first
        var date = ""
        var year = 0
        if let created = asset.creationDate {
            let parts = calendar.dateComponents([.year, .month, .day], from: created)
            year = parts.year ?? 0
            date = String(format: "%04d-%02d-%02d", year, parts.month ?? 0, parts.day ?? 0)
        }
        var tags: [String] = []
        let subtypes = asset.mediaSubtypes
        if subtypes.contains(.videoHighFrameRate) { tags.append("slo-mo") }
        if subtypes.contains(.videoTimelapse) { tags.append("time-lapse") }
        if subtypes.contains(.videoCinematic) { tags.append("cinematic") }
        if subtypes.contains(.photoLive) { tags.append("live") }
        if subtypes.contains(.photoPanorama) { tags.append("panorama") }
        if subtypes.contains(.photoScreenshot) { tags.append("screenshot") }
        // A RAW photo is one whose own original is a RAW file. RAW+JPEG pairs, where Photos shows the JPEG, aren't.
        let isRaw = asset.mediaType == .image && primary?.type == .photo
            && (primary.flatMap { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) } ?? false)
        if isRaw { tags.append("RAW") }
        // Going by the video itself rather than its size, which Photos doesn't always know.
        let isLive = asset.mediaType == .image && subtypes.contains(.photoLive)
            && resources.contains { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }
        // A JPEG with a RAW file kept alongside it (RAW+JPEG from a camera) isn't offered: a copy would drop the RAW.
        let isJPEG = asset.mediaType == .image && !isRaw && primary?.type == .photo
            && (primary.flatMap { UTType($0.uniformTypeIdentifier)?.conforms(to: .jpeg) } ?? false)
            && !resources.contains { $0.type == .alternatePhoto }
        if asset.hasAdjustments { tags.append("edited") }
        #if !APP_STORE
        // Not a public property, so only read it where it exists. A hint: it goes stale as Photos frees space.
        if let primary = primary, primary.responds(to: NSSelectorFromString("isLocallyAvailable")),
            primary.value(forKey: "locallyAvailable") as? Bool == true
        {
            tags.append("on this Mac")
        }
        #endif
        return Item(
            id: asset.localIdentifier, name: primary?.originalFilename ?? "(unnamed)", bytes: bytes, sizeKnown: sizeKnown,
            date: date, year: year, isVideo: asset.mediaType == .video, isRaw: isRaw, isLive: isLive, isJPEG: isJPEG,
            motionBytes: motionBytes, width: asset.pixelWidth,
            height: asset.pixelHeight, duration: asset.duration, favorite: asset.isFavorite, tags: tags)
    }

    /// `minBytes` leaves out anything smaller, for picking many items at once.
    func query(kind: String, year: Int?, minBytes: Int64 = 0, offset: Int, limit: Int) -> [String: Any] {
        lock.lock()
        let all = Array(items.values)
        var state: [String: Any] = ["status": status, "scanned": scanned, "total": total]
        state["measuredAt"] = measuredAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
        let stale = status == "ready" && (measuredAt.map { Date().timeIntervalSince($0) > Library.cacheLifetime } ?? false)
        lock.unlock()
        // Left running for more than a day, the app refreshes itself the next time someone looks.
        if stale { update() }

        #if APP_STORE
        state.merge(PhotosSizeAccess.shared.state) { $1 }
        #endif
        return state.merging(Library.listing(all, kind: kind, year: year, minBytes: minBytes, offset: offset, limit: limit)) { $1 }
    }

    /// One page of `all`, largest first, with the totals the page shows. Folders list their files the same way.
    static func listing(_ all: [Item], kind: String, year: Int?, minBytes: Int64, offset: Int, limit: Int) -> [String: Any] {
        var years: [Int: (bytes: Int64, count: Int)] = [:]
        var libraryBytes: Int64 = 0
        var rawCount = 0
        for item in all {
            libraryBytes += item.bytes
            years[item.year, default: (0, 0)].bytes += item.bytes
            years[item.year, default: (0, 0)].count += 1
            if item.isRaw { rawCount += 1 }
        }
        // "photo" includes RAW photos; "raw" is only those.
        let matches = all.filter { item in
            let kindMatches = kind == "all" || (kind == "raw" ? item.isRaw : (kind == "video") == item.isVideo)
            return kindMatches && (year == nil || item.year == year) && item.bytes >= minBytes
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
        let page = matches.dropFirst(max(0, offset)).prefix(max(0, limit))

        var result: [String: Any] = [:]
        result["libraryBytes"] = libraryBytes
        result["libraryCount"] = all.count
        result["unknownSizeCount"] = all.filter { !$0.sizeKnown }.count
        // The page only offers a RAW filter when there is something for it to show.
        result["rawCount"] = rawCount
        result["matchCount"] = matches.count
        result["matchBytes"] = matches.reduce(Int64(0)) { $0 + $1.bytes }
        result["years"] = years.keys.sorted(by: >).map { ["year": $0, "bytes": years[$0]!.bytes, "count": years[$0]!.count] }
        result["items"] = page.map { $0.json }
        return result
    }

    func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Drops any of these items that Photos no longer has, such as ones deleted in the Photos app itself
    /// or on another device, and returns their ids.
    @discardableResult
    func forget(missingAmong ids: [String]) -> Set<String> {
        guard !ids.isEmpty, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return [] }
        var present = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            present.insert(asset.localIdentifier)
        }
        let missing = Set(ids).subtracting(present)
        guard !missing.isEmpty else { return [] }
        // If Photos has nothing at all to show, the library is unavailable, not emptied: forget nothing.
        let probe = PHFetchOptions()
        probe.fetchLimit = 1
        guard PHAsset.fetchAssets(with: probe).count > 0 else { return [] }
        lock.lock()
        for id in missing where items[id] != nil { noteChange(id, nil) }
        lock.unlock()
        saveCacheSoon()
        return missing
    }

    /// True once there is a complete list to work from, including while it is being re-measured.
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status == "ready" || status == "updating"
    }

    func item(_ id: String) -> Item? {
        lock.lock()
        defer { lock.unlock() }
        return items[id]
    }

    /// Measures a newly created asset and adds it to the list.
    func add(_ asset: PHAsset) -> Item {
        #if APP_STORE
        PhotosSizeAccess.shared.reload()
        #endif
        let item = Library.makeItem(asset, Calendar.current)
        lock.lock()
        noteChange(item.id, item)
        lock.unlock()
        saveCacheSoon()
        return item
    }

    /// Calls back with a JPEG and whether it is the real thing or only Photos' blurry placeholder.
    func thumbnail(id: String, size: Int, completion: @escaping (Data?, Bool) -> Void) {
        guard let asset = asset(id) else { return completion(nil, false) }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        #if DEBUG && APP_STORE
        if CommandLine.arguments.contains("--database-sizes") { options.isNetworkAccessAllowed = false }
        #endif

        // Photos may deliver a placeholder first and the real image later, much later, or never.
        // The grid shouldn't wait long for it; the viewer can.
        let patience: Double = size > 600 ? 20 : 2
        let once = NSLock()
        var finished = false
        var fallback: NSImage?
        func finish(_ image: NSImage?, sharp: Bool) {
            once.lock()
            let already = finished
            finished = true
            once.unlock()
            if already { return }
            DispatchQueue.global(qos: .userInitiated).async { completion(image.flatMap(jpegData), sharp) }
        }
        func giveUp(after seconds: Double) {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                once.lock()
                let image = fallback
                once.unlock()
                finish(image, sharp: false)
            }
        }
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: size, height: size), contentMode: .aspectFit, options: options
        ) { image, info in
            if (info?[PHImageResultIsDegradedKey] as? Bool) ?? false {
                once.lock()
                fallback = image ?? fallback
                once.unlock()
                giveUp(after: patience)
            } else {
                once.lock()
                let best = image ?? fallback
                once.unlock()
                finish(best, sharp: image != nil)
            }
        }
        giveUp(after: patience + 15)
    }

    /// A playable file for the video. Uses the copy on this Mac when there is one; otherwise asks Photos to
    /// fetch a reduced-size version from iCloud. Photos fetches one thing at a time, so this can stall behind
    /// a large download; after `patience` seconds it gives up with nil.
    func videoURL(id: String, patience: Double = 45, completion: @escaping (URL?) -> Void) {
        guard let asset = asset(id), asset.mediaType == .video else { return completion(nil) }
        let once = NSLock()
        var finished = false
        func finish(_ url: URL?) {
            once.lock()
            let already = finished
            finished = true
            once.unlock()
            if !already { completion(url) }
        }
        let local = PHVideoRequestOptions()
        local.isNetworkAccessAllowed = false
        local.deliveryMode = .automatic
        PHImageManager.default().requestAVAsset(forVideo: asset, options: local) { video, _, _ in
            if let url = (video as? AVURLAsset)?.url { return finish(url) }
            let remote = PHVideoRequestOptions()
            remote.isNetworkAccessAllowed = true
            remote.deliveryMode = .mediumQualityFormat
            let request = PHImageManager.default().requestAVAsset(forVideo: asset, options: remote) { video, _, info in
                if video == nil { log("video \(id): \(String(describing: info))") }
                finish((video as? AVURLAsset)?.url)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + patience) {
                once.lock()
                let pending = !finished
                once.unlock()
                if pending { PHImageManager.default().cancelImageRequest(request) }
                finish(nil)
            }
        }
    }

    /// Photos shows its own confirmation dialog before anything is removed.
    func delete(ids: [String], completion: @escaping (Bool, String?) -> Void) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return completion(false, "Those items are no longer in the library.") }
        var found: [String] = []
        assets.enumerateObjects { asset, _, _ in found.append(asset.localIdentifier) }
        // The confirmation is this app's own dialog, so the app has to come forward for it to be seen.
        // Once it has been answered, hand the screen back to whatever was in front: another app, when the
        // deletion comes at the end of a long queue, or the browser for someone using the page there.
        var previous: NSRunningApplication?
        DispatchQueue.main.async {
            previous = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets)
        }) { ok, error in
            DispatchQueue.main.async {
                guard let previous = previous, previous != NSRunningApplication.current, !previous.isTerminated else { return }
                if #available(macOS 14.0, *) { NSApp.yieldActivation(to: previous) }
                previous.activate(options: [])
            }
            if ok {
                self.lock.lock()
                for id in found { self.noteChange(id, nil) }
                self.lock.unlock()
                self.saveCacheSoon()
                completion(true, nil)
            } else if (error as NSError?)?.code == 3072 {
                completion(false, "Cancelled. Nothing was deleted.")
            } else {
                completion(false, error?.localizedDescription ?? "Photos refused the deletion.")
            }
        }
    }
}

func jpegData(_ image: NSImage) -> Data? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
}

// MARK: - Folders

/// Photos and videos in folders the person adds: on this Mac, on an external drive, or in Google Drive through
/// Google Drive for desktop, which puts a Drive in Finder. Their items work like Photos items, with ids of the
/// form "file:" and the path, so the two kinds never clash.
final class Folders {
    struct Folder {
        let path: String
        /// "local" or "drive".
        let source: String
    }

    /// What is known about one folder's contents.
    final class Scan {
        /// scanning, ready, or missing (not there now, such as a drive that isn't plugged in).
        var status = "scanning"
        var scanned = 0
        var total = 0
        var items: [String: Item] = [:]
        var measuredAt: Date?
    }

    static let prefix = "file:"
    /// The folder inside each added folder where smaller copies go.
    static let copies = "Compressed"
    private let lock = NSLock()
    private var folders: [Folder] = []
    private var scans: [String: Scan] = [:]
    private let file = dataFile("folders.json", flag: "--folders")
    /// Tests can let files under this folder go to the Trash without the question. Nothing else can skip it.
    private let trashWithoutAsking: String? = {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--trash-without-asking-under"), flag + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1]).standardizedFileURL.path
    }()

    init() {
        #if APP_STORE
        _ = FolderAccess.shared
        #endif
        guard let data = try? Data(contentsOf: file), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]]
        else { return }
        folders = list.compactMap { entry in
            guard let path = entry["path"], let source = entry["source"] else { return nil }
            return Folder(path: path, source: source)
        }
    }

    private func save() {
        lock.lock()
        let list = folders.map { ["path": $0.path, "source": $0.source] }
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: list) { try? data.write(to: file, options: .atomic) }
    }

    static func isFile(_ id: String) -> Bool { id.hasPrefix(prefix) }
    /// One spelling for each path (macOS writes some both with and without /private), so a folder is known once.
    static func normal(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    static func id(_ url: URL) -> String { prefix + url.standardizedFileURL.path }
    static func url(_ id: String) -> URL? { isFile(id) ? URL(fileURLWithPath: String(id.dropFirst(prefix.count))) : nil }

    /// Google Drive for desktop's folders in Finder, one for each signed-in account. `--drive-root PATH` stands in
    /// for them in tests.
    static var driveRoots: [URL] {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--drive-root"), flag + 1 < arguments.count {
            return [URL(fileURLWithPath: arguments[flag + 1], isDirectory: true).standardizedFileURL]
        }
        #if APP_STORE
        // Sandboxed apps discover availability, not account folders. Folder access is always chosen in a panel.
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.drivefs") == nil
            ? [] : [URL(fileURLWithPath: "/Google Drive", isDirectory: true)]
        #else
        let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
        return names.filter { $0.hasPrefix("GoogleDrive") }.sorted().map { storage.appendingPathComponent($0, isDirectory: true) }
        #endif
    }

    static func inDrive(_ path: String) -> Bool {
        let path = normal(path)
        #if APP_STORE
        let parts = URL(fileURLWithPath: path).pathComponents
        return parts.contains { $0.hasPrefix("GoogleDrive-") }
        #else
        return driveRoots.contains { path == $0.path || path.hasPrefix($0.path + "/") }
        #endif
    }

    /// How a folder's place is shown: "My Drive / Videos" in Drive, "~/Movies/Trips" in the home folder.
    static func place(_ path: String) -> String {
        let path = normal(path)
        #if APP_STORE
        let components = URL(fileURLWithPath: path).pathComponents
        if let drive = components.firstIndex(where: { $0.hasPrefix("GoogleDrive-") }) {
            return components.dropFirst(drive + 1).joined(separator: " / ")
        }
        #endif
        if let root = driveRoots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
            return String(path.dropFirst(root.path.count)).split(separator: "/").joined(separator: " / ")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("/Volumes/") { return path.split(separator: "/").dropFirst().joined(separator: " / ") }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The added folders of one source, each with what its last look found.
    func list(source: String) -> [[String: Any]] {
        lock.lock()
        let mine = folders.filter { $0.source == source }
        lock.unlock()
        return mine.map { folder in
            let scan = scanIfNeeded(folder.path)
            lock.lock()
            defer { lock.unlock() }
            let bytes = scan.items.values.reduce(Int64(0)) { $0 + $1.bytes }
            return [
                "path": folder.path, "name": (folder.path as NSString).lastPathComponent, "place": Folders.place(folder.path),
                "status": scan.status, "count": scan.items.count, "bytes": bytes, "scanned": scan.scanned, "total": scan.total,
            ]
        }
    }

    /// Adds a folder the person chose. Returns nil, or why it can't be added.
    func add(path: String, source: String) -> String? {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            return "That folder isn't there any more."
        }
        if url.pathComponents.contains(where: { $0.hasSuffix(".photoslibrary") }) {
            return "That's a Photos library. Its photos and videos are under Apple Photos."
        }
        if source == "drive" && !Folders.inDrive(url.path) {
            return "That folder isn't in Google Drive. Choose one inside Google Drive in Finder, or add it under Local Folder."
        }
        lock.lock()
        if !folders.contains(where: { $0.path == url.path }) { folders.append(Folder(path: url.path, source: source)) }
        lock.unlock()
        save()
        _ = scanIfNeeded(url.path)
        return nil
    }

    /// Takes a folder off the list. Its files aren't touched.
    func remove(path: String) {
        let path = Folders.normal(path)
        lock.lock()
        folders.removeAll { $0.path == path }
        scans[path] = nil
        lock.unlock()
        save()
    }

    /// Looks through the folder again, keeping the old list in view until the new one is complete.
    func rescan(_ path: String) {
        let path = Folders.normal(path)
        lock.lock()
        let scan = Scan()
        scan.items = scans[path]?.items ?? [:]
        scans[path] = scan
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { self.scan(path, into: scan) }
    }

    private func scanIfNeeded(_ path: String) -> Scan {
        lock.lock()
        if let scan = scans[path] {
            lock.unlock()
            return scan
        }
        let scan = Scan()
        scans[path] = scan
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { self.scan(path, into: scan) }
        return scan
    }

    static let keys: [URLResourceKey] = [
        .isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentTypeKey, .creationDateKey,
        .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey,
    ]

    /// Lists the folder's photos and videos with their sizes first, then reads each one's size in pixels, length and
    /// date, largest first, so the top of the list settles quickly. Files that are only in the cloud aren't opened,
    /// since that would download them.
    private func scan(_ path: String, into scan: Scan) {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else {
            lock.lock()
            scan.status = "missing"
            lock.unlock()
            return
        }
        // Packages such as a Photos library are skipped whole.
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Folders.keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var found: [(url: URL, values: URLResourceValues)] = []
        while let url = walk?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(Folders.keys)), values.isRegularFile == true,
                let type = values.contentType, type.conforms(to: .movie) || type.conforms(to: .image)
            else { continue }
            found.append((url, values))
        }
        found.sort { ($0.values.fileSize ?? 0) > ($1.values.fileSize ?? 0) }
        var fresh: [String: Item] = [:]
        for entry in found { if let item = Folders.makeItem(entry.url, entry.values, probe: false) { fresh[item.id] = item } }
        lock.lock()
        scan.total = found.count
        scan.scanned = 0
        scan.items = fresh
        lock.unlock()
        for entry in found {
            autoreleasepool {
                if let item = Folders.makeItem(entry.url, entry.values, probe: true) {
                    lock.lock()
                    if scan.items[item.id] != nil { scan.items[item.id] = item }
                    scan.scanned += 1
                    lock.unlock()
                }
            }
        }
        lock.lock()
        scan.status = "ready"
        scan.scanned = scan.total
        scan.measuredAt = Date()
        lock.unlock()
        log("folder \(Folders.place(path)): \(found.count) photos and videos")
    }

    /// A file in the cloud only, not on this Mac: Google Drive for desktop shows it, but opening it downloads it.
    static func isCloudOnly(_ values: URLResourceValues) -> Bool {
        if let status = values.ubiquitousItemDownloadingStatus { return status == .notDownloaded }
        return (values.totalFileAllocatedSize ?? 1) == 0 && (values.fileSize ?? 0) > 0
    }

    private static let exifDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    /// The item for a photo or video file. With `probe`, the file is opened for its size in pixels, length and the
    /// date it was taken; without, those wait, and the file's own dates stand in.
    static func makeItem(_ url: URL, _ values: URLResourceValues, probe: Bool) -> Item? {
        guard let type = values.contentType, type.conforms(to: .movie) || type.conforms(to: .image) else { return nil }
        let isVideo = type.conforms(to: .movie)
        let cloud = isCloudOnly(values)
        var width = 0, height = 0, duration = 0.0
        var taken: Date?
        if probe && !cloud {
            if isVideo {
                let asset = AVURLAsset(url: url)
                let seconds = asset.duration.seconds
                duration = seconds.isFinite ? seconds : 0
                if let track = asset.tracks(withMediaType: .video).first {
                    let shown = track.naturalSize.applying(track.preferredTransform)
                    width = Int(abs(shown.width).rounded())
                    height = Int(abs(shown.height).rounded())
                }
                taken = asset.creationDate?.dateValue
            } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            {
                width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
                height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
                // Turned a quarter, the photo is shown the other way round.
                if let orientation = properties[kCGImagePropertyOrientation as String] as? Int, (5...8).contains(orientation) {
                    swap(&width, &height)
                }
                let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
                taken = (exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap(exifDate.date(from:))
            }
        }
        let isRaw = !isVideo && type.conforms(to: .rawImage)
        var tags: [String] = []
        if isRaw { tags.append("RAW") }
        if cloud { tags.append("in the cloud") }
        var date = "", year = 0
        if let when = taken ?? values.creationDate ?? values.contentModificationDate {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: when)
            year = parts.year ?? 0
            date = String(format: "%04d-%02d-%02d", year, parts.month ?? 0, parts.day ?? 0)
        }
        return Item(
            id: id(url), name: url.lastPathComponent, bytes: Int64(values.fileSize ?? 0), date: date, year: year, isVideo: isVideo,
            isRaw: isRaw, isLive: false, isJPEG: !isVideo && type.conforms(to: .jpeg), motionBytes: 0, width: width, height: height,
            duration: duration, favorite: false, tags: tags)
    }

    func item(_ id: String) -> Item? {
        lock.lock()
        defer { lock.unlock() }
        for scan in scans.values { if let item = scan.items[id] { return item } }
        return nil
    }

    /// The added folder a file is in, the innermost if folders sit inside each other.
    func folder(containing url: URL) -> Folder? {
        let path = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        return folders.filter { path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    /// The items of one added folder, a page at a time, like the Photos library's.
    func query(folder path: String, kind: String, year: Int?, minBytes: Int64, offset: Int, limit: Int) -> [String: Any] {
        let path = Folders.normal(path)
        // Only folders on the list are looked into.
        lock.lock()
        let listed = folders.contains { $0.path == path }
        lock.unlock()
        guard listed else {
            let none: [String: Any] = ["status": "missing", "scanned": 0, "total": 0, "measuredAt": NSNull()]
            return none.merging(Library.listing([], kind: kind, year: year, minBytes: minBytes, offset: offset, limit: limit)) { $1 }
        }
        let scan = scanIfNeeded(path)
        lock.lock()
        let all = Array(scan.items.values)
        var result: [String: Any] = ["status": scan.status, "scanned": scan.scanned, "total": scan.total]
        result["measuredAt"] = scan.measuredAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
        lock.unlock()
        return result.merging(Library.listing(all, kind: kind, year: year, minBytes: minBytes, offset: offset, limit: limit)) { $1 }
    }

    /// Adds a file the app has just written, such as a smaller copy, to its folder's list, or refreshes one that has
    /// changed, such as a file just downloaded from Google Drive. Returns its item.
    @discardableResult
    func addFile(_ url: URL) -> Item? {
        guard let values = try? url.resourceValues(forKeys: Set(Folders.keys)), let item = Folders.makeItem(url, values, probe: true),
            let folder = folder(containing: url)
        else { return nil }
        lock.lock()
        scans[folder.path]?.items[item.id] = item
        lock.unlock()
        return item
    }

    /// Of these file ids, the ones whose files have gone, which are also dropped from the lists.
    @discardableResult
    func forget(missingAmong ids: [String]) -> Set<String> {
        let missing = Set(ids.filter { id in Folders.url(id).map { !FileManager.default.fileExists(atPath: $0.path) } ?? false })
        guard !missing.isEmpty else { return [] }
        lock.lock()
        for scan in scans.values { for id in missing { scan.items[id] = nil } }
        lock.unlock()
        return missing
    }

    /// What would show that a file changed after it was copied: its size and when it was last changed.
    static func fingerprint(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return "\(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    /// A picture of the file, the same as Finder shows. For a file only in the cloud this may be Google's own.
    func thumbnail(id: String, size: Int, completion: @escaping (Data?) -> Void) {
        // Only for photos and videos in added folders, not just any file on the Mac.
        guard item(id) != nil, let url = Folders.url(id), FileManager.default.fileExists(atPath: url.path) else { return completion(nil) }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size), scale: 1, representationTypes: [.thumbnail, .lowQualityThumbnail])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { picture, _ in
            guard let image = picture?.cgImage else { return completion(nil) }
            completion(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        }
    }

    /// Moves files to the Trash after asking, since Photos' own confirmation doesn't cover them. In Google Drive the
    /// files go to Drive's trash as well.
    func trash(ids: [String], completion: @escaping (Bool, String?) -> Void) {
        let urls = ids.compactMap(Folders.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return completion(false, "Those files are no longer there.") }
        let bytes = urls.reduce(Int64(0)) { sum, url in
            sum + (item(Folders.id(url))?.bytes ?? Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
        }
        func go() {
            var failed: [String] = []
            for url in urls {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    failed.append(url.lastPathComponent)
                    log("couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)")
                }
            }
            forget(missingAmong: urls.map(Folders.id))
            if failed.isEmpty { return completion(true, nil) }
            completion(failed.count < urls.count, "Couldn't move \(failed.count == 1 ? failed[0] : "\(failed.count) files") to the Trash.")
        }
        if let root = trashWithoutAsking, urls.allSatisfy({ $0.standardizedFileURL.path.hasPrefix(root + "/") }) {
            return DispatchQueue.global().async { go() }
        }
        DispatchQueue.main.async {
            let previous = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            // Files in Google Drive don't show in this Mac's Trash: Google Drive keeps them in its own trash.
            let one = urls.count == 1, drive = urls.filter { Folders.inDrive($0.path) }.count
            let bin = drive == urls.count ? "Google Drive's trash" : "the Trash"
            let alert = NSAlert()
            alert.messageText = one ? "Move “\(urls[0].lastPathComponent)” to \(bin)?" : "Move \(urls.count) files to \(bin)?"
            alert.informativeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + ". "
                + (drive == urls.count ? "You can restore \(one ? "it" : "them") from Google Drive's trash for 30 days."
                    : "You can put \(one ? "it" : "them") back from the Trash until it's emptied."
                    + (drive > 0 ? " Files from Google Drive go to Google Drive's trash instead, where you can restore them for 30 days." : ""))
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            let answer = alert.runModal()
            if let previous = previous, previous != NSRunningApplication.current, !previous.isTerminated {
                if #available(macOS 14.0, *) { NSApp.yieldActivation(to: previous) }
                previous.activate(options: [])
            }
            guard answer == .alertFirstButtonReturn else { return completion(false, "Cancelled. Nothing was moved to the Trash.") }
            DispatchQueue.global().async { go() }
        }
    }
}

// MARK: - History

/// A permanent record of shrink attempts and deletions: one JSON object per line, so it survives restarts
/// and stays readable. Lives in ~/Library/Application Support/Photo Review unless `--history FILE` is given.
final class History {
    private let lock = NSLock()
    private let file: URL
    private var events: [[String: Any]] = []
    private let clock = ISO8601DateFormatter()

    init() {
        file = dataFile("history.jsonl", flag: "--history")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            if let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] {
                events.append(event)
            }
        }
    }

    func record(_ event: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        var event = event
        event["time"] = clock.string(from: Date())
        events.append(event)
        guard var line = try? JSONSerialization.data(withJSONObject: event) else { return }
        line.append(Data("\n".utf8))
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }

    func all() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// For every video that has been shrunk, the id of its latest smaller copy (original id -> copy id).
    func copies() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var copies: [String: String] = [:]
        for event in events where event["type"] as? String == "shrink" && event["outcome"] as? String == "done" {
            if let original = event["assetId"] as? String, let copy = event["newId"] as? String, !copy.isEmpty {
                copies[original] = copy
            }
        }
        return copies
    }

    /// For every smaller copy this app has made, the size of the original it came from (copy id -> bytes).
    func origins() -> [String: Int64] {
        lock.lock()
        defer { lock.unlock() }
        var origins: [String: Int64] = [:]
        for event in events where event["type"] as? String == "shrink" && event["outcome"] as? String == "done" {
            if let copy = event["newId"] as? String, !copy.isEmpty, let bytes = (event["originalBytes"] as? NSNumber)?.int64Value {
                origins[copy] = bytes
            }
        }
        return origins
    }
}

// MARK: - Shrinking

struct ShrinkSettings {
    /// Cap on the smaller dimension in pixels; nil keeps the original size.
    let shortSide: Int?
    /// Cap on frames per second; nil keeps the original rate.
    let fps: Double?
    let hevc: Bool
    let quality: String

    /// The same choices in the form the page sends them, so a failed job can be started again.
    var json: [String: String] {
        [
            "resolution": shortSide.map(String.init) ?? "keep", "fps": fps.map { String(Int($0)) } ?? "keep",
            "codec": hevc ? "hevc" : "h264", "quality": quality,
        ]
    }

    init(_ payload: [String: Any]) {
        // Anything outside the offered choices falls back to the gentlest option rather than reaching the encoder.
        let resolution = Int(payload["resolution"] as? String ?? "") ?? 0
        shortSide = [2160, 1080, 720].contains(resolution) ? resolution : nil
        let rate = Double(payload["fps"] as? String ?? "") ?? 0
        fps = [24, 30].contains(rate) ? rate : nil
        hevc = (payload["codec"] as? String) != "h264"
        let level = payload["quality"] as? String ?? ""
        quality = ["high", "medium", "low"].contains(level) ? level : "high"
    }

    func size(width: Int, height: Int) -> (width: Int, height: Int) {
        let short = min(width, height)
        guard let cap = shortSide, short > cap else { return (width, height) }
        let scale = Double(cap) / Double(short)
        return (Int((Double(width) * scale / 2).rounded()) * 2, Int((Double(height) * scale / 2).rounded()) * 2)
    }

    /// HEIC compression for RAW photos. On test RAWs from four cameras these came to roughly 13-45%,
    /// 6-25% and 4-19% of the RAW file; index.html uses the same ranges for its estimate.
    var photoQuality: Double { quality == "low" ? 0.6 : quality == "medium" ? 0.75 : 0.9 }

    /// HEIC compression for JPEG photos and the JPEG stills of Live Photos. index.html estimates the sizes.
    var jpegQuality: Double { quality == "low" ? 0.5 : quality == "medium" ? 0.65 : 0.8 }

    /// Target video bitrate in bits per second. index.html mirrors this for its estimate.
    /// `hevc` is the format the copy will really be in, which is HEVC for HDR and 10-bit video whatever was chosen.
    func bitrate(width: Int, height: Int, fps: Double, hevc: Bool? = nil) -> Double {
        let base = quality == "low" ? 6e6 : quality == "medium" ? 12e6 : 24e6  // HEVC at 4K, 30 fps
        let pixels = Double(width * height) / (3840 * 2160)
        return base * pow(pixels, 0.75) * pow(max(fps, 1) / 30, 0.6) * (hevc ?? self.hevc ? 1 : 1.7)
    }
}

struct ShrinkError: LocalizedError {
    let state: String  // failed, skipped or cancelled
    let message: String
    var errorDescription: String? { message }

    static func failed(_ message: String) -> ShrinkError { ShrinkError(state: "failed", message: message) }
    static let cancelled = ShrinkError(state: "cancelled", message: "Cancelled.")
    static let nothingToGain = ShrinkError(
        state: "skipped", message: "Already at or below this quality, so re-encoding wouldn't save space.")
}

/// Re-encodes the video track of `asset` into a QuickTime file at `url`, keeping its audio and metadata.
func encode(
    _ asset: AVAsset, audioMix: AVAudioMix? = nil, to url: URL, settings: ShrinkSettings,
    isCancelled: @escaping () -> Bool, progress: @escaping (Double) -> Void
) throws {
    guard let videoTrack = asset.tracks(withMediaType: .video).first else { throw ShrinkError.failed("This item has no video track.") }
    let sourceFps = videoTrack.nominalFrameRate > 0 ? Double(videoTrack.nominalFrameRate) : 30
    let targetFps = min(settings.fps ?? sourceFps, sourceFps)
    let target = settings.size(width: Int(videoTrack.naturalSize.width), height: Int(videoTrack.naturalSize.height))

    let format = videoTrack.formatDescriptions.first.map { $0 as! CMFormatDescription }
    func tag(_ key: CFString) -> String? {
        format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: key) as? String }
    }
    let primaries = tag(kCMFormatDescriptionExtension_ColorPrimaries)
    let transfer = tag(kCMFormatDescriptionExtension_TransferFunction)
    let matrix = tag(kCMFormatDescriptionExtension_YCbCrMatrix)
    let hdr = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
    // ProRes and other 10-bit originals keep their extra precision, as HDR must. H.264 here is 8-bit
    // only and would flatten them, so these are saved as 10-bit HEVC whatever format was chosen.
    let depth = format.flatMap {
        (CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
    }
    let proRes = [
        kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
        kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
    ].contains(format.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0)
    let tenBit = hdr || (depth ?? 8) > 8 || proRes
    let hevc = settings.hevc || tenBit
    let bitrate = settings.bitrate(width: target.width, height: target.height, fps: targetFps, hevc: hevc)
    let sourceRate = Double(videoTrack.estimatedDataRate)
    if sourceRate > 0, bitrate > sourceRate * 0.8 { throw ShrinkError.nothingToGain }

    let reader = try AVAssetReader(asset: asset)
    let pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let videoOutput = AVAssetReaderTrackOutput(
        track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else { throw ShrinkError.failed("This video can't be decoded on this Mac.") }
    reader.add(videoOutput)

    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    // Embedded cover art would be written as a second video track.
    writer.metadata = asset.metadata.filter { $0.commonKey != .commonKeyArtwork }
    writer.shouldOptimizeForNetworkUse = true

    let profile: String =
        hevc
        ? (tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String
        : AVVideoProfileLevelH264HighAutoLevel
    var video: [String: Any] = [
        AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
        AVVideoWidthKey: target.width,
        AVVideoHeightKey: target.height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: Int(targetFps.rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoProfileLevelKey: profile,
        ] as [String: Any],
    ]
    if let primaries = primaries, let transfer = transfer, let matrix = matrix {
        var tagged = video
        tagged[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix,
        ]
        if writer.canApply(outputSettings: tagged, forMediaType: .video) { video = tagged }
    }
    guard writer.canApply(outputSettings: video, forMediaType: .video) else {
        throw ShrinkError.failed("This Mac can't encode that size and format combination.")
    }
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
    videoInput.transform = videoTrack.preferredTransform
    videoInput.expectsMediaDataInRealTime = false
    writer.add(videoInput)

    var tracks: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)] = [(videoOutput, videoInput)]
    let audioTracks = asset.tracks(withMediaType: .audio)
    if asset is AVComposition || audioMix != nil {
        // Photos hands back slo-mo and other retimed videos as a composition. Their sound has to be rendered
        // to follow the picture; copied as-is it plays in bursts and ends early.
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                tracks.append((output, input))
            }
        }
    } else {
        for track in audioTracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let hint = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { continue }
            reader.add(output)
            writer.add(input)
            tracks.append((output, input))
        }
    }

    guard reader.startReading() else { throw reader.error ?? ShrinkError.failed("Couldn't read the video.") }
    guard writer.startWriting() else { throw writer.error ?? ShrinkError.failed("Couldn't start encoding.") }
    writer.startSession(atSourceTime: .zero)

    let duration = max(asset.duration.seconds, 0.001)
    // When lowering the frame rate, keep one frame per `step` seconds and drop the rest.
    let step = targetFps < sourceFps - 1 ? 1 / targetFps : 0
    var nextKeep = 0.0
    let finished = DispatchGroup()
    for (index, track) in tracks.enumerated() {
        finished.enter()
        var done = false
        track.input.requestMediaDataWhenReady(on: DispatchQueue(label: "shrink.track\(index)")) {
            if done { return }
            while track.input.isReadyForMoreMediaData {
                guard !isCancelled(), let sample = track.output.copyNextSampleBuffer() else {
                    done = true
                    track.input.markAsFinished()
                    return finished.leave()
                }
                if index == 0 {
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if step > 0 {
                        if time < nextKeep - 0.002 { continue }
                        nextKeep = max(nextKeep + step, time + step / 2)
                    }
                    progress(min(max(time / duration, 0), 1))
                }
                if !track.input.append(sample) {
                    done = true
                    reader.cancelReading()
                    track.input.markAsFinished()
                    return finished.leave()
                }
            }
        }
    }
    // A writer that has failed stops asking for data, so its tracks would never report finishing.
    while finished.wait(timeout: .now() + 0.25) == .timedOut {
        if writer.status == .failed || reader.status == .failed || isCancelled() { break }
    }

    if isCancelled() {
        reader.cancelReading()
        writer.cancelWriting()
        throw ShrinkError.cancelled
    }
    if reader.status == .failed {
        writer.cancelWriting()
        throw reader.error ?? ShrinkError.failed("Couldn't read the video.")
    }
    if writer.status == .failed {
        reader.cancelReading()
        throw writer.error ?? ShrinkError.failed("Encoding failed.")
    }
    let written = DispatchSemaphore(value: 0)
    writer.finishWriting { written.signal() }
    written.wait()
    guard writer.status == .completed else { throw writer.error ?? ShrinkError.failed("Encoding failed.") }
}

/// Develops a camera RAW file the way Photos shows it by default and saves it at `url` as a 10-bit HEIC in
/// Display P3, carrying over the file's own camera data (dates, camera, lens, GPS).
func developRAW(_ file: URL, to url: URL, settings: ShrinkSettings) throws {
    guard let filter = CIRAWFilter(imageURL: file) else { throw ShrinkError.failed("This Mac can't read this RAW format.") }
    // A smaller size is made while developing, which is quicker and sharper than scaling the result.
    let native = filter.nativeSize
    if let cap = settings.shortSide, min(native.width, native.height) > CGFloat(cap) {
        filter.scaleFactor = Float(CGFloat(cap) / min(native.width, native.height))
    }
    guard let developed = filter.outputImage else { throw ShrinkError.failed("This RAW file couldn't be developed.") }
    var properties = developed.properties
    if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
        let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    {
        let carried = [
            kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary,
            kCGImagePropertyExifAuxDictionary, kCGImagePropertyIPTCDictionary,
        ]
        for key in carried as [String] { if let value = original[key] { properties[key] = value } }
    }
    // The developed picture is already upright, and may be smaller than the RAW, so the copy says so.
    properties[kCGImagePropertyOrientation as String] = 1
    if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
    }
    if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
        exif[kCGImagePropertyExifPixelXDimension as String] = Int(developed.extent.width)
        exif[kCGImagePropertyExifPixelYDimension as String] = Int(developed.extent.height)
        properties[kCGImagePropertyExifDictionary as String] = exif
    }
    let image = developed.settingProperties(properties)
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!])
    try? FileManager.default.removeItem(at: url)
    let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
    try context.writeHEIF10Representation(
        of: image, to: url, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, options: [quality: settings.photoQuality])
}

/// Free space on the drive that holds `url`, or nil if it can't be read. The startup disk counts the space macOS can
/// make by clearing caches and the like; other drives say 0 for that, so their plain free space is the figure to use.
func freeSpace(at url: URL) -> Int64? {
    let space = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    let important = space?.volumeAvailableCapacityForImportantUsage ?? 0
    return important > 0 ? important : space?.volumeAvailableCapacity.map { Int64($0) }
}

/// Saves the picture in an image file's data as a HEIC at `url`, carrying over its metadata, its HDR gain map and,
/// at full size, the depth data behind Portrait effects. Used for JPEG photos, which come out at about half the size.
/// `settings` gives the quality and any cap on the size; `orientation` replaces the file's own when Photos shows
/// the photo turned another way.
func convertToHEIC(_ data: Data, to url: URL, settings: ShrinkSettings, orientation: CGImagePropertyOrientation? = nil) throws {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
        throw ShrinkError.failed("This photo couldn't be read.")
    }
    try? FileManager.default.removeItem(at: url)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
        throw ShrinkError.failed("This Mac can't save HEIC photos.")
    }
    var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: settings.jpegQuality]
    // Most iPhone photos have one, and without it they look flatter on a screen that can show HDR.
    if #available(macOS 14.1, *) { options[kCGImageDestinationPreserveGainMap] = true }
    if let orientation = orientation { options[kCGImagePropertyOrientation] = orientation.rawValue }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
    let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
    let scaled = settings.shortSide.map { min(width, height) > $0 } ?? false
    if scaled, let cap = settings.shortSide {
        // Scaled as it's written, gain map included; the orientation tag still applies, and only the size changes.
        let longSide = Int((Double(max(width, height)) * Double(cap) / Double(min(width, height))).rounded())
        let scale = Double(longSide) / Double(max(width, height))
        options[kCGImageDestinationImageMaxPixelSize] = longSide
        options[kCGImagePropertyExifDictionary] = [
            kCGImagePropertyExifPixelXDimension: Int((Double(width) * scale).rounded()),
            kCGImagePropertyExifPixelYDimension: Int((Double(height) * scale).rounded()),
        ]
    }
    CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
    // Depth and mattes only line up with the picture at its own size.
    if !scaled {
        var kinds = [
            kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypePortraitEffectsMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
        ]
        if #available(macOS 14.1, *) {
            kinds += [kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte]
        }
        for kind in kinds {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kind) { CGImageDestinationAddAuxiliaryDataInfo(destination, kind, info) }
        }
    }
    guard CGImageDestinationFinalize(destination) else { throw ShrinkError.failed("Couldn't save the HEIC copy.") }
}

/// Whether Photo Review may control Photos, which copying titles, captions and keywords needs; macOS asks once. The app
/// asks when a queue starts, so the question comes while someone is at the Mac rather than when the first copy is
/// saved, which for a large video can be an hour later. If it goes unanswered, one copy in the queue waits for it and
/// the rest go ahead without their details, picking up again as soon as it's answered.
final class PhotosControl {
    enum Answer: String { case allowed, refused, undecided, unavailable }
    private let lock = NSLock()
    /// Open while macOS is asking.
    private var question: DispatchGroup?
    /// A copy in the current queue has already waited for an answer.
    private var waited = false
    private let check: (_ prompt: Bool) -> Answer
    private let patience: Double

    /// `check` and `patience` (seconds) can be replaced for testing.
    init(check: @escaping (_ prompt: Bool) -> Answer = PhotosControl.ask, patience: Double = 90) {
        self.check = check
        self.patience = patience
    }

    /// When a queue starts: asks now if macOS hasn't been told yet, without waiting for the answer.
    func queueStarted() {
        lock.lock()
        waited = false
        lock.unlock()
        _ = openQuestion()
    }

    /// What to go by before copying an item's details.
    func answerForCopy() -> Answer {
        let now = check(false)
        guard now == .undecided else { return now }
        lock.lock()
        let first = !waited
        waited = true
        lock.unlock()
        guard first else { return now }
        _ = openQuestion().wait(timeout: .now() + patience)
        return check(false)
    }

    /// The question macOS is asking, starting it if it isn't already.
    private func openQuestion() -> DispatchGroup {
        lock.lock()
        defer { lock.unlock() }
        if let open = question { return open }
        let open = DispatchGroup()
        open.enter()
        question = open
        // It doesn't return until the question is answered, so not on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = self.check(true)
            log("controlling Photos: \(answer.rawValue)")
            self.lock.lock()
            self.question = nil
            self.lock.unlock()
            open.leave()
        }
        return open
    }

    static var photosIsOpen: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Photos").contains { $0.isFinishedLaunching }
    }

    /// Asks macOS, putting the question to the person if `prompt` and nothing has been decided yet. macOS only answers
    /// about a running app, so Photos is opened first if it isn't, hidden and without coming to the front.
    static func ask(prompt: Bool) -> Answer {
        if !photosIsOpen, let photos = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: photos, configuration: configuration)
            var waited = 0.0
            while !photosIsOpen && waited < 15 {
                Thread.sleep(forTimeInterval: 0.25)
                waited += 0.25
            }
        }
        var target = AEAddressDesc()
        let bundle = "com.apple.Photos"
        guard bundle.withCString({ AECreateDesc(DescType(typeApplicationBundleID), $0, bundle.utf8.count, &target) }) == noErr else {
            return .unavailable
        }
        defer { AEDisposeDesc(&target) }
        switch Int(AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), prompt)) {
        case Int(noErr): return .allowed
        case errAEEventNotPermitted: return .refused
        case procNotFound: return .unavailable
        default: return .undecided
        }
    }
}

let photosControl = PhotosControl()

/// Photos keeps titles, captions and keywords where PhotoKit can't reach them, so they're copied to the new item
/// through Photos' scripting, which opens Photos if it isn't running. Returns nil when that worked or there was
/// nothing to copy, otherwise a short note for the page.
func copyDetails(from original: String, to copy: String) -> String? {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-/"))
    guard [original, copy].allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
    // Asked first, so a question nobody has answered holds up one copy in a queue rather than each one in turn.
    switch photosControl.answerForCopy() {
    case .allowed: break
    case .refused:
        return "Titles, captions and keywords weren't copied: allow Photo Review to control Photos in System Settings > Privacy & Security > Automation."
    case .undecided:
        return "Titles, captions and keywords weren't copied: macOS is still waiting for an answer about letting Photo Review control Photos."
    case .unavailable:
        return "Titles, captions and keywords weren't copied: Photos couldn't be opened."
    }
    let script = """
        tell application "Photos"
            set sourceItem to media item id "\(original)"
            set copyItem to media item id "\(copy)"
            set itemTitle to name of sourceItem
            if itemTitle is not missing value and itemTitle is not "" then set name of copyItem to itemTitle
            set itemCaption to description of sourceItem
            if itemCaption is not missing value and itemCaption is not "" then set description of copyItem to itemCaption
            set itemKeywords to keywords of sourceItem
            if itemKeywords is not missing value and itemKeywords is not {} then set keywords of copyItem to itemKeywords
        end tell
        """
    for attempt in 1...6 {
        let (status, errors) = runAppleScript(script, timeout: 90)
        if status == 0 { return nil }
        // A brand-new item can take a moment to show up in Photos' scripting.
        if errors.contains("-1728"), attempt < 6 {
            Thread.sleep(forTimeInterval: 2)
            continue
        }
        log("copying details to \(copy) failed: \(errors)")
        if errors.contains("-1743") {
            return "Titles, captions and keywords weren't copied: allow Photo Review to control Photos in System Settings > Privacy & Security > Automation."
        }
        return "Titles, captions and keywords couldn't be copied (" + errors.trimmingCharacters(in: .whitespacesAndNewlines).suffix(120) + ")."
    }
    return "Titles, captions and keywords weren't copied: Photos didn't find the new copy in time."
}

/// Runs AppleScript in a separate osascript process, so a slow Photos, or a permission prompt nobody has
/// answered, can't hold the app up. Gives up after `timeout` seconds. Returns the exit status and any errors.
func runAppleScript(_ source: String, timeout: Double) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
        try process.run()
    } catch {
        return (-1, error.localizedDescription)
    }
    // Read while it runs, so a long error message can't fill the pipe and stall the script.
    var text = Data()
    let read = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        text = errors.fileHandleForReading.readDataToEndOfFile()
        read.signal()
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        // Make sure it has gone before the job moves on.
        if finished.wait(timeout: .now() + 3) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 3)
        }
        return (-2, "Photos didn't answer in time")
    }
    guard read.wait(timeout: .now() + 5) == .success else { return (process.terminationStatus, "") }
    return (process.terminationStatus, String(data: text, encoding: .utf8) ?? "")
}

/// Writes the pieces of a file PhotoKit hands over. Once a write has failed, or the file has been finished or
/// abandoned, any further pieces are dropped rather than written to a closed file, and a failed write is
/// reported instead of stopping the app.
final class Sink {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var error: Error?

    init(_ handle: FileHandle) { self.handle = handle }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = handle, error == nil else { return }
        do { try handle.write(contentsOf: data) } catch { self.error = error }
    }

    /// The first write that failed, if any.
    var problem: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    /// Makes sure everything has reached the disk, then closes the file. Returns what went wrong, if anything.
    func finish() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = handle else { return error }
        self.handle = nil
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            self.error = self.error ?? error
        }
        return self.error
    }

    /// Closes the file without checking it, for a copy that is being abandoned.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}

final class Job {
    let id: Int
    let assetId: String
    let name: String
    let originalBytes: Int64
    let original: Item
    /// What the job does: "video" re-encodes a video, "photo" makes a HEIC copy of a RAW or JPEG photo or of a
    /// Live Photo's still, and "archive" copies the item's files into a folder and then deletes it.
    let kind: String
    var isPhoto: Bool { kind == "photo" }
    var isArchive: Bool { kind == "archive" }
    /// A file in an added folder rather than an item in Photos.
    var isFile: Bool { Folders.isFile(assetId) }
    /// For an archive job, the folder the files go into.
    let folder: URL?
    let settings: ShrinkSettings
    /// Encode only and leave the file in the temporary folder, without touching the library. For an archive
    /// job, copy the files but keep the original.
    let dryRun: Bool
    /// Ask Photos to delete the original once the smaller copy is safely in the library.
    let deleteOriginal: Bool
    /// What became of that request: "" (not asked for), pending, deleted or kept.
    var deletion = ""
    var state = "queued"  // queued, downloading, encoding, saving, done, skipped, failed, cancelled
    var progress = 0.0
    var message = ""
    /// Something worth knowing about a finished job that isn't a failure, such as captions that weren't copied.
    var note = ""
    var newBytes: Int64 = 0
    var newItem: Item?
    /// The files an archive job wrote, and their sizes, which are checked again just before the original is deleted.
    var files: [String] = []
    var fileSizes: [Int64] = []
    /// What the original looked like when it was copied (see `Converter.fingerprint`). If it has changed by the
    /// time the queue is done, the copy is out of date and the original is kept.
    var source: String?
    /// What a photo's copy is: "raw" for one developed from a RAW file, "heic" for a JPEG turned into a HEIC,
    /// "still" for a Live Photo's HEIC still kept as it was. For the history.
    var made = ""
    var cancelled = false
    var originalDeleted = false
    /// The smaller copy this job made has since been deleted, so the video counts as not shrunk again.
    var copyDeleted = false
    /// When the job entered its current state, for the page's elapsed time and estimate.
    var stateSince = Date()
    /// Seconds spent in each state so far.
    var phases: [String: Double] = [:]
    /// Where the download bar stood when it first moved in this attempt, and when. Photos picks up a
    /// dropped download where it left off, so speed has to be measured from here rather than from zero.
    var paceFrom: (progress: Double, time: Date)?

    /// Seconds the download still needs at the pace seen so far, or nil while that isn't known.
    var remainingSeconds: Int? {
        guard state == "downloading", let start = paceFrom, progress > start.progress else { return nil }
        let pace = Date().timeIntervalSince(start.time) / (progress - start.progress)
        return Int(pace * (1 - progress))
    }

    /// What the history keeps about this attempt once it has ended.
    var record: [String: Any] {
        if isArchive {
            return [
                "type": "archive", "outcome": state, "message": message, "assetId": assetId, "name": name,
                "bytes": originalBytes, "video": original.isVideo, "folder": folder?.path ?? "", "files": files,
                "downloadSeconds": Int(phases["downloading"] ?? 0),
            ]
        }
        return [
            "type": "shrink", "kind": kind, "made": made, "outcome": state, "message": message,
            "assetId": assetId, "name": name, "originalBytes": originalBytes, "newBytes": newBytes, "newId": newItem?.id ?? "",
            "settings": settings.json, "downloadSeconds": Int(phases["downloading"] ?? 0),
            "encodeSeconds": Int(phases["encoding"] ?? 0),
        ]
    }

    init(id: Int, item: Item, settings: ShrinkSettings, dryRun: Bool, deleteOriginal: Bool, folder: URL? = nil) {
        self.id = id
        self.deleteOriginal = deleteOriginal && !dryRun
        assetId = item.id
        name = item.name
        originalBytes = item.bytes
        original = item
        kind = folder != nil ? "archive" : item.isVideo ? "video" : "photo"
        self.folder = folder
        self.settings = settings
        self.dryRun = dryRun
    }

    // A switch rather than a list, since a long queue asks this of every job many times over.
    var isActive: Bool {
        switch state {
        case "queued", "downloading", "encoding", "saving": return true
        default: return false
        }
    }

    var json: [String: Any] {
        [
            "id": id, "assetId": assetId, "name": name, "kind": kind, "state": state,
            "progress": progress, "message": message, "note": note,
            "originalBytes": originalBytes, "newBytes": newBytes, "newItem": newItem?.json ?? NSNull(),
            "item": original.json, "dryRun": dryRun, "settings": settings.json, "originalDeleted": originalDeleted, "copyDeleted": copyDeleted,
            "seconds": Int(Date().timeIntervalSince(stateSince)), "remaining": remainingSeconds ?? NSNull(),
            "deleteOriginal": deleteOriginal, "deletion": deletion, "folder": folder?.path ?? NSNull(), "files": files.count,
            "file": isFile, "drive": isFile && Folders.inDrive(Folders.url(assetId)?.path ?? ""),
        ]
    }
}

/// Runs shrink jobs one at a time.
final class Converter {
    private let library: Library
    private let folders: Folders
    private let history: History
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "shrink", qos: .userInitiated)
    private var jobs: [Job] = []
    private var nextId = 1
    /// Finished jobs whose originals are to be deleted once nothing else is running.
    private var awaitingDeletion: [Job] = []
    /// Jobs added since the queue was last empty, for the summary once it is empty again.
    private var currentRun: [Job] = []
    /// An update of the Dock badge is on its way (guarded by `lock`), and the number it last showed (main thread).
    private var badgeScheduled = false
    private var shownCount = 0
    /// Told on the main thread how many jobs are still to do whenever that changes, for the Dock badge.
    var onActiveCount: ((Int) -> Void)?
    /// Told on the main thread once the queue has run dry: the jobs that ended since it last did, and how many
    /// originals are now waiting for the deletion confirmation. For the notification.
    var onFinished: ((_ ended: [Job], _ awaitingConfirmation: Int) -> Void)?

    init(library: Library, folders: Folders, history: History) {
        self.library = library
        self.folders = folders
        self.history = history
    }

    /// `deleteOriginal` applies to every item in the request; `deleteOriginalIds` names the ones picked for it
    /// one by one. Either is enough for an original to be deleted after its compression.
    func enqueue(ids: [String], settings: ShrinkSettings, dryRun: Bool, deleteOriginal: Bool, deleteOriginalIds: Set<String> = []) -> Int {
        add(ids.compactMap { library.item($0) ?? folders.item($0) }.filter { $0.isCompressible }) { id, item in
            Job(id: id, item: item, settings: settings, dryRun: dryRun, deleteOriginal: deleteOriginal || deleteOriginalIds.contains(item.id))
        }
    }

    /// Copies each item's files into `folder`, then deletes the item once the queue is done, after one
    /// confirmation for all of them. A test run copies the files and keeps the items.
    func enqueueArchive(ids: [String], folder: URL, dryRun: Bool) -> Int {
        add(ids.compactMap { library.item($0) }) { id, item in
            Job(id: id, item: item, settings: ShrinkSettings([:]), dryRun: dryRun, deleteOriginal: true, folder: folder)
        }
    }

    /// Queues the job `make` builds for each item that hasn't one running already, and returns how many were
    /// queued. A fresh attempt replaces the rows left by earlier ones that didn't finish. It's all done in one
    /// pass, since picking many at once can mean thousands of items.
    private func add(_ items: [Item], _ make: (Int, Item) -> Job) -> Int {
        lock.lock()
        var busy = Set(jobs.lazy.filter { $0.isActive }.map { $0.assetId })
        var made: [Job] = []
        for item in items where !busy.contains(item.id) {
            busy.insert(item.id)  // the same item twice in one request is queued once
            made.append(make(nextId, item))
            nextId += 1
        }
        let fresh = Set(made.map { $0.assetId })
        jobs.removeAll { fresh.contains($0.assetId) && ["failed", "cancelled", "skipped"].contains($0.state) }
        jobs += made
        currentRun += made
        lock.unlock()
        for job in made { queue.async { self.run(job) } }
        reportActiveCount()
        return made.count
    }

    /// Tells the Dock badge how many jobs are left. A long queue changes all the time, so updates are gathered up
    /// and the count is taken when the update runs, which also keeps a late update from showing an old number.
    private func reportActiveCount() {
        lock.lock()
        let scheduled = badgeScheduled
        badgeScheduled = true
        lock.unlock()
        if scheduled { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.lock.lock()
            self.badgeScheduled = false
            let count = self.jobs.reduce(0) { $0 + ($1.isActive ? 1 : 0) }
            self.lock.unlock()
            guard count != self.shownCount else { return }
            self.shownCount = count
            self.onActiveCount?(count)
        }
    }

    func list() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return jobs.map { $0.json }
    }

    func cancel(_ id: Int) {
        update { jobs in
            guard let job = jobs.first(where: { $0.id == id && $0.isActive }) else { return }
            job.cancelled = true
            // A job still waiting its turn has nothing to stop, so show it as cancelled straight away
            // instead of leaving it looking untouched until the queue reaches it.
            if job.state == "queued" {
                job.state = "cancelled"
                job.message = "Cancelled."
            }
        }
        reportActiveCount()
    }

    var hasActiveJobs: Bool {
        lock.lock()
        defer { lock.unlock() }
        return jobs.contains { $0.isActive }
    }

    /// Deletes library items through Photos (which asks the user to confirm), or moves files in added folders to the
    /// Trash (after Photo Review asks), and records what was removed. Photos items go first when there are both.
    func delete(ids: [String], completion: @escaping (Bool, String?) -> Void) {
        let files = ids.filter(Folders.isFile), photos = ids.filter { !Folders.isFile($0) }
        guard !photos.isEmpty else { return trash(files, completion: completion) }
        deletePhotos(photos) { ok, error in
            guard !files.isEmpty else { return completion(ok, error) }
            self.trash(files) { trashed, problem in completion(ok && trashed, error ?? problem) }
        }
    }

    private func trash(_ ids: [String], completion: @escaping (Bool, String?) -> Void) {
        let doomed = ids.compactMap { folders.item($0) }
        folders.trash(ids: ids) { ok, error in
            let gone = ids.filter { id in Folders.url(id).map { !FileManager.default.fileExists(atPath: $0.path) } ?? false }
            if !gone.isEmpty {
                self.originalsDeleted(gone)
                self.history.record([
                    "type": "delete", "trash": true,
                    "items": doomed.filter { gone.contains($0.id) }.map { ["id": $0.id, "name": $0.name, "bytes": $0.bytes, "video": $0.isVideo] },
                ])
            }
            completion(ok, error)
        }
    }

    private func deletePhotos(_ ids: [String], completion: @escaping (Bool, String?) -> Void) {
        let doomed = ids.compactMap { library.item($0) }
        library.delete(ids: ids) { ok, error in
            if ok {
                self.originalsDeleted(ids)
                self.history.record([
                    "type": "delete",
                    "items": doomed.map { ["id": $0.id, "name": $0.name, "bytes": $0.bytes, "video": $0.isVideo] },
                ])
            }
            completion(ok, error)
        }
    }

    /// Once the queue has nothing left to do, asks Photos to delete the originals that were marked for it.
    /// One request for the whole batch means one confirmation, not one per video in the middle of a long run.
    private func deleteOriginalsIfIdle() {
        lock.lock()
        let idle = !jobs.contains { $0.isActive }
        let batch = idle ? awaitingDeletion : []
        let ended = idle ? currentRun : []
        if idle {
            awaitingDeletion = []
            currentRun = []
        }
        lock.unlock()
        // Hours can pass between a copy being checked and the end of the queue, so each one is checked again.
        var kept: [(job: Job, reason: String)] = []
        let ready = batch.filter { job in
            guard let reason = reasonToKeep(job) else { return true }
            kept.append((job, reason))
            return false
        }
        if !kept.isEmpty {
            update { _ in
                for entry in kept {
                    entry.job.deletion = "kept"
                    entry.job.message = entry.reason
                }
            }
            for entry in kept { log("job \(entry.job.id) \(entry.job.name): original kept: \(entry.reason)") }
        }
        if !ended.isEmpty { DispatchQueue.main.async { self.onFinished?(ended, ready.count) } }
        let photos = ready.filter { !$0.isFile }, files = ready.filter { $0.isFile }
        func trashFiles() {
            guard !files.isEmpty else { return }
            trash(files.map { $0.assetId }) { _, error in
                self.update { _ in
                    for job in files {
                        let gone = Folders.url(job.assetId).map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
                        job.deletion = gone ? "deleted" : "kept"
                        if !gone { job.message = error ?? "It wasn't moved to the Trash." }
                    }
                }
            }
        }
        guard !photos.isEmpty else { return trashFiles() }
        deletePhotos(photos.map { $0.assetId }) { ok, error in
            self.update { _ in
                for job in photos {
                    job.deletion = ok ? "deleted" : "kept"
                    if !ok { job.message = error ?? "Photos didn't delete it." }
                }
            }
            trashFiles()
        }
    }

    /// Why an original lined up for deletion should be kept after all, or nil if its copy still stands: the smaller
    /// copy or a copied file is gone, or the original has been changed since it was copied.
    private func reasonToKeep(_ job: Job) -> String? {
        if job.isFile {
            guard let url = Folders.url(job.assetId), FileManager.default.fileExists(atPath: url.path) else { return nil }
            if let source = job.source, Folders.fingerprint(url) != source { return "The original was changed after it was copied." }
            guard let copy = job.newItem.flatMap({ Folders.url($0.id) }), FileManager.default.fileExists(atPath: copy.path) else {
                return "The smaller copy is no longer in the folder."
            }
            return nil
        }
        // Already gone from Photos: there's nothing to keep, and the deletion passes over it.
        guard let asset = library.asset(job.assetId) else { return nil }
        if let source = job.source, Converter.fingerprint(asset) != source {
            return "The original was changed in Photos after it was copied."
        }
        if job.isArchive {
            for (path, size) in zip(job.files, job.fileSizes) {
                let now = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
                if now != size { return "\((path as NSString).lastPathComponent) is no longer in the folder as it was copied." }
            }
            return nil
        }
        guard let copy = job.newItem, library.asset(copy.id) != nil else { return "The smaller copy is no longer in Photos." }
        return nil
    }

    /// What would leave a copy out of date: the original's edits, date, place and favorite flag. Taken when an item
    /// is copied and again before its original is deleted.
    static func fingerprint(_ asset: PHAsset) -> String {
        let edits = PHAssetResource.assetResources(for: asset)
            .filter { [.adjustmentData, .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo].contains($0.type) }
            .map { "\($0.type.rawValue):\(resourceBytes($0, asset: asset).map(String.init) ?? "unknown")" }
            .sorted()
        let place = asset.location.map { String(format: "%.6f,%.6f", $0.coordinate.latitude, $0.coordinate.longitude) } ?? "none"
        #if APP_STORE
        let revision = "\(asset.modificationDate?.timeIntervalSince1970 ?? 0) "
        #else
        let revision = ""
        #endif
        return "\(revision)\(asset.hasAdjustments) \(edits.joined(separator: ",")) \(asset.creationDate?.timeIntervalSince1970 ?? 0) \(place) \(asset.isFavorite)"
    }

    /// Catches originals and smaller copies that were deleted somewhere other than this app, so their
    /// rows stop offering them.
    func checkOriginals() {
        lock.lock()
        var waiting: [String] = []
        for job in jobs where job.state == "done" && job.newItem != nil {
            if !job.originalDeleted && job.deletion != "pending" { waiting.append(job.assetId) }
            if !job.copyDeleted, let copy = job.newItem { waiting.append(copy.id) }
        }
        lock.unlock()
        let missing = library.forget(missingAmong: waiting.filter { !Folders.isFile($0) })
            .union(folders.forget(missingAmong: waiting.filter(Folders.isFile)))
        if !missing.isEmpty { originalsDeleted(Array(missing)) }
    }

    /// Notes which finished jobs have had their original or their smaller copy deleted, so the page
    /// stops offering what is no longer there.
    func originalsDeleted(_ ids: [String]) {
        update { jobs in
            for job in jobs {
                if ids.contains(job.assetId) { job.originalDeleted = true }
                if let copy = job.newItem, ids.contains(copy.id) { job.copyDeleted = true }
            }
        }
    }

    func clearFinished() {
        lock.lock()
        jobs.removeAll { !$0.isActive }
        lock.unlock()
    }

    private func update(_ change: ([Job]) -> Void) {
        lock.lock()
        change(jobs)
        lock.unlock()
    }

    private func set(_ job: Job, _ state: String, message: String = "") {
        var ended: [String: Any]?
        update { _ in
            job.phases[job.state, default: 0] += Date().timeIntervalSince(job.stateSince)
            job.state = state
            job.message = message
            job.progress = 0
            job.stateSince = Date()
            // Test runs add nothing to Photos, so they stay out of the record.
            if !job.isActive, !job.dryRun { ended = job.record }
        }
        log("job \(job.id) \(job.name): \(state) \(message)")
        if let ended = ended { history.record(ended) }
        reportActiveCount()
    }

    private func isCancelled(_ job: Job) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return job.cancelled
    }

    private func run(_ job: Job) {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: job.isArchive ? "Copying originals to a folder" : "Compressing")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // Cancelled while it was waiting: already marked, nothing to do, except that it may have been
        // the last thing the originals of earlier videos were waiting for.
        if isCancelled(job) { return deleteOriginalsIfIdle() }
        do {
            if job.isArchive { try archive(job) } else { try compress(job) }
            // Worth a line in the log: the check before deleting will keep this original.
            if let source = job.source, let asset = library.asset(job.assetId), Converter.fingerprint(asset) != source {
                log("job \(job.id) \(job.name): the original changed in Photos while it was being copied")
            }
        } catch let error as ShrinkError {
            set(job, error.state, message: error.message)
        } catch {
            set(job, "failed", message: error.localizedDescription)
        }
        deleteOriginalsIfIdle()
    }

    /// Makes the smaller copy, adds it to Photos with the original's details, and lines the original up for
    /// deletion if that was asked for.
    private func compress(_ job: Job) throws {
        if job.isFile { return try compressFile(job) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "photo-review-\(UUID().uuidString).\(job.isPhoto ? "heic" : "mov")")
        // A test run keeps its file to look at, but only if it got that far; a skipped or failed one leaves nothing behind.
        var kept = false
        defer { if !kept { try? FileManager.default.removeItem(at: output) } }
        let asset = try job.isPhoto ? compressPhoto(job, to: output) : compressVideo(job, to: output)
        // Cancelled just as the copy was finished: nothing goes into Photos.
        if isCancelled(job) { throw ShrinkError.cancelled }
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let newBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard newBytes > 0, Double(newBytes) < Double(job.originalBytes) * 0.9 else {
            throw job.isPhoto ? ShrinkError(state: "skipped", message: "A copy wouldn't be meaningfully smaller, so it was skipped.") : ShrinkError.nothingToGain
        }

        var newItem: Item?
        var detailsCopied = true
        if !job.dryRun {
            set(job, "saving")
            newItem = try save(output, replacing: asset, name: job.name, photo: job.isPhoto)
            // Titles, captions and keywords live where PhotoKit can't reach them; Photos' scripting can.
            if let copy = newItem, let problem = copyDetails(from: job.assetId, to: copy.id) {
                detailsCopied = false
                update { _ in job.note = problem }
            }
        }
        update { _ in
            job.newBytes = newBytes
            job.newItem = newItem
            guard job.deleteOriginal, let copy = newItem else { return }
            // Only let go of an original whose copy matches it: the same length for a video, the same shape
            // for a photo, and its titles, captions and keywords. Anything else needs a human look.
            let originalShape = Double(asset.pixelWidth) / Double(max(asset.pixelHeight, 1))
            let copyShape = Double(copy.width) / Double(max(copy.height, 1))
            let matches = job.isPhoto ? copy.width > 0 && abs(copyShape / originalShape - 1) < 0.02 : abs(copy.duration - asset.duration) < 1
            job.deletion = "kept"
            if job.cancelled {
                // The copy is already in Photos and stays, but a cancelled job doesn't go on to delete anything.
                job.message = "Cancelled after the copy was added to Photos."
            } else if !matches {
                job.message = job.isPhoto
                    ? "The copy's shape differs from the original's, so check it before deleting."
                    : "The copy's length differs from the original's, so check it before deleting."
            } else if !detailsCopied {
                job.message = "Check the new copy, then delete the original."
            } else {
                job.deletion = "pending"
                awaitingDeletion.append(job)
            }
        }
        kept = job.dryRun
        set(job, "done", message: job.dryRun ? output.path : job.message)
    }

    /// Copies an item's files into a folder for its year inside the chosen one, checks each copy, and then lines
    /// the item up for deletion like Compress & delete. The original and any edited version are both kept, and a
    /// Live Photo keeps its video.
    private func archive(_ job: Job) throws {
        guard let folder = job.folder else { throw ShrinkError.failed("No folder was chosen.") }
        guard let asset = library.asset(job.assetId) else { throw ShrinkError.failed("This item is no longer in the library.") }
        let source = Converter.fingerprint(asset)
        let kept: [PHAssetResourceType] = [.photo, .video, .alternatePhoto, .pairedVideo, .audio, .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo]
        let resources = PHAssetResource.assetResources(for: asset).filter { kept.contains($0.type) }
        guard !resources.isEmpty else { throw ShrinkError.failed("Photos has no files for this item.") }
        #if APP_STORE
        PhotosSizeAccess.shared.reload()
        #endif
        let knownSizes = resources.map { resourceBytes($0, asset: asset) }
        #if APP_STORE
        guard knownSizes.allSatisfy({ $0 != nil }) else {
            throw ShrinkError.failed("Some file sizes are unavailable. Choose your Photos library for size access and measure again before archiving this item.")
        }
        #endif
        let sizes = knownSizes.map { $0 ?? 0 }
        let total = max(sizes.reduce(0, +), 1)
        if let free = freeSpace(at: folder), free < total + 200_000_000 {
            throw ShrinkError.failed(String(format: "Not enough space in that folder: it needs about %.1f GB and %.1f GB is free.", Double(total) / 1e9, Double(free) / 1e9))
        }
        let date = asset.creationDate
        let place = folder.appendingPathComponent(date.map { String(Calendar.current.component(.year, from: $0)) } ?? "No date", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        } catch {
            throw ShrinkError.failed("Couldn't make a folder there: " + error.localizedDescription)
        }
        set(job, "downloading")
        var written: [URL] = []
        var writtenSizes: [Int64] = []
        var copiedBytes: Int64 = 0
        do {
            for (resource, size) in zip(resources, sizes) {
                // The edited version is named after the item, since Photos calls every one of them FullSizeRender.
                let edited = [.fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo].contains(resource.type)
                let fileExtension = (resource.originalFilename as NSString).pathExtension
                let fileName = edited
                    ? (job.name as NSString).deletingPathExtension + " (edited)" + (fileExtension.isEmpty ? "" : "." + fileExtension)
                    : resource.originalFilename
                let target = Converter.freeName(fileName, in: place)
                // Written under a temporary name and given its own only once it's complete and checked, so a copy
                // that was cut short, even by the app quitting, never looks like a finished one.
                let partial = place.appendingPathComponent(target.lastPathComponent + ".partial")
                written.append(partial)
                let before = copiedBytes
                try fetch(resource, to: partial, for: job) { fraction in
                    self.update { _ in job.progress = (Double(before) + fraction * Double(size)) / Double(total) }
                }
                // A copy that came out the wrong size isn't one to delete the original over.
                let copied = ((try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.int64Value ?? 0
                guard copied > 0, size == 0 || copied == size else {
                    throw ShrinkError.failed("The copy of \(fileName) came out the wrong size, so the original was kept.")
                }
                try FileManager.default.moveItem(at: partial, to: target)
                written[written.count - 1] = target
                if let date = date { try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: target.path) }
                writtenSizes.append(copied)
                copiedBytes += copied
            }
            // Cancelled once everything was copied: the copies go again, and the original stays as it was.
            if isCancelled(job) { throw ShrinkError.cancelled }
        } catch {
            // Unfinished copies are removed so they aren't taken for complete ones.
            for file in written { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        _ = library.add(asset)  // re-measure: the original is on this Mac now
        update { _ in
            job.files = written.map { $0.path }
            job.fileSizes = writtenSizes
            job.source = source
            job.newBytes = copiedBytes
            if job.deleteOriginal && !job.cancelled {
                job.deletion = "pending"
                awaitingDeletion.append(job)
            }
        }
        set(job, "done", message: job.dryRun ? "Copied to \(place.path). Test run: the original stays." : "")
    }

    /// `name` in `folder`, or "name (2)" and so on when that is taken, so nothing already there is overwritten.
    static func freeName(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension, fileExtension = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) (\(number))" + (fileExtension.isEmpty ? "" : "." + fileExtension))
            number += 1
        }
        return candidate
    }

    /// Makes a smaller copy of a photo or video file in an added folder. The copy goes in the folder's Compressed
    /// folder, in the same subfolders as the original, with the original's dates; the original stays where it is,
    /// or is lined up for the Trash if that was asked for. A file that is only in Google Drive is downloaded first.
    private func compressFile(_ job: Job) throws {
        guard let source = Folders.url(job.assetId), FileManager.default.fileExists(atPath: source.path) else {
            throw ShrinkError.failed("This file is no longer there.")
        }
        var original = job.original
        // Cheap check before any download or encoding, as for Photos videos.
        func checkWorthIt() throws {
            guard original.isVideo && original.duration > 0 else { return }
            let target = job.settings.size(width: original.width, height: original.height)
            let rate = job.settings.bitrate(width: target.width, height: target.height, fps: job.settings.fps ?? 30)
            if rate * original.duration / 8 > Double(job.originalBytes) * 0.8 { throw ShrinkError.nothingToGain }
        }
        try checkWorthIt()
        let before = Folders.fingerprint(source)
        update { _ in job.source = before }
        if let values = try? source.resourceValues(forKeys: Set(Folders.keys)), Folders.isCloudOnly(values) {
            set(job, "downloading")
            try download(source, for: job)
            // Now that it's here, its length and size in pixels can be read, and its tile stops saying it's in the
            // cloud. A fresh URL, since a URL keeps the values it read before the download.
            if let probed = folders.addFile(URL(fileURLWithPath: source.path)) { original = probed }
            try checkWorthIt()
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "photo-review-\(UUID().uuidString).\(original.isVideo ? "mov" : "heic")")
        // A test run keeps its file to look at, but only if it got that far; a skipped or failed one leaves nothing behind.
        var kept = false
        defer { if !kept { try? FileManager.default.removeItem(at: output) } }
        set(job, "encoding")
        if original.isVideo {
            try encode(AVURLAsset(url: source), to: output, settings: job.settings, isCancelled: { self.isCancelled(job) }) { fraction in
                self.update { _ in job.progress = fraction }
            }
        } else if original.isRaw {
            try developRAW(source, to: output, settings: job.settings)
            update { _ in job.made = "raw" }
        } else if original.isJPEG {
            try convertToHEIC(try Data(contentsOf: source), to: output, settings: job.settings)
            update { _ in job.made = "heic" }
        } else {
            throw ShrinkError(state: "skipped", message: "Only videos, RAW photos and JPEG photos are made smaller.")
        }
        if isCancelled(job) { throw ShrinkError.cancelled }
        let newBytes = ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard newBytes > 0, Double(newBytes) < Double(job.originalBytes) * 0.9 else {
            throw job.isPhoto ? ShrinkError(state: "skipped", message: "A copy wouldn't be meaningfully smaller, so it was skipped.") : ShrinkError.nothingToGain
        }

        var newItem: Item?
        if !job.dryRun {
            set(job, "saving")
            let place = copyFolder(for: source)
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            let stem = (job.name as NSString).deletingPathExtension
            let target = Converter.freeName(stem + " (compressed)." + (original.isVideo ? "mov" : "heic"), in: place)
            try FileManager.default.moveItem(at: output, to: target)
            // The copy keeps the original's dates, so the two sort together.
            if let dates = try? source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                var attributes: [FileAttributeKey: Any] = [:]
                if let created = dates.creationDate { attributes[.creationDate] = created }
                if let changed = dates.contentModificationDate { attributes[.modificationDate] = changed }
                try? FileManager.default.setAttributes(attributes, ofItemAtPath: target.path)
            }
            newItem = folders.addFile(target)
            if newItem == nil { throw ShrinkError.failed("The copy was saved at \(target.path), but it couldn't be read back.") }
        }
        update { _ in
            job.newBytes = newBytes
            job.newItem = newItem
            guard job.deleteOriginal, let copy = newItem else { return }
            // As in Photos: only an original whose copy matches it, the same length or the same shape, goes.
            let originalShape = Double(original.width) / Double(max(original.height, 1))
            let copyShape = Double(copy.width) / Double(max(copy.height, 1))
            let matches = original.isVideo
                ? original.duration > 0 && abs(copy.duration - original.duration) < 1
                : copy.width > 0 && original.width > 0 && abs(copyShape / originalShape - 1) < 0.02
            job.deletion = "kept"
            if job.cancelled {
                job.message = "Cancelled after the copy was saved."
            } else if !matches {
                job.message = original.isVideo
                    ? "The copy's length differs from the original's, so check it before deleting."
                    : "The copy's shape differs from the original's, so check it before deleting."
            } else {
                job.deletion = "pending"
                awaitingDeletion.append(job)
            }
        }
        kept = job.dryRun
        set(job, "done", message: job.dryRun ? output.path : job.message)
    }

    /// Where a file's smaller copy goes: the Compressed folder of the added folder it's in, in the same subfolders.
    /// A copy that is itself in a Compressed folder stays beside the file it came from.
    private func copyFolder(for file: URL) -> URL {
        let parent = file.deletingLastPathComponent().standardizedFileURL
        guard let root = folders.folder(containing: file).map({ URL(fileURLWithPath: $0.path, isDirectory: true) }) else {
            return parent.appendingPathComponent(Folders.copies, isDirectory: true)
        }
        let inside = parent.path.count > root.path.count ? String(parent.path.dropFirst(root.path.count + 1)) : ""
        if inside == Folders.copies || inside.hasPrefix(Folders.copies + "/") { return parent }
        let copies = root.appendingPathComponent(Folders.copies, isDirectory: true)
        return inside.isEmpty ? copies : copies.appendingPathComponent(inside, isDirectory: true)
    }

    /// Brings a file that is only in the cloud onto this Mac by reading it as Finder would, which has Google Drive
    /// for desktop download it.
    private func download(_ url: URL, for job: Job) throws {
        let finished = DispatchSemaphore(value: 0)
        var failure: Error?
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
                // Reading a byte is enough: the whole file comes down before it can be read.
                if let handle = try? FileHandle(forReadingFrom: url) {
                    _ = try? handle.read(upToCount: 1)
                    try? handle.close()
                }
            }
            failure = error
            finished.signal()
        }
        while finished.wait(timeout: .now() + 0.5) == .timedOut {
            if isCancelled(job) { throw ShrinkError.cancelled }
        }
        if let failure = failure { throw ShrinkError.failed("Couldn't download it from Google Drive: " + failure.localizedDescription) }
        // A fresh URL: the one passed in still holds the values it read before the download.
        if let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: Set(Folders.keys)), Folders.isCloudOnly(values) {
            throw ShrinkError.failed("Google Drive didn't download it. Check that Google Drive for desktop is running and online.")
        }
    }

    /// Downloads the video if needed and re-encodes it into `output`. Returns the original's asset.
    private func compressVideo(_ job: Job, to output: URL) throws -> PHAsset {
        guard let asset = library.asset(job.assetId), asset.mediaType == .video else {
            throw ShrinkError.failed("This video is no longer in the library.")
        }
        // Cheap check before a long download. Assumes 30 fps when the rate is kept, which never overestimates much.
        let target = job.settings.size(width: asset.pixelWidth, height: asset.pixelHeight)
        let rate = job.settings.bitrate(width: target.width, height: target.height, fps: job.settings.fps ?? 30)
        if rate * asset.duration / 8 > Double(job.originalBytes) * 0.8 { throw ShrinkError.nothingToGain }

        let source = Converter.fingerprint(asset)
        update { _ in job.source = source }
        set(job, "downloading")
        let video = try original(of: asset, for: job)
        _ = library.add(asset)  // re-measure: the original is on this Mac now
        set(job, "encoding")
        try encode(
            video.asset, audioMix: video.audioMix, to: output, settings: job.settings,
            isCancelled: { self.isCancelled(job) }
        ) { fraction in
            self.update { _ in job.progress = fraction }
        }
        return asset
    }

    /// Makes a HEIC copy of a photo at `output`: a RAW photo developed afresh, or the still of a JPEG or Live
    /// Photo. Returns the original's asset.
    private func compressPhoto(_ job: Job, to output: URL) throws -> PHAsset {
        guard let asset = library.asset(job.assetId), asset.mediaType == .image else {
            throw ShrinkError.failed("This photo is no longer in the library.")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        // A RAW+JPEG pair holds two pictures, the RAW file and the camera's own JPEG, whichever Photos shows.
        if resources.contains(where: { $0.type == .alternatePhoto }) {
            throw ShrinkError(state: "skipped", message: "This photo keeps a RAW file and a JPEG together, and a copy would keep only one of them.")
        }
        let source = Converter.fingerprint(asset)
        update { _ in job.source = source }
        if !job.original.isRaw {
            try stillCopy(job, asset, to: output)
            return asset
        }
        // A copy developed from the RAW file would come out without the edits made to it in Photos.
        if asset.hasAdjustments {
            throw ShrinkError(state: "skipped", message: "This photo has edits in Photos, which a copy made from the RAW file would lose.")
        }
        guard let raw = resources.first(where: { $0.type == .photo && (UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) ?? false) })
        else { throw ShrinkError.failed("This photo has no RAW original to compress.") }
        set(job, "downloading")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "photo-review-\(UUID().uuidString).\((raw.originalFilename as NSString).pathExtension)")
        defer { try? FileManager.default.removeItem(at: file) }
        try fetch(raw, to: file, for: job)
        _ = library.add(asset)  // re-measure: the original is on this Mac now
        set(job, "encoding")
        try developRAW(file, to: output, settings: job.settings)
        update { _ in job.made = "raw" }
        return asset
    }

    /// A HEIC copy of a JPEG photo, or of a Live Photo's still without its video. A still that is already HEIC
    /// is kept exactly as it is; a JPEG is converted, which loses a little quality. Edits are baked in, as they
    /// are for videos.
    private func stillCopy(_ job: Job, _ asset: PHAsset, to output: URL) throws {
        set(job, "downloading")
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction, _, _, _ in
            self.update { _ in
                job.progress = fraction
                if job.paceFrom == nil { job.paceFrom = (fraction, Date()) }
            }
        }
        let arrived = DispatchSemaphore(value: 0)
        var result: (data: Data?, type: String?, orientation: CGImagePropertyOrientation, info: [AnyHashable: Any]?) = (nil, nil, .up, nil)
        let request = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, type, orientation, info in
            result = (data, type, orientation, info)
            arrived.signal()
        }
        while arrived.wait(timeout: .now() + 0.5) == .timedOut {
            if isCancelled(job) {
                PHImageManager.default().cancelImageRequest(request)
                throw ShrinkError.cancelled
            }
        }
        if isCancelled(job) { throw ShrinkError.cancelled }
        guard let data = result.data else {
            throw ShrinkError.failed("Couldn't get the photo from Photos: " + Converter.describe(result.info?[PHImageErrorKey] as? NSError))
        }
        _ = library.add(asset)  // re-measure: the original is on this Mac now
        set(job, "encoding")
        // Photos can show a photo turned another way than its file says, and the copy has to look the way Photos shows it.
        let embedded = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
            .flatMap { $0[kCGImagePropertyOrientation as String] as? UInt32 }
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let turned = result.orientation != embedded ? result.orientation : nil
        if let turned = turned { log("job \(job.id) \(job.name): Photos shows it turned \(turned.rawValue), its file says \(embedded.rawValue)") }
        if let type = result.type, UTType(type)?.conforms(to: .heic) == true, turned == nil {
            try data.write(to: output)
            update { _ in job.made = "still" }
        } else {
            try convertToHEIC(data, to: output, settings: job.settings, orientation: turned)
            update { _ in job.made = "heic" }
        }
    }

    /// Copies a resource's original file out of Photos into `file`, downloading it from iCloud if it isn't on
    /// this Mac. Unlike a video download it's seconds rather than hours, so one try is enough. `progress`, if
    /// given, is told how far along this file is instead of the job's bar being set directly.
    private func fetch(_ resource: PHAssetResource, to file: URL, for job: Job, progress: ((Double) -> Void)? = nil) throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction in
            if let progress = progress { return progress(fraction) }
            self.update { _ in
                job.progress = fraction
                if job.paceFrom == nil { job.paceFrom = (fraction, Date()) }
            }
        }
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let handle = try? FileHandle(forWritingTo: file) else {
            throw ShrinkError.failed("Couldn't make a file to copy the original into.")
        }
        let sink = Sink(handle)
        defer { sink.close() }
        let finished = DispatchSemaphore(value: 0)
        var failure: NSError?
        let request = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
            sink.write(data)
        } completionHandler: { error in
            failure = error as NSError?
            finished.signal()
        }
        while finished.wait(timeout: .now() + 0.5) == .timedOut {
            // A write that failed, on a full or unplugged drive say, stops the download as well.
            if isCancelled(job) || sink.problem != nil {
                PHAssetResourceManager.default().cancelDataRequest(request)
                // Photos may still be handing data over; the sink drops whatever comes after this.
                _ = finished.wait(timeout: .now() + 10)
                break
            }
        }
        if isCancelled(job) { throw ShrinkError.cancelled }
        if let problem = sink.problem { throw ShrinkError.failed("Couldn't write the copy: " + problem.localizedDescription) }
        if let failure = failure { throw ShrinkError.failed("Couldn't download the original from iCloud: " + Converter.describe(failure)) }
        if let problem = sink.finish() { throw ShrinkError.failed("Couldn't finish writing the copy: " + problem.localizedDescription) }
    }

    /// The full-quality video with any edits applied, downloaded from iCloud if it isn't on this Mac.
    private func original(of asset: PHAsset, for job: Job) throws -> (asset: AVAsset, audioMix: AVAudioMix?) {
        func request(network: Bool) -> (video: AVAsset?, audioMix: AVAudioMix?, info: [AnyHashable: Any]?) {
            let options = PHVideoRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = network
            // The on-this-Mac check reports 100% straight away, which would look like a finished download.
            if network {
                options.progressHandler = { fraction, _, _, _ in
                    self.update { _ in
                        job.progress = fraction
                        if job.paceFrom == nil { job.paceFrom = (fraction, Date()) }
                        // Data is flowing again, so the "trying again" note no longer applies.
                        job.message = ""
                    }
                }
            }
            let arrived = DispatchSemaphore(value: 0)
            var result: (video: AVAsset?, audioMix: AVAudioMix?, info: [AnyHashable: Any]?) = (nil, nil, nil)
            let request = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, mix, info in
                result = (video, mix, info)
                arrived.signal()
            }
            while arrived.wait(timeout: .now() + 0.5) == .timedOut {
                if isCancelled(job) {
                    PHImageManager.default().cancelImageRequest(request)
                    return (nil, nil, nil)
                }
            }
            return result
        }

        let local = request(network: false)
        if let video = local.video { return (video, local.audioMix) }
        if isCancelled(job) { throw ShrinkError.cancelled }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        let needed = job.originalBytes + 2_000_000_000
        if let free = free, free < needed {
            throw ShrinkError.failed(
                String(format: "Not enough free disk space to download the original: needs about %.1f GB, %.1f GB is free.",
                    Double(needed) / 1e9, Double(free) / 1e9))
        }
        // A download this size can run for hours, so one dropped connection shouldn't throw it all away.
        let attempts = 6
        for attempt in 1...attempts {
            let remote = request(network: true)
            if isCancelled(job) { throw ShrinkError.cancelled }
            if let video = remote.video { return (video, remote.audioMix) }
            let error = remote.info?[PHImageErrorKey] as? NSError
            let dropped = error?.domain == NSURLErrorDomain || [3164, 3169].contains(error?.code ?? 0)
            guard dropped, attempt < attempts else {
                throw ShrinkError.failed("Couldn't download the original from iCloud: " + Converter.describe(error))
            }
            log("job \(job.id) download attempt \(attempt) failed: \(String(describing: error))")
            update { _ in
                job.message = "The connection dropped. Trying again shortly (attempt \(attempt + 1) of \(attempts))."
                job.paceFrom = nil
            }
            // Wait a little longer each time, checking for Cancel while waiting.
            for _ in 0..<(attempt * 40) {
                if isCancelled(job) { throw ShrinkError.cancelled }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        throw ShrinkError.failed("Couldn't download the original from iCloud.")
    }

    /// Plain words for the errors Photos reports by number.
    private static func describe(_ error: NSError?) -> String {
        guard let error = error else { return "Photos gave no reason." }
        if error.domain == NSURLErrorDomain { return "the network connection failed (" + error.localizedDescription + ")" }
        switch error.code {
        case 3164: return "this Mac is offline."
        case 3169: return "the network connection kept dropping."
        case 3305: return "there isn't enough free disk space."
        default: return error.localizedDescription
        }
    }

    /// Adds the encoded file to Photos as a new video or photo carrying the original's date, location, favorite
    /// flag and albums.
    private func save(_ file: URL, replacing original: PHAsset, name: String, photo: Bool) throws -> Item {
        var newId: String?
        try PHPhotoLibrary.shared().performChangesAndWait {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = (name as NSString).deletingPathExtension + (photo ? " (compressed).heic" : " (compressed).mov")
            options.shouldMoveFile = true
            request.addResource(with: photo ? .photo : .video, fileURL: file, options: options)
            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite
            newId = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = newId, let created = library.asset(id) else {
            throw ShrinkError.failed(photo ? "Photos didn't accept the new photo." : "Photos didn't accept the new video.")
        }
        // Best effort: an album that refuses the addition shouldn't undo the new copy.
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(original, with: .album, options: nil)
        albums.enumerateObjects { album, _, _ in
            guard album.canPerform(.addContent) else { return }
            try? PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([created] as NSArray)
            }
        }
        return library.add(created)
    }
}

// MARK: - HTTP

struct Request {
    static let maxBody = 4 << 20
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    /// Nil until the whole request has arrived.
    init?(_ data: Data) {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)),
            let head = String(data: data.subdata(in: 0..<headEnd.lowerBound), encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, let url = URLComponents(string: "http://localhost" + parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // A negative or absurd length is treated as no body rather than trusted in the arithmetic below.
        var length = Int(headers["content-length"] ?? "") ?? 0
        if length < 0 || length > Request.maxBody { length = 0 }
        guard data.count >= headEnd.upperBound + length else { return nil }
        // The page builds queries with URLSearchParams, which sends a space as "+" (a real "+" arrives as %2B).
        var form = url
        form.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        var query: [String: String] = [:]
        for item in form.queryItems ?? [] { query[item.name] = item.value ?? "" }
        method = String(parts[0])
        path = url.path
        self.query = query
        self.headers = headers
        body = data.subdata(in: headEnd.upperBound..<(headEnd.upperBound + length))
    }
}

final class Server {
    private let library: Library
    /// Photos and videos in folders the person adds, beside the Photos library.
    private let folders = Folders()
    /// The app listens to it for the Dock badge and the notification when the queue is done.
    let converter: Converter
    private let history = History()
    private let queue = DispatchQueue(label: "http", attributes: .concurrent)
    private var listener: NWListener?
    private let page: String
    private let statsPage: String
    private let icon: Data
    /// Called on the main thread with nil once the port is open, or with the reason it couldn't be.
    var onStart: ((String?) -> Void)?
    /// Asks the person to pick a folder (the app shows its own panel) and calls back with it, or nil. The purpose is
    /// "archive" (where to copy originals), "local" or "drive" (a folder to add).
    var chooseFolder: ((_ purpose: String, _ completion: @escaping (URL?) -> Void) -> Void)?
    var hasActiveJobs: Bool { converter.hasActiveJobs }

    init(library: Library) {
        self.library = library
        converter = Converter(library: library, folders: folders, history: history)
        func resource(_ name: String) -> String {
            let url = Bundle.main.url(forResource: name, withExtension: "html")
            return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "\(name).html is missing"
        }
        page = resource("index").replacingOccurrences(of: "__TOKEN__", with: token)
        statsPage = resource("stats").replacingOccurrences(of: "__TOKEN__", with: token)
        icon = Bundle.main.url(forResource: "icon", withExtension: "svg").flatMap { try? Data(contentsOf: $0) } ?? Data()
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: nothing off this Mac can reach the server.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        // A port that is already taken is reported here, not thrown by the initializer.
        listener.stateUpdateHandler = { state in
            log("listener: \(state)")
            switch state {
            case .ready: DispatchQueue.main.async { self.onStart?(nil) }
            case .failed(let error):
                var reason = error.localizedDescription
                if case .posix(let code) = error, code == .EADDRINUSE { reason = "the port is already in use." }
                DispatchQueue.main.async { self.onStart?(reason) }
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            self.read(connection, Data())
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
            var buffer = buffer
            if let data = data { buffer.append(data) }
            if let request = Request(buffer) {
                self.handle(request, connection)
            } else if complete || error != nil || buffer.count > Request.maxBody + (1 << 16) {
                connection.cancel()
            } else {
                self.read(connection, buffer)
            }
        }
    }

    private func send(_ connection: NWConnection, _ status: Int, _ type: String, _ body: Data, _ extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\nContent-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in extra { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendJSON(_ connection: NWConnection, _ object: [String: Any], status: Int = 200) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(connection, status, "application/json", body, ["Cache-Control": "no-store"])
    }

    private func handle(_ request: Request, _ connection: NWConnection) {
        // Rejects requests that reached us under another hostname (DNS rebinding).
        guard ["127.0.0.1:\(port)", "localhost:\(port)"].contains(request.headers["host"] ?? "") else {
            return send(connection, 403, "text/plain", Data("forbidden".utf8))
        }
        if request.method == "POST", request.headers["x-token"] != token {
            return send(connection, 403, "text/plain", Data("forbidden".utf8))
        }
        switch (request.method, request.path) {
        case ("GET", "/"):
            send(connection, 200, "text/html; charset=utf-8", Data(page.utf8), ["Cache-Control": "no-store"])
        case ("GET", "/icon.svg"):
            send(connection, 200, "image/svg+xml", icon, ["Cache-Control": "private, max-age=3600"])
        case ("GET", "/privacy"):
            let file = Bundle.main.url(forResource: "privacy", withExtension: "html")
            let data = file.flatMap { try? Data(contentsOf: $0) }
            send(connection, data == nil ? 404 : 200, "text/html; charset=utf-8", data ?? Data())
        case ("GET", "/stats"):
            send(connection, 200, "text/html; charset=utf-8", Data(statsPage.utf8), ["Cache-Control": "no-store"])
        case ("GET", "/api/stats"):
            // Each finished shrink also says whether its original and its smaller copy are still in the library.
            let events = history.all().map { event -> [String: Any] in
                guard event["type"] as? String == "shrink", event["outcome"] as? String == "done" else { return event }
                var event = event
                // A file counts as there if it's on disk, whether or not its folder has been looked through since.
                func exists(_ id: String) -> Bool {
                    Folders.url(id).map { FileManager.default.fileExists(atPath: $0.path) } ?? (library.item(id) != nil)
                }
                event["originalExists"] = exists(event["assetId"] as? String ?? "")
                event["copyExists"] = exists(event["newId"] as? String ?? "")
                return event
            }
            sendJSON(connection, ["ready": library.isReady, "events": events])
        case ("GET", "/api/items"):
            // The Photos library, or with source=folder one added folder.
            let folder = request.query["source"] == "folder" ? request.query["folder"] : nil
            let query = { () -> [String: Any] in
                let kind = request.query["kind"] ?? "all", year = Int(request.query["year"] ?? "")
                let minBytes = Int64(request.query["minBytes"] ?? "") ?? 0
                let offset = Int(request.query["offset"] ?? "") ?? 0, limit = min(Int(request.query["limit"] ?? "") ?? 60, 2000)
                if let folder = folder {
                    return self.folders.query(folder: folder, kind: kind, year: year, minBytes: minBytes, offset: offset, limit: limit)
                }
                return self.library.query(kind: kind, year: year, minBytes: minBytes, offset: offset, limit: limit)
            }
            var result = query()
            // Anything on this page that has since been deleted, in Photos itself or in Finder, is dropped before it is shown.
            if let items = result["items"] as? [[String: Any]] {
                let shown = items.prefix(500).compactMap { $0["id"] as? String }
                if folder != nil {
                    if !folders.forget(missingAmong: shown).isEmpty { result = query() }
                } else if library.isReady, !library.forget(missingAmong: shown).isEmpty {
                    result = query()
                }
            }
            // A video whose smaller copy is in Photos while the original is still here carries that copy
            // along. This comes from the history file, so its tile can say so after the app is restarted.
            // A smaller copy says what it was shrunk from, so it isn't mistaken for something still to do.
            // The history knows the original's size; a copy made elsewhere is recognised by its name alone.
            let copies = history.copies(), origins = history.origins()
            if let items = result["items"] as? [[String: Any]] {
                result["items"] = items.map { item -> [String: Any] in
                    var item = item
                    let id = item["id"] as? String ?? ""
                    if let copy = copies[id].flatMap({ library.item($0) ?? folders.item($0) }) { item["copy"] = copy.json }
                    if let bytes = origins[id] {
                        item["shrunkFrom"] = bytes
                    } else if [" (compressed)", " (shrunk)"].contains(where: { ((item["name"] as? String ?? "") as NSString).deletingPathExtension.hasSuffix($0) }) {
                        // Copies made before the button was renamed end in "(shrunk)".
                        item["shrunkFrom"] = 0
                    }
                    return item
                }
            }
            // Compressing downloads each original first, so Pick many keeps a batch to what fits. The Photos library
            // is nearly always on the startup disk, which is what the home folder is on. This is the space free now,
            // not counting what macOS could clear later, so a batch can't fill the disk if it doesn't.
            let free = (try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
            // Files on this Mac or a drive need no download; only Google Drive's can.
            result["freeBytes"] = folder.map { Folders.inDrive($0) } == false ? NSNull() : (free ?? NSNull())
            sendJSON(connection, result)
        case ("GET", "/thumb"):
            let size = min(max(Int(request.query["size"] ?? "") ?? 480, 64), 2400)
            if Folders.isFile(request.query["id"] ?? "") {
                return folders.thumbnail(id: request.query["id"] ?? "", size: size) { data in
                    if let data = data {
                        self.send(connection, 200, "image/jpeg", data, ["Cache-Control": "private, max-age=3600"])
                    } else {
                        self.send(connection, 404, "text/plain", Data("no image".utf8))
                    }
                }
            }
            library.thumbnail(id: request.query["id"] ?? "", size: size) { data, sharp in
                if let data = data {
                    let caching = sharp ? "private, max-age=3600" : "no-store"
                    self.send(connection, 200, "image/jpeg", data, ["Cache-Control": caching])
                } else {
                    self.send(connection, 404, "text/plain", Data("no image".utf8))
                }
            }
        case ("GET", "/video"):
            serveVideo(request, connection)
        case ("POST", "/api/delete"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let ids = payload?["ids"] as? [String] ?? []
            guard !ids.isEmpty else { return sendJSON(connection, ["ok": false, "error": "Nothing selected."], status: 400) }
            converter.delete(ids: ids) { ok, error in
                self.sendJSON(connection, ["ok": ok, "error": error ?? ""])
            }
        case ("POST", "/api/shrink"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let started = converter.enqueue(
                ids: payload["ids"] as? [String] ?? [], settings: ShrinkSettings(payload),
                dryRun: payload["dryRun"] as? Bool ?? false, deleteOriginal: payload["deleteOriginal"] as? Bool ?? false,
                deleteOriginalIds: Set(payload["deleteOriginalIds"] as? [String] ?? []))
            // Copies get their titles, captions and keywords through Photos, which macOS asks about once: ask now.
            // Files in folders have none of those, so a queue of only files doesn't ask.
            let photosItems = (payload["ids"] as? [String] ?? []).contains { !Folders.isFile($0) }
            if started > 0, photosItems, payload["dryRun"] as? Bool != true { photosControl.queueStarted() }
            sendJSON(connection, ["ok": started > 0, "started": started, "error": started > 0 ? "" : "No videos or RAW photos to compress."])
        case ("GET", "/api/jobs"):
            converter.checkOriginals()
            sendJSON(connection, ["jobs": converter.list()])
        case ("POST", "/api/archive"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            var isFolder: ObjCBool = false
            guard let path = payload["folder"] as? String, FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                return sendJSON(connection, ["ok": false, "error": "That folder isn't there any more."], status: 400)
            }
            let started = converter.enqueueArchive(
                ids: payload["ids"] as? [String] ?? [], folder: URL(fileURLWithPath: path, isDirectory: true),
                dryRun: payload["dryRun"] as? Bool ?? false)
            sendJSON(connection, ["ok": started > 0, "started": started, "error": started > 0 ? "" : "Nothing to copy."])
        case ("POST", "/api/choose-folder"):
            DispatchQueue.main.async {
                guard let choose = self.chooseFolder else {
                    return self.sendJSON(connection, ["ok": false, "error": "Choosing a folder isn't available."])
                }
                choose("archive") { folder in
                    self.sendJSON(connection, folder.map { ["ok": true, "path": $0.path] } ?? ["ok": false, "error": ""])
                }
            }
        case ("GET", "/api/folders"):
            let source = request.query["source"] == "drive" ? "drive" : "local"
            let drives = Folders.driveRoots.map { root -> [String: Any] in
                // "GoogleDrive-name@gmail.com" is how Google Drive for desktop names each account's folder.
                let account = root.lastPathComponent.hasPrefix("GoogleDrive-") ? String(root.lastPathComponent.dropFirst(12)) : root.lastPathComponent
                return ["path": root.path, "account": account]
            }
            sendJSON(connection, ["source": source, "folders": folders.list(source: source), "drives": drives])
        case ("POST", "/api/folders/add"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let source = payload["source"] as? String == "drive" ? "drive" : "local"
            func add(_ path: String) {
                let problem = folders.add(path: path, source: source)
                sendJSON(connection, problem == nil ? ["ok": true, "path": URL(fileURLWithPath: path).standardizedFileURL.path] : ["ok": false, "error": problem!])
            }
            // A path comes only from tests; the page has the person choose one in the usual panel.
            if let path = payload["path"] as? String { return add(path) }
            DispatchQueue.main.async {
                guard let choose = self.chooseFolder else {
                    return self.sendJSON(connection, ["ok": false, "error": "Choosing a folder isn't available."])
                }
                choose(source) { folder in
                    guard let folder = folder else { return self.sendJSON(connection, ["ok": false, "error": ""]) }
                    DispatchQueue.global().async { add(folder.path) }
                }
            }
        case ("POST", "/api/folders/remove"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            guard let path = payload["path"] as? String else { return sendJSON(connection, ["ok": false, "error": "No folder."], status: 400) }
            folders.remove(path: path)
            sendJSON(connection, ["ok": true])
        case ("GET", "/api/version"):
            #if APP_STORE
            sendJSON(connection, ["available": false, "appStore": true])
            #else
            sendJSON(connection, updates.json)
            #endif
        #if APP_STORE
        case ("POST", "/api/size-library"):
            guard library.canChooseSizeLibrary else { return sendJSON(connection, ["ok": false, "error": "Wait for the current measurement to finish."]) }
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true; panel.canChooseDirectories = true
                panel.treatsFilePackagesAsDirectories = true
                panel.allowsMultipleSelection = false
                panel.message = "Choose your System Photo Library to read file sizes without downloading photos or videos. Photo Review only reads its size records."
                panel.prompt = "Read Sizes"
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let url = panel.url else {
                    return self.sendJSON(connection, ["ok": false, "error": ""])
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try PhotosSizeAccess.shared.select(url)
                        self.library.update()
                        self.sendJSON(connection, ["ok": true])
                    } catch { self.sendJSON(connection, ["ok": false, "error": error.localizedDescription]) }
                }
            }
        #if DEBUG
        case ("POST", "/api/audit-sizes"):
            DispatchQueue.global(qos: .utility).async {
                PhotosSizeAccess.shared.reload()
                self.sendJSON(connection, PhotosSizeAccess.shared.audit(limit: Int(request.query["limit"] ?? "") ?? 0, ids: (request.query["ids"] ?? "").split(separator: ",").map(String.init)))
            }
        #endif
        #endif
        case ("POST", "/api/update"):
            // With a folder, that folder is looked through again; without, the Photos library is measured again.
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            if let folder = payload["folder"] as? String {
                folders.rescan(folder)
                return sendJSON(connection, ["ok": true])
            }
            sendJSON(connection, ["ok": library.update()])
        case ("POST", "/api/jobs/cancel"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            converter.cancel(payload?["id"] as? Int ?? 0)
            sendJSON(connection, ["ok": true])
        case ("POST", "/api/jobs/clear"):
            converter.clearFinished()
            sendJSON(connection, ["ok": true])
        case ("POST", "/api/reveal"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let id = payload?["id"] as? String ?? ""
            // A file is shown in Finder instead.
            if let url = Folders.url(id) {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return sendJSON(connection, ["ok": false, "error": "it's no longer in that folder."])
                }
                return DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    self.sendJSON(connection, ["ok": true, "error": ""])
                }
            }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-/"))
            guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else {
                return sendJSON(connection, ["ok": false, "error": "Bad id."], status: 400)
            }
            DispatchQueue.main.async {
                var error: NSDictionary?
                let source = "tell application \"Photos\"\nactivate\nspotlight media item id \"\(id)\"\nend tell"
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                var message = error?[NSAppleScript.errorMessage] as? String ?? ""
                if message.contains("media item") { message = "it's no longer in the Photos library." }
                self.sendJSON(connection, ["ok": error == nil, "error": message])
            }
        default:
            send(connection, 404, "text/plain", Data("not found".utf8))
        }
    }

    private func serveVideo(_ request: Request, _ connection: NWConnection) {
        let id = request.query["id"] ?? ""
        // Only videos have something to play; anything else is simply not found.
        guard (library.item(id) ?? folders.item(id))?.isVideo == true else {
            return send(connection, 404, "text/plain", Data("not a video".utf8))
        }
        // A file in a folder plays from where it is (one only in Google Drive downloads as it plays).
        let find: (@escaping (URL?) -> Void) -> Void = Folders.isFile(id)
            ? { found in found(Folders.url(id)) } : { found in self.library.videoURL(id: id, completion: found) }
        find { url in
            guard let url = url else {
                return self.send(connection, 504, "text/plain", Data("Photos didn't provide the video".utf8))
            }
            guard let file = try? FileHandle(forReadingFrom: url),
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0
            else {
                return self.send(connection, 404, "text/plain", Data("unreadable".utf8))
            }
            var start: Int64 = 0
            var end = size - 1
            var status = 200
            if let range = request.headers["range"], range.hasPrefix("bytes=") {
                let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                if let first = bounds.first, let from = Int64(first) {
                    start = from
                    if bounds.count > 1, let to = Int64(bounds[1]) { end = min(to, size - 1) }
                    status = 206
                } else if bounds.count > 1, let suffix = Int64(bounds[1]) {
                    start = max(0, size - suffix)
                    status = 206
                }
            }
            guard start <= end else {
                try? file.close()
                return self.send(connection, 416, "text/plain", Data(), ["Content-Range": "bytes */\(size)"])
            }
            var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Partial Content")\r\nContent-Type: video/mp4\r\n"
            head += "Content-Length: \(end - start + 1)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            if status == 206 { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
            head += "\r\n"
            try? file.seek(toOffset: UInt64(start))
            connection.send(content: Data(head.utf8), completion: .contentProcessed { error in
                if error == nil {
                    self.stream(connection, file, end - start + 1)
                } else {
                    try? file.close()
                    connection.cancel()
                }
            })
        }
    }

    private func stream(_ connection: NWConnection, _ file: FileHandle, _ remaining: Int64) {
        let chunk = remaining > 0 ? file.readData(ofLength: Int(min(remaining, 1 << 20))) : Data()
        if chunk.isEmpty {
            try? file.close()
            return connection.cancel()
        }
        connection.send(content: chunk, completion: .contentProcessed { error in
            if error == nil {
                self.stream(connection, file, remaining - Int64(chunk.count))
            } else {
                try? file.close()
                connection.cancel()
            }
        })
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    UNUserNotificationCenterDelegate
{
    private let library = Library()
    private var server: Server?
    private var window: NSWindow!
    private var webView: WKWebView!
    private var titleWatch: NSKeyValueObservation?
    private var quitConfirmed = false
    private var askedForNotifications = false
    private var updateTimer: Timer?
    private let automaticUpdates = "checkForUpdates"
    private let home = URL(string: "http://127.0.0.1:\(port)/")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [automaticUpdates: true])
        UNUserNotificationCenter.current().delegate = self
        NSApp.mainMenu = makeMenu()

        // The pages the app serves are its interface, shown in its own window rather than a browser tab.
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .windowBackgroundColor

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Photo Review"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = webView
        window.tabbingMode = .disallowed
        // Comes back at the size and place it was left.
        if !window.setFrameUsingName("Photo Review") { window.center() }
        window.setFrameAutosaveName("Photo Review")
        titleWatch = webView.observe(\.title) { [weak self] view, _ in
            self?.window.title = view.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Photo Review"
        }
        webView.loadHTMLString(AppDelegate.notice("Starting…"), baseURL: nil)
        // Started with --no-open (after an update, say), the app waits in the Dock until it's clicked.
        if !CommandLine.arguments.contains("--no-open") { window.makeKeyAndOrderFront(nil) }

        let server = Server(library: library)
        server.onStart = { [weak self] problem in self?.started(problem) }
        server.converter.onActiveCount = { [weak self] count in self?.queueChanged(count) }
        server.converter.onFinished = { [weak self] ended, confirming in self?.queueFinished(ended, confirming) }
        server.chooseFolder = { [weak self] purpose, completion in
            if let self = self { self.chooseFolder(purpose, completion) } else { completion(nil) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            started(error.localizedDescription)
        }
    }

    private func started(_ problem: String?) {
        if let problem = problem {
            server = nil
            webView.loadHTMLString(
                AppDelegate.notice(
                    "Photo Review couldn't start: \(problem)",
                    detail: "Another copy may already be running. Quit this one, then open Photo Review again."),
                baseURL: nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        #if DEBUG
        // Isolated folder tests do not ask for or read a personal Photos library.
        if !CommandLine.arguments.contains("--folders-only") { library.start() }
        #else
        library.start()
        #endif
        webView.load(URLRequest(url: home))
        scheduleUpdateChecks()
        // For the log: whether Photos may be controlled, found out only if Photos is open anyway, so nothing is asked.
        DispatchQueue.global(qos: .utility).async {
            if PhotosControl.photosIsOpen { log("controlling Photos: \(PhotosControl.ask(prompt: false).rawValue)") }
        }
    }

    /// A plain page for the moments before the interface is ready, in the system's own light or dark look.
    private static func notice(_ message: String, detail: String = "") -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        return """
            <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">
            <body style="font: 15px -apple-system, sans-serif; display: grid; place-content: center; height: 90vh; text-align: center">
            <p><b>\(escape(message))</b></p><p style="opacity: .7">\(escape(detail))</p></body>
            """
    }

    private func isOwnPage(_ url: URL) -> Bool {
        url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost") && url.port == Int(port)
    }

    /// Web pages and email, the only kinds of link the pages have. Anything else goes nowhere, rather than being
    /// handed to whichever app would open it.
    private func opensElsewhere(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    // The app's own pages, and the notice shown while it starts, load here. Links to anything else, such as the
    // website or Apple's guides, open in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if isOwnPage(url) || url.absoluteString == "about:blank" { return decisionHandler(.allow) }
        if opensElsewhere(url) { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    // A link meant for a new window opens in the browser, or in this window if it's one of the app's pages.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isOwnPage(url) { webView.load(action.request) } else if opensElsewhere(url) { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    // If the page's process quits, show the page again rather than a blank window.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if server != nil { webView.load(URLRequest(url: home)) }
    }

    private func makeMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        #if !APP_STORE
        let automatic = item("Check for Updates Automatically", #selector(toggleAutomaticUpdates(_:)))
        automatic.state = UserDefaults.standard.bool(forKey: automaticUpdates) ? .on : .off
        #endif
        let appMenu = NSMenu()
        for entry in [
            item("About Photo Review", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide Photo Review", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))), .separator(),
            item("Quit Photo Review", #selector(NSApplication.terminate(_:)), "q"),
        ] { appMenu.addItem(entry) }
        #if !APP_STORE
        appMenu.insertItem(item("Check for Updates…", #selector(checkForUpdates)), at: 1)
        appMenu.insertItem(automatic, at: 2)
        #endif
        // The page's own text fields and selections need these to cut, copy and paste.
        let editMenu = NSMenu(title: "Edit")
        for entry in [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] { editMenu.addItem(entry) }
        let viewMenu = NSMenu(title: "View")
        for entry in [
            item("Library", #selector(showLibrary), "1"), item("Savings and History", #selector(showSavings), "2"), .separator(),
            item("Reload Page", #selector(reloadPage), "r"), item("Open in Browser", #selector(openBrowser)), .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ] { viewMenu.addItem(entry) }
        let windowMenu = NSMenu(title: "Window")
        for entry in [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"), item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(), item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ] { windowMenu.addItem(entry) }
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item("Photo Review Website", #selector(openWebsite)))
        #if APP_STORE
        helpMenu.addItem(item("Privacy Policy", #selector(showPrivacy)))
        #endif
        helpMenu.addItem(item("Report a Problem…", #selector(reportProblem)))
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu

        let menu = NSMenu()
        for (title, submenu) in [("Photo Review", appMenu), ("Edit", editMenu), ("View", viewMenu), ("Window", windowMenu), ("Help", helpMenu)] {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.submenu = submenu
            menu.addItem(entry)
        }
        return menu
    }

    private func show(_ path: String) {
        guard server != nil else { return }
        window.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: home.appendingPathComponent(path)))
    }

    @objc private func showLibrary() { show("") }
    @objc private func showSavings() { show("stats") }
    @objc private func reloadPage() { if server != nil { webView.reload() } }
    @objc private func openBrowser() { if server != nil { NSWorkspace.shared.open(home) } }
    @objc private func openWebsite() { NSWorkspace.shared.open(URL(string: "https://danielyaa5.github.io/photo-review/")!) }
    @objc private func reportProblem() { NSWorkspace.shared.open(URL(string: "https://github.com/danielyaa5/photo-review/issues")!) }

    // MARK: Queue progress

    /// Shows how many jobs are left on the Dock icon. The first time anything is queued is a good moment to ask
    /// whether the app may say so when it's all done.
    private func queueChanged(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        log("dock badge: \(count > 0 ? String(count) : "none")")
        guard count > 0, !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            log("notifications \(granted ? "allowed" : "not allowed")\(error.map { ": " + $0.localizedDescription } ?? "")")
        }
    }

    /// A long queue usually finishes while nobody is watching, so say how it went, and that the deletion is
    /// waiting for its confirmation if it is.
    private func queueFinished(_ ended: [Job], _ confirming: Int) {
        let sizes = ByteCountFormatter()
        let done = ended.filter { $0.state == "done" }
        let compressed = done.filter { !$0.isArchive }, archived = done.filter { $0.isArchive }
        let smaller = compressed.reduce(Int64(0)) { $0 + max($1.originalBytes - $1.newBytes, 0) }
        var parts: [String] = []
        if !compressed.isEmpty { parts.append("\(compressed.count) compressed (\(sizes.string(fromByteCount: smaller)) smaller)") }
        if !archived.isEmpty { parts.append("\(archived.count) copied to a folder") }
        let skipped = ended.filter { $0.state == "skipped" }.count, failed = ended.filter { $0.state == "failed" }.count
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) couldn't be done") }
        // A queue that was only cancelled has nothing to report.
        guard !parts.isEmpty else { return }
        var body = parts.joined(separator: ", ") + "."
        if confirming > 0 {
            body += " Confirm deleting \(confirming == 1 ? "1 original" : "\(confirming) originals") in the Photo Review dialog."
            NSApp.requestUserAttention(.criticalRequest)
        }
        let content = UNMutableNotificationContent()
        content.title = "The queue has finished"
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            log("notification: \(body)\(error.map { " (not shown: " + $0.localizedDescription + ")" } ?? "")")
        }
    }

    // While the window is in front, its queue panel already says all this, so the note only goes in the list.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(NSApp.isActive && window.isVisible ? [.list] : [.banner, .list, .sound])
    }

    // Clicking the notification brings the window back.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completionHandler()
    }

    // MARK: Archive

    /// The folder for "Copy to a folder, then delete", picked in the usual Mac panel. The last one is offered again.
    private func chooseFolder(_ purpose: String, _ completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // Each purpose remembers its own last folder.
        let remembered: String
        var start: URL?
        switch purpose {
        case "local":
            panel.prompt = "Add Folder"
            panel.message = "Choose a folder on this Mac or an external drive. Photo Review lists its photos and videos, largest first; nothing in it changes until you choose."
            remembered = "localFolder"
            start = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        case "drive":
            panel.prompt = "Add Folder"
            panel.message = "Choose a folder in Google Drive. Files that are only in the cloud are listed without being downloaded."
            remembered = "driveFolder"
            #if !APP_STORE
            start = Folders.driveRoots.first.map { root in
                let mine = root.appendingPathComponent("My Drive", isDirectory: true)
                return FileManager.default.fileExists(atPath: mine.path) ? mine : root
            }
            #endif
        default:
            panel.prompt = "Copy Here"
            panel.message = "Choose where to copy the originals, for example a folder on an external drive. Photo Review makes a folder for each year inside it. The files keep their camera details, but not the titles, captions, keywords or albums from Photos."
            remembered = "archiveFolder"
        }
        if let last = UserDefaults.standard.string(forKey: remembered) { start = URL(fileURLWithPath: last) }
        if let start = start { panel.directoryURL = start }
        func chosen(_ response: NSApplication.ModalResponse) {
            guard response == .OK, let folder = panel.url else { return completion(nil) }
            #if APP_STORE
            do { try FolderAccess.shared.remember(folder) }
            catch {
                log("saving folder permission: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "Couldn't keep access to that folder"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return completion(nil)
            }
            #endif
            UserDefaults.standard.set(folder.path, forKey: remembered)
            completion(folder)
        }
        NSApp.activate(ignoringOtherApps: true)
        if window.isVisible {
            window.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for: window, completionHandler: chosen)
        } else {
            chosen(panel.runModal())
        }
    }

    // MARK: Updates

    #if APP_STORE
    private func scheduleUpdateChecks() {}
    @objc private func showPrivacy() {
        webView.load(URLRequest(url: home.appendingPathComponent("privacy")))
        window.makeKeyAndOrderFront(nil)
    }
    #else
    private func scheduleUpdateChecks() {
        updateTimer?.invalidate()
        guard UserDefaults.standard.bool(forKey: automaticUpdates) else { return }
        updates.check()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { _ in updates.check() }
    }

    @objc private func checkForUpdates() {
        updates.check { newer, problem in
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let newer = newer {
                    alert.messageText = "Photo Review \(newer.version) is available"
                    alert.informativeText = "You have \(updates.current). Download the new version and drag it into Applications, replacing this one."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(newer.page) }
                } else if let problem = problem {
                    alert.messageText = "Couldn't check for updates"
                    alert.informativeText = problem
                    alert.runModal()
                } else {
                    alert.messageText = "Photo Review is up to date"
                    alert.informativeText = "Version \(updates.current) is the newest."
                    alert.runModal()
                }
            }
        }
    }

    @objc private func toggleAutomaticUpdates(_ sender: NSMenuItem) {
        let on = !UserDefaults.standard.bool(forKey: automaticUpdates)
        UserDefaults.standard.set(on, forKey: automaticUpdates)
        sender.state = on ? .on : .off
        scheduleUpdateChecks()
    }

    #endif

    /// Quitting throws away a compression in progress, including a long download, so ask first.
    private func confirmQuit() -> Bool {
        if quitConfirmed || server?.hasActiveJobs != true { return true }
        let alert = NSAlert()
        alert.messageText = "Something is still being compressed"
        alert.informativeText = "Quitting now stops it and discards the progress so far, including any download from iCloud."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        quitConfirmed = alert.runModal() == .alertSecondButtonReturn
        return quitConfirmed
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmQuit() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmQuit() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Clicking the Dock icon brings the window back if it isn't showing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
