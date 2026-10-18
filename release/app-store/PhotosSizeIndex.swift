import Foundation
import SQLite3

/// Metadata only. Never opens original media or writes to the Photos database.
/// Photos' schema is undocumented: unknown or ambiguous resource layouts return nil.
struct PhotosSizeIndex {
    struct Resource {
        let kind: Int, version: Int, subtype: Int
        let bytes: Int64
    }
    struct Asset {
        var resources: [Resource] = []
        var modifiedAt: TimeInterval?
    }
    var assets: [String: Asset] = [:]
    var library: URL?

    func bytes(assetID: String, resourceType: Int, isRAW: Bool = false) -> Int64? {
        let uuid = String(assetID.split(separator: "/").first ?? "").uppercased()
        guard let asset = assets[uuid] else { return nil }
        if resourceType == 7 {
            // The current adjustment plist differs from the original imported .AAE sidecar.
            // Read its logical file size only, never its contents or any media. Validate the path component.
            guard UUID(uuidString: uuid) != nil, let library = library else { return nil }
            let file = library.appendingPathComponent("resources/renders/\(uuid.prefix(1))/\(uuid).plist")
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize, size > 0 else { return nil }
            return Int64(size)
        }
        let shape: (Int, Int, Int)
        switch resourceType {
        case 1, 4:
            // RAW+JPEG can expose either member as the primary photo. Match the resource's content type,
            // not its position in PhotoKit's array. Standalone RAW originals use the normal still slot.
            if isRAW && asset.resources.contains(where: { $0.kind == 4 && $0.version == 0 && $0.subtype == 17 }) {
                shape = (4, 0, 17)
            } else { shape = (0, 0, 1) }
        case 2: shape = (1, 0, 1)   // Original video
        case 3: shape = (2, 0, 1)   // Audio
        case 5: shape = (0, 2, 2)   // Edited still
        case 6: shape = (1, 2, 16)  // Edited video
        case 110: shape = (7, 2, 14) // Secondary adjustment data returned by PhotoKit
        case 16: shape = (5, 0, 22) // Original adjustment sidecar returned by PhotoKit
        case 8: shape = (0, 1, 15)  // Adjustment base still
        case 9: shape = (3, 0, 18)  // Live Photo original motion
        case 10: shape = (3, 2, 19) // Live Photo edited motion
        case 11: shape = (3, 1, 20) // Live Photo adjustment base motion
        default: return nil        // Unverified resource layouts
        }
        let candidates = asset.resources.filter { ($0.kind, $0.version, $0.subtype) == shape }
        guard !candidates.isEmpty, candidates.allSatisfy({ $0.bytes > 0 }) else { return nil }
        let sizes = Set(candidates.map(\.bytes))
        return sizes.count == 1 ? sizes.first : nil
    }

    static func read(library: URL) throws -> PhotosSizeIndex {
        var db: OpaquePointer?
        let file = library.appendingPathComponent("database/Photos.sqlite")
        let opened = sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        func failure() -> NSError {
            NSError(domain: "PhotosSizeIndex", code: Int(sqlite3_errcode(db)), userInfo:
                [NSLocalizedDescriptionKey: "Couldn't read size records from this Photos library. Choose the current library again; its format may not be supported."])
        }
        guard opened == SQLITE_OK, sqlite3_db_readonly(db, "main") == 1 else { throw failure() }
        sqlite3_busy_timeout(db, 1500)
        // A normal read transaction includes committed WAL records. Do not use immutable=1 on a live library.
        guard sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN", nil, nil, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        let sql = """
            SELECT a.ZUUID, r.ZRESOURCETYPE, r.ZVERSION, r.ZDATASTORESUBTYPE, r.ZDATALENGTH, a.ZMODIFICATIONDATE
            FROM ZASSET a JOIN ZINTERNALRESOURCE r ON r.ZASSET = a.Z_PK
            WHERE r.ZDATASTORESUBTYPE IN (1,2,14,15,16,17,18,19,20,22)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var index = PhotosSizeIndex()
        index.library = library
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                let uuid = String(cString: text).uppercased()
                index.assets[uuid, default: Asset()].modifiedAt = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 5)
                index.assets[uuid, default: Asset()].resources.append(Resource(
                    kind: Int(sqlite3_column_int(statement, 1)), version: Int(sqlite3_column_int(statement, 2)),
                    subtype: Int(sqlite3_column_int(statement, 3)), bytes: sqlite3_column_int64(statement, 4)))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw failure() }
        return index
    }
}
