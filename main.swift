import AVFoundation
import AppKit
import Network
import Photos
import VideoToolbox

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

// MARK: - Library

struct Item {
    let id: String
    let name: String
    let bytes: Int64
    let date: String
    let year: Int
    let isVideo: Bool
    let width: Int
    let height: Int
    let duration: Double
    let favorite: Bool
    /// Slo-mo, time-lapse, edited and similar, for display.
    let tags: [String]

    var json: [String: Any] {
        [
            "id": id, "name": name, "bytes": bytes, "date": date, "year": year, "video": isVideo,
            "w": width, "h": height, "dur": duration, "fav": favorite, "tags": tags,
        ]
    }
}

extension Item {
    /// Rebuilds an item from `json`, as stored in the measurement cache.
    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let name = json["name"] as? String,
            let bytes = (json["bytes"] as? NSNumber)?.int64Value
        else { return nil }
        self.init(
            id: id, name: name, bytes: bytes, date: json["date"] as? String ?? "", year: json["year"] as? Int ?? 0,
            isVideo: json["video"] as? Bool ?? false, width: json["w"] as? Int ?? 0, height: json["h"] as? Int ?? 0,
            duration: (json["dur"] as? NSNumber)?.doubleValue ?? 0, favorite: json["fav"] as? Bool ?? false,
            tags: json["tags"] as? [String] ?? [])
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
    private static let cacheVersion = 1
    private static let cacheLifetime: TimeInterval = 24 * 60 * 60

    func start() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { auth in
            switch auth {
            case .authorized:
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
        let idle = status == "ready"
        if idle {
            status = "updating"
            scanned = 0
        }
        lock.unlock()
        if idle { DispatchQueue.global(qos: .userInitiated).async { self.scan(replacing: true) } }
        return idle
    }

    private func scan(replacing: Bool) {
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
        for resource in resources {
            bytes += (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
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
        if asset.hasAdjustments { tags.append("edited") }
        // Not a public property, so only read it where it exists. A hint: it goes stale as Photos frees space.
        if let primary = primary, primary.responds(to: NSSelectorFromString("isLocallyAvailable")),
            primary.value(forKey: "locallyAvailable") as? Bool == true
        {
            tags.append("on this Mac")
        }
        return Item(
            id: asset.localIdentifier, name: primary?.originalFilename ?? "(unnamed)", bytes: bytes,
            date: date, year: year, isVideo: asset.mediaType == .video, width: asset.pixelWidth,
            height: asset.pixelHeight, duration: asset.duration, favorite: asset.isFavorite, tags: tags)
    }

    func query(kind: String, year: Int?, offset: Int, limit: Int) -> [String: Any] {
        lock.lock()
        let all = Array(items.values)
        var state: [String: Any] = ["status": status, "scanned": scanned, "total": total]
        state["measuredAt"] = measuredAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull()
        let stale = status == "ready" && (measuredAt.map { Date().timeIntervalSince($0) > Library.cacheLifetime } ?? false)
        lock.unlock()
        // Left running for more than a day, the app refreshes itself the next time someone looks.
        if stale { update() }

        var years: [Int: (bytes: Int64, count: Int)] = [:]
        var libraryBytes: Int64 = 0
        for item in all {
            libraryBytes += item.bytes
            years[item.year, default: (0, 0)].bytes += item.bytes
            years[item.year, default: (0, 0)].count += 1
        }
        let matches = all.filter { item in
            (kind == "all" || (kind == "video") == item.isVideo) && (year == nil || item.year == year)
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
        let page = matches.dropFirst(max(0, offset)).prefix(max(0, limit))

        var result = state
        result["libraryBytes"] = libraryBytes
        result["libraryCount"] = all.count
        result["matchCount"] = matches.count
        result["matchBytes"] = matches.reduce(Int64(0)) { $0 + $1.bytes }
        result["years"] = years.keys.sorted(by: >).map { ["year": $0, "bytes": years[$0]!.bytes, "count": years[$0]!.count] }
        result["items"] = page.map { $0.json }
        return result
    }

    func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
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
        // Once it has been answered, hand the screen back to whatever was in front, normally the browser,
        // rather than leaving this app's little window sitting on top.
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

    /// Target video bitrate in bits per second. index.html mirrors this for its estimate.
    func bitrate(width: Int, height: Int, fps: Double) -> Double {
        let base = quality == "low" ? 6e6 : quality == "medium" ? 12e6 : 24e6  // HEVC at 4K, 30 fps
        let pixels = Double(width * height) / (3840 * 2160)
        return base * pow(pixels, 0.75) * pow(max(fps, 1) / 30, 0.6) * (hevc ? 1 : 1.7)
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
    let bitrate = settings.bitrate(width: target.width, height: target.height, fps: targetFps)
    let sourceRate = Double(videoTrack.estimatedDataRate)
    if sourceRate > 0, bitrate > sourceRate * 0.8 { throw ShrinkError.nothingToGain }

    let format = videoTrack.formatDescriptions.first.map { $0 as! CMFormatDescription }
    func tag(_ key: CFString) -> String? {
        format.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: key) as? String }
    }
    let primaries = tag(kCMFormatDescriptionExtension_ColorPrimaries)
    let transfer = tag(kCMFormatDescriptionExtension_TransferFunction)
    let matrix = tag(kCMFormatDescriptionExtension_YCbCrMatrix)
    let hdr = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
    // HDR needs 10-bit HEVC; H.264 would flatten it.
    let hevc = settings.hevc || hdr
    // ProRes and 10-bit HEVC originals keep their extra precision whenever the result is HEVC.
    let depth = format.flatMap {
        (CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
    }
    let proRes = [
        kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
        kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
    ].contains(format.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0)
    let tenBit = hevc && (hdr || (depth ?? 8) > 8 || proRes)

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

final class Job {
    let id: Int
    let assetId: String
    let name: String
    let originalBytes: Int64
    let original: Item
    let settings: ShrinkSettings
    /// Encode only and leave the file in the temporary folder, without touching the library.
    let dryRun: Bool
    /// Ask Photos to delete the original once the smaller copy is safely in the library.
    let deleteOriginal: Bool
    /// What became of that request: "" (not asked for), pending, deleted or kept.
    var deletion = ""
    var state = "queued"  // queued, downloading, encoding, saving, done, skipped, failed, cancelled
    var progress = 0.0
    var message = ""
    var newBytes: Int64 = 0
    var newItem: Item?
    var cancelled = false
    var originalDeleted = false
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
        [
            "type": "shrink", "outcome": state, "message": message, "assetId": assetId, "name": name,
            "originalBytes": originalBytes, "newBytes": newBytes, "newId": newItem?.id ?? "",
            "settings": settings.json, "downloadSeconds": Int(phases["downloading"] ?? 0),
            "encodeSeconds": Int(phases["encoding"] ?? 0),
        ]
    }

    init(id: Int, item: Item, settings: ShrinkSettings, dryRun: Bool, deleteOriginal: Bool) {
        self.id = id
        self.deleteOriginal = deleteOriginal && !dryRun
        assetId = item.id
        name = item.name
        originalBytes = item.bytes
        original = item
        self.settings = settings
        self.dryRun = dryRun
    }

    var isActive: Bool { ["queued", "downloading", "encoding", "saving"].contains(state) }

    var json: [String: Any] {
        [
            "id": id, "assetId": assetId, "name": name, "state": state, "progress": progress, "message": message,
            "originalBytes": originalBytes, "newBytes": newBytes, "newItem": newItem?.json ?? NSNull(),
            "item": original.json, "dryRun": dryRun, "settings": settings.json, "originalDeleted": originalDeleted,
            "seconds": Int(Date().timeIntervalSince(stateSince)), "remaining": remainingSeconds ?? NSNull(),
            "deleteOriginal": deleteOriginal, "deletion": deletion,
        ]
    }
}

/// Runs shrink jobs one at a time.
final class Converter {
    private let library: Library
    private let history: History
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "shrink", qos: .userInitiated)
    private var jobs: [Job] = []
    private var nextId = 1
    /// Finished jobs whose originals are to be deleted once nothing else is running.
    private var awaitingDeletion: [Job] = []

    init(library: Library, history: History) {
        self.library = library
        self.history = history
    }

    func enqueue(ids: [String], settings: ShrinkSettings, dryRun: Bool, deleteOriginal: Bool) -> Int {
        var added = 0
        for id in ids {
            guard let item = library.item(id), item.isVideo else { continue }
            lock.lock()
            let busy = jobs.contains { $0.assetId == id && $0.isActive }
            let job = Job(id: nextId, item: item, settings: settings, dryRun: dryRun, deleteOriginal: deleteOriginal)
            if !busy {
                // A fresh attempt replaces the rows left by earlier ones that didn't finish.
                jobs.removeAll { $0.assetId == id && ["failed", "cancelled", "skipped"].contains($0.state) }
                nextId += 1
                jobs.append(job)
            }
            lock.unlock()
            if busy { continue }
            added += 1
            queue.async { self.run(job) }
        }
        return added
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
    }

    var hasActiveJobs: Bool {
        lock.lock()
        defer { lock.unlock() }
        return jobs.contains { $0.isActive }
    }

    /// Deletes library items through Photos (which asks the user to confirm) and records what was removed.
    func delete(ids: [String], completion: @escaping (Bool, String?) -> Void) {
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
        if idle { awaitingDeletion = [] }
        lock.unlock()
        guard !batch.isEmpty else { return }
        delete(ids: batch.map { $0.assetId }) { ok, error in
            self.update { _ in
                for job in batch {
                    job.deletion = ok ? "deleted" : "kept"
                    if !ok { job.message = error ?? "Photos didn't delete it." }
                }
            }
        }
    }

    /// Notes which finished jobs have had their original deleted, so the page stops offering to select it.
    func originalsDeleted(_ ids: [String]) {
        update { jobs in
            for job in jobs where ids.contains(job.assetId) { job.originalDeleted = true }
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
    }

    private func isCancelled(_ job: Job) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return job.cancelled
    }

    private func run(_ job: Job) {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Shrinking a video")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("photo-review-\(UUID().uuidString).mov")
        defer { if !job.dryRun { try? FileManager.default.removeItem(at: output) } }
        // Cancelled while it was waiting: already marked, nothing to do.
        if isCancelled(job) { return }
        do {
            guard let asset = library.asset(job.assetId), asset.mediaType == .video else {
                throw ShrinkError.failed("This video is no longer in the library.")
            }
            // Cheap check before a long download. Assumes 30 fps when the rate is kept, which never overestimates much.
            let target = job.settings.size(width: asset.pixelWidth, height: asset.pixelHeight)
            let rate = job.settings.bitrate(width: target.width, height: target.height, fps: job.settings.fps ?? 30)
            if rate * asset.duration / 8 > Double(job.originalBytes) * 0.8 { throw ShrinkError.nothingToGain }

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
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            let newBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard newBytes > 0, Double(newBytes) < Double(job.originalBytes) * 0.9 else { throw ShrinkError.nothingToGain }

            var newItem: Item?
            if !job.dryRun {
                set(job, "saving")
                newItem = try save(output, replacing: asset, name: job.name)
            }
            update { _ in
                job.newBytes = newBytes
                job.newItem = newItem
                guard job.deleteOriginal, let copy = newItem else { return }
                // Only let go of an original whose copy runs the same length; anything else needs a human look.
                if abs(copy.duration - asset.duration) < 1 {
                    job.deletion = "pending"
                    awaitingDeletion.append(job)
                } else {
                    job.deletion = "kept"
                    job.message = "The copy's length differs from the original's, so check it before deleting."
                }
            }
            let note = job.dryRun ? output.path : job.message
            set(job, "done", message: note)
        } catch let error as ShrinkError {
            set(job, error.state, message: error.message)
        } catch {
            set(job, "failed", message: error.localizedDescription)
        }
        deleteOriginalsIfIdle()
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

    /// Adds the encoded file to Photos as a new video carrying the original's date, location, favorite flag and albums.
    private func save(_ file: URL, replacing original: PHAsset, name: String) throws -> Item {
        var newId: String?
        try PHPhotoLibrary.shared().performChangesAndWait {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = (name as NSString).deletingPathExtension + " (shrunk).mov"
            options.shouldMoveFile = true
            request.addResource(with: .video, fileURL: file, options: options)
            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite
            newId = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = newId, let created = library.asset(id) else {
            throw ShrinkError.failed("Photos didn't accept the new video.")
        }
        // Best effort: an album that refuses the addition shouldn't undo the new video.
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
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] { query[item.name] = item.value ?? "" }
        method = String(parts[0])
        path = url.path
        self.query = query
        self.headers = headers
        body = data.subdata(in: headEnd.upperBound..<(headEnd.upperBound + length))
    }
}

final class Server {
    private let library: Library
    private let converter: Converter
    private let history = History()
    private let queue = DispatchQueue(label: "http", attributes: .concurrent)
    private var listener: NWListener?
    private let page: String
    private let statsPage: String
    private let icon: Data
    /// Called on the main thread with nil once the port is open, or with the reason it couldn't be.
    var onStart: ((String?) -> Void)?
    var hasActiveJobs: Bool { converter.hasActiveJobs }

    init(library: Library) {
        self.library = library
        converter = Converter(library: library, history: history)
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
        case ("GET", "/stats"):
            send(connection, 200, "text/html; charset=utf-8", Data(statsPage.utf8), ["Cache-Control": "no-store"])
        case ("GET", "/api/stats"):
            // Each finished shrink also says whether its original and its smaller copy are still in the library.
            let events = history.all().map { event -> [String: Any] in
                guard event["type"] as? String == "shrink", event["outcome"] as? String == "done" else { return event }
                var event = event
                event["originalExists"] = library.item(event["assetId"] as? String ?? "") != nil
                event["copyExists"] = library.item(event["newId"] as? String ?? "") != nil
                return event
            }
            sendJSON(connection, ["ready": library.isReady, "events": events])
        case ("GET", "/api/items"):
            let result = library.query(
                kind: request.query["kind"] ?? "all", year: Int(request.query["year"] ?? ""),
                offset: Int(request.query["offset"] ?? "") ?? 0, limit: min(Int(request.query["limit"] ?? "") ?? 60, 2000))
            sendJSON(connection, result)
        case ("GET", "/thumb"):
            let size = min(max(Int(request.query["size"] ?? "") ?? 480, 64), 2400)
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
                dryRun: payload["dryRun"] as? Bool ?? false, deleteOriginal: payload["deleteOriginal"] as? Bool ?? false)
            sendJSON(connection, ["ok": started > 0, "started": started, "error": started > 0 ? "" : "No videos to shrink."])
        case ("GET", "/api/jobs"):
            sendJSON(connection, ["jobs": converter.list()])
        case ("POST", "/api/update"):
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
        // Only videos have something to play; anything else is simply not found.
        guard library.item(request.query["id"] ?? "")?.isVideo == true else {
            return send(connection, 404, "text/plain", Data("not a video".utf8))
        }
        library.videoURL(id: request.query["id"] ?? "") { url in
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let library = Library()
    private var server: Server?
    private var window: NSWindow!
    private var label: NSTextField!
    private var button: NSButton!
    private var quitConfirmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Photo Review", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu

        label = NSTextField(wrappingLabelWithString: "Starting…")
        // Selectable text is what makes a link inside it clickable.
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        button = NSButton(title: "Open in Browser", target: self, action: #selector(openBrowser))
        button.isEnabled = false
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Photo Review"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)

        let server = Server(library: library)
        server.onStart = { [weak self] problem in self?.started(problem) }
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
            button.isEnabled = false
            label.stringValue =
                "Photo Review couldn't start on port \(port): \(problem)\n\nAnother copy may already be running. Close this window to quit."
            return
        }
        let address = "http://127.0.0.1:\(port)"
        let text = "Photo Review is running at \(address)\n\nKeep this window open while you review. Close it to quit."
        let message = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor])
        message.addAttributes(
            [.link: URL(string: address + "/")!, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue],
            range: (text as NSString).range(of: address))
        label.attributedStringValue = message
        button.isEnabled = true
        library.start()
        if !CommandLine.arguments.contains("--no-open") { openBrowser() }
    }

    @objc private func openBrowser() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(port)/")!)
    }

    /// Quitting throws away a shrink in progress, including a long download, so ask first.
    private func confirmQuit() -> Bool {
        if quitConfirmed || server?.hasActiveJobs != true { return true }
        let alert = NSAlert()
        alert.messageText = "A video is still being shrunk"
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
