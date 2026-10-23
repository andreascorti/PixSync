import Foundation
import Photos

enum ExportKind: String, Codable, CaseIterable, Identifiable {
  case original
  case edited

  var id: String { rawValue }
  var title: String { self == .original ? "Original" : "Edited" }
}

struct ExportRecord: Codable, Identifiable {
  var id: String { "\(assetID)|\(kind.rawValue)" }
  let assetID: String
  let kind: ExportKind
  let relativePath: String
  let filename: String
  let modificationDate: Date?
  let fingerprint: String
}

struct RemovedExport: Identifiable, Codable {
  var id: String { "\(assetID)|\(relativePath)" }
  let assetID: String
  let filename: String
  let relativePath: String
  let detectedAt: Date
}

struct AmbiguousMatch: Identifiable {
  let id = UUID()
  let filename: String
  let candidateCount: Int
}

struct DestinationItem: Codable, Identifiable {
  var id: String { relativePath }
  let relativePath: String
  let isDirectory: Bool
}

struct SyncSummary {
  var exported = 0
  var alreadyPresent = 0
  var removedFromPhotos = 0
  var missingOnDisk = 0
  var errors: [String] = []
}

extension PHAsset {
  var pixSyncDate: Date { creationDate ?? modificationDate ?? .distantPast }
}
