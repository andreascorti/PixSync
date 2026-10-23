import Foundation
import XCTest

@MainActor
final class SafeExportTests: XCTestCase {
  func testExportPathUsesOriginalNameWhenAvailable() {
    let destination = URL(fileURLWithPath: "/tmp/photos", isDirectory: true)

    let path = SafeExportPath.make(
      originalFilename: "IMG_001.heic",
      assetID: "asset-123456",
      kind: .original,
      date: Date(timeIntervalSince1970: 0),
      destination: destination,
      fileExists: { _ in false }
    )

    XCTAssertEqual(path, "IMG_001.heic")
  }

  func testExportPathChoosesUnusedDeterministicNameOnCollision() {
    let destination = URL(fileURLWithPath: "/tmp/photos", isDirectory: true)
    let date = Date(timeIntervalSince1970: 0)
    let existing = Set([
      "IMG_001.heic",
      "IMG_001-1970-01-01-123456.heic",
    ])

    let path = SafeExportPath.make(
      originalFilename: "IMG_001.heic",
      assetID: "asset-123456",
      kind: .original,
      date: date,
      destination: destination,
      fileExists: { existing.contains($0.lastPathComponent) }
    )

    XCTAssertEqual(path, "IMG_001-1970-01-01-123456-2.heic")
  }

  func testEditedExportGetsDistinctFilename() {
    let destination = URL(fileURLWithPath: "/tmp/photos", isDirectory: true)

    let path = SafeExportPath.make(
      originalFilename: "IMG_001.heic",
      assetID: "asset-123456",
      kind: .edited,
      date: Date(timeIntervalSince1970: 0),
      destination: destination,
      fileExists: { _ in false }
    )

    XCTAssertEqual(path, "IMG_001-edited.heic")
  }

  func testCommitNeverOverwritesAnExistingDestinationFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let temporary = directory.appendingPathComponent("export.partial")
    let destination = directory.appendingPathComponent("photo.heic")
    try Data("new export".utf8).write(to: temporary)
    try Data("existing user photo".utf8).write(to: destination)

    XCTAssertThrowsError(try SafeExportFileCommitter.commit(temporary, to: destination))
    XCTAssertEqual(try Data(contentsOf: destination), Data("existing user photo".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
  }

  func testCommitMovesNewExportIntoPlace() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let temporary = directory.appendingPathComponent("export.partial")
    let destination = directory.appendingPathComponent("photo.heic")
    let bytes = Data("exported photo".utf8)
    try bytes.write(to: temporary)

    try SafeExportFileCommitter.commit(temporary, to: destination)

    XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    XCTAssertEqual(try Data(contentsOf: destination), bytes)
  }

  func testDismissedRemovedPhotoAlertStaysDismissedAfterReload() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let storeURL = directory.appendingPathComponent("sync-state.json")
    let record = ExportRecord(
      assetID: "photos-local-id",
      kind: .original,
      relativePath: "IMG_1234.heic",
      filename: "IMG_1234.heic",
      modificationDate: nil,
      fingerprint: "fingerprint"
    )
    let removed = RemovedExport(
      assetID: record.assetID,
      filename: record.filename,
      relativePath: record.relativePath,
      detectedAt: Date(timeIntervalSince1970: 0)
    )

    let firstStore = SyncStore(storeURL: storeURL)
    firstStore.save(record)
    firstStore.setRemoved([removed])
    firstStore.dismissRemoval(removed)

    let reloadedStore = SyncStore(storeURL: storeURL)
    reloadedStore.setRemoved([removed])

    XCTAssertTrue(reloadedStore.removedExports.isEmpty)
    XCTAssertEqual(
      reloadedStore.record(for: record.assetID, kind: .original)?.relativePath, record.relativePath)
  }
}
