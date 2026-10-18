import Foundation
import SQLite3

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root.appendingPathComponent("database"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let file = root.appendingPathComponent("database/Photos.sqlite")
var db: OpaquePointer?
require(sqlite3_open(file.path, &db) == SQLITE_OK, "fixture open")
let setup = """
PRAGMA journal_mode=WAL;
CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZMODIFICATIONDATE REAL);
CREATE TABLE ZINTERNALRESOURCE (ZASSET INTEGER, ZRESOURCETYPE INTEGER, ZVERSION INTEGER, ZDATASTORESUBTYPE INTEGER, ZDATALENGTH INTEGER);
INSERT INTO ZASSET VALUES (1,'TEST-ASSET',0);
INSERT INTO ZINTERNALRESOURCE VALUES (1,1,0,1,8104934109), (1,1,2,16,6500000000), (1,5,0,22,1333),
 (1,3,0,18,3766192), (1,7,2,14,20033), (1,3,2,19,2000000), (1,0,0,4,99999);
"""
require(sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK, "fixture setup")
// Keep the writer open so the read must include committed WAL data.
let before = try Data(contentsOf: file)
let index = try PhotosSizeIndex.read(library: root)
require(index.bytes(assetID: "test-asset/L0/001", resourceType: 2) == 8104934109, "64-bit original")
require(index.bytes(assetID: "TEST-ASSET", resourceType: 6) == 6500000000, "edited resource")
require(index.bytes(assetID: "TEST-ASSET", resourceType: 9) == 3766192, "Live Photo motion")
require(index.bytes(assetID: "TEST-ASSET", resourceType: 10) == 2000000, "edited motion")
require(index.bytes(assetID: "TEST-ASSET", resourceType: 110) == 20033, "secondary adjustment data")
require(index.bytes(assetID: "TEST-ASSET", resourceType: 16) == 1333, "original adjustment sidecar")
require(index.bytes(assetID: "TEST-ASSET", resourceType: 19) == nil, "unknown layouts never guessed")
require(index.bytes(assetID: "WRONG-LIBRARY", resourceType: 2) == nil, "wrong library")
let after = try Data(contentsOf: file)
require(after == before, "source unchanged")
require(sqlite3_exec(db, "INSERT INTO ZINTERNALRESOURCE VALUES (1,1,0,1,42)", nil, nil, nil) == SQLITE_OK, "ambiguous fixture")
let ambiguous = try PhotosSizeIndex.read(library: root)
require(ambiguous.bytes(assetID: "TEST-ASSET", resourceType: 2) == nil, "conflicting sizes rejected")
require(sqlite3_exec(db, "INSERT INTO ZASSET VALUES (2,'RAW-PAIR',0); INSERT INTO ZINTERNALRESOURCE VALUES (2,0,0,1,1234567),(2,4,0,17,30000000)", nil, nil, nil) == SQLITE_OK, "RAW pair fixture")
let pair = try PhotosSizeIndex.read(library: root)
require(pair.bytes(assetID: "RAW-PAIR", resourceType: 1) == 1234567, "JPEG primary")
require(pair.bytes(assetID: "RAW-PAIR", resourceType: 4, isRAW: true) == 30000000, "RAW alternate")
require(pair.bytes(assetID: "RAW-PAIR", resourceType: 1, isRAW: true) == 30000000, "RAW primary")
require(pair.bytes(assetID: "RAW-PAIR", resourceType: 4) == 1234567, "JPEG alternate")
let uuid = "00000000-0000-0000-0000-000000000001"
let render = root.appendingPathComponent("resources/renders/0")
try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
try Data(repeating: 0, count: 2468).write(to: render.appendingPathComponent(uuid + ".plist"))
require(sqlite3_exec(db, "INSERT INTO ZASSET VALUES (3,'\(uuid)',0); INSERT INTO ZINTERNALRESOURCE VALUES (3,5,0,22,1333)", nil, nil, nil) == SQLITE_OK, "adjustment fixture")
let edited = try PhotosSizeIndex.read(library: root)
require(edited.bytes(assetID: uuid, resourceType: 7) == 2468, "current adjustment file size")
require(edited.bytes(assetID: uuid, resourceType: 16) == 1333, "original adjustment kept separate")
require(edited.bytes(assetID: "../outside", resourceType: 7) == nil, "invalid path component rejected")
require(sqlite3_exec(db, "DROP TABLE ZINTERNALRESOURCE", nil, nil, nil) == SQLITE_OK, "unsupported schema fixture")
do { _ = try PhotosSizeIndex.read(library: root); fatalError("unsupported schema accepted") } catch {}
sqlite3_close(db)
print("PASS: 64-bit sizes, edited and Live resources, RAW+JPEG switching, adjustment files, WAL snapshot, unsupported schemas, ambiguous records, wrong library, read-only source")
