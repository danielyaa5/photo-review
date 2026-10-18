import AppKit
import Photos
import UniformTypeIdentifiers

/// The selected library is used only for read-only metadata. Media operations still go through PhotoKit.
final class PhotosSizeAccess {
    static let shared = PhotosSizeAccess()
    private let lock = NSLock()
    private var library: URL?
    private var index = PhotosSizeIndex()
    private var problem: String?
    private let bookmarkKey = "photosSizeLibraryBookmark"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            library = url
            if stale { try saveBookmark(url) }
        } catch { problem = "Choose your Photos library again to restore access to its size records." }
    }

    private func saveBookmark(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    func select(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let fresh = try PhotosSizeIndex.read(library: url)
            // Prevent selecting an unrelated library. Each actual lookup also requires the same asset UUID.
            let visible = PHAsset.fetchAssets(with: nil)
            if visible.count > 0 {
                var matched = false
                visible.enumerateObjects { asset, _, stop in
                    let uuid = String(asset.localIdentifier.split(separator: "/")[0]).uppercased()
                    if fresh.assets[uuid] != nil { matched = true; stop.pointee = true }
                }
                guard matched else {
                    throw NSError(domain: "PhotosSizeAccess", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "This isn't the library Photos is currently using. Choose your System Photo Library."])
                }
            }
            try saveBookmark(url)
            lock.lock()
            let old = library
            library = url; index = fresh; problem = nil
            lock.unlock()
            old?.stopAccessingSecurityScopedResource()
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func reload() {
        lock.lock()
        defer { lock.unlock() }
        guard let library = library else { return }
        do { index = try PhotosSizeIndex.read(library: library); problem = nil }
        catch { index = PhotosSizeIndex(); problem = error.localizedDescription }
    }

    func bytes(_ resource: PHAssetResource, asset: PHAsset? = nil) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        if let asset = asset {
            let uuid = String(asset.localIdentifier.split(separator: "/")[0]).uppercased()
            guard let record = index.assets[uuid] else { return nil }
            switch (record.modifiedAt, asset.modificationDate?.timeIntervalSinceReferenceDate) {
            case (nil, nil): break
            case let (stored?, current?) where abs(stored - current) < 0.001: break
            default: return nil // A stale clone or an edit during measurement must not supply stale sizes.
            }
        }
        return index.bytes(assetID: resource.assetLocalIdentifier, resourceType: resource.type.rawValue,
            isRAW: UTType(resource.uniformTypeIdentifier)?.conforms(to: .rawImage) ?? false)
    }

    var state: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["sizeLibrarySelected": library != nil, "sizeLibraryError": problem ?? ""]
    }

    #if DEBUG
    /// Compares the fallback with public size metadata without requesting any media.
    func audit(limit: Int = 0, ids: [String] = []) -> [String: Any] {
        var counts: [String: Int] = [:]
        var examples: [[String: Any]] = []
        let assets = ids.isEmpty ? PHAsset.fetchAssets(with: nil) : PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        assets.enumerateObjects { asset, position, stop in
            if limit > 0, position >= limit { stop.pointee = true; return }
            autoreleasepool {
                let resources = PHAssetResource.assetResources(for: asset)
                for resource in resources {
                    let fallback = self.bytes(resource, asset: asset)
                    var expected: Int64?
                    if #available(macOS 27, *) { expected = resource.dataSize.map(Int64.init) }
                    let outcome = expected == nil ? "publicUnknown" : fallback == nil ? "missing" : fallback == expected ? "match" : "mismatch"
                    counts["\(resource.type.rawValue):\(outcome)", default: 0] += 1
                    if (outcome == "mismatch" || outcome == "missing"), examples.filter({ $0["type"] as? Int == resource.type.rawValue }).count < 4 {
                        examples.append(["type": resource.type.rawValue, "expected": expected as Any? ?? NSNull(),
                            "actual": fallback as Any? ?? NSNull(), "id": asset.localIdentifier,
                            "filename": resource.originalFilename,
                            "resources": resources.map { r -> [String: Any] in
                                var size: Int64?
                                if #available(macOS 27, *) { size = r.dataSize.map(Int64.init) }
                                return ["type": r.type.rawValue, "name": r.originalFilename, "bytes": size as Any? ?? NSNull()]
                            }])
                    }
                }
            }
        }
        return ["assets": assets.count, "resourceCounts": counts, "mismatches": examples]
    }
    #endif
}
