import CryptoKit
import Foundation
import Photos

@MainActor
final class SyncStore: ObservableObject {
  @Published private(set) var records: [String: ExportRecord] = [:]
  @Published private(set) var removedExports: [RemovedExport] = []
  @Published private(set) var unmatchedDestinationItems: [DestinationItem] = []
  @Published private(set) var ambiguousMatches: [AmbiguousMatch] = []
  private var dismissedRemovalIDs = Set<String>()

  private let storeURL: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(storeURL: URL? = nil) {
    if let storeURL {
      self.storeURL = storeURL
      try? FileManager.default.createDirectory(
        at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    } else {
      let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      let directory = appSupport.appendingPathComponent("PixSync", isDirectory: true)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      self.storeURL = directory.appendingPathComponent("sync-state.json")
    }
    load()
  }

  func record(for assetID: String, kind: ExportKind) -> ExportRecord? {
    records["\(assetID)|\(kind.rawValue)"]
  }

  func save(_ record: ExportRecord) {
    records[record.id] = record
    persist()
  }

  func setRemoved(_ values: [RemovedExport]) {
    removedExports = values.filter { !dismissedRemovalIDs.contains($0.id) }
    persist()
  }

  func dismissRemoval(_ item: RemovedExport) {
    dismissedRemovalIDs.insert(item.id)
    removedExports.removeAll { $0.id == item.id }
    persist()
  }

  func addAmbiguous(_ values: [AmbiguousMatch]) { ambiguousMatches = values }

  func reconcileExistingFiles(in root: URL, assets: [PHAsset]) async -> (
    matched: Int, unmatched: Int
  ) {
    let known = Set(records.values.map(\.relativePath))
    var assetsByName: [String: [PHAsset]] = [:]
    for (index, asset) in assets.enumerated() {
      for resource in PHAssetResource.assetResources(for: asset)
      where resource.type == .photo || resource.type == .video {
        assetsByName[resource.originalFilename, default: []].append(asset)
      }
      if index % 256 == 255 { try? await Task.sleep(for: .milliseconds(1)) }
    }
    var matched = 0
    var unmatched = 0
    var unmatchedItems: [DestinationItem] = []
    var uncertain: [AmbiguousMatch] = []
    var matchedRecords: [ExportRecord] = []
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return (0, 0) }
    var scannedCount = 0
    while let file = enumerator.nextObject() as? URL {
      scannedCount += 1
      if scannedCount % 256 == 0 { try? await Task.sleep(for: .milliseconds(1)) }
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
      let relative = String(file.path.dropFirst(root.path.count + 1))
      if values?.isDirectory == true {
        unmatched += 1
        unmatchedItems.append(DestinationItem(relativePath: relative, isDirectory: true))
        continue
      }
      guard values?.isRegularFile == true else {
        continue
      }
      guard !known.contains(relative) else { continue }
      let candidates = assetsByName[file.lastPathComponent] ?? []
      if candidates.count == 1, let asset = candidates.first {
        let record = ExportRecord(
          assetID: asset.localIdentifier, kind: .original, relativePath: relative,
          filename: file.lastPathComponent, modificationDate: asset.modificationDate,
          fingerprint: fingerprint(asset))
        matchedRecords.append(record)
        matched += 1
      } else {
        unmatched += 1
        unmatchedItems.append(DestinationItem(relativePath: relative, isDirectory: false))
        if candidates.count > 1 {
          uncertain.append(
            AmbiguousMatch(filename: file.lastPathComponent, candidateCount: candidates.count))
        }
      }
    }
    for record in matchedRecords { records[record.id] = record }
    if !matchedRecords.isEmpty { persist() }
    setUnmatchedDestinationItems(unmatchedItems)
    addAmbiguous(uncertain)
    return (matched, unmatched)
  }

  func setUnmatchedDestinationItems(_ values: [DestinationItem]) {
    unmatchedDestinationItems = values.sorted {
      $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
    persist()
  }

  var unmatchedDestinationSummary: String? {
    guard !unmatchedDestinationItems.isEmpty else { return nil }
    let fileCount = unmatchedDestinationItems.filter { !$0.isDirectory }.count
    let folderCount = unmatchedDestinationItems.count - fileCount
    let itemCount = unmatchedDestinationItems.count
    var parts: [String] = []
    if fileCount > 0 { parts.append("\(fileCount) \(fileCount == 1 ? "file" : "files")") }
    if folderCount > 0 { parts.append("\(folderCount) \(folderCount == 1 ? "folder" : "folders")") }
    let plural = itemCount == 1 ? "isn't" : "aren't"
    let pronoun = itemCount == 1 ? "It is" : "They are"
    return
      "\(parts.joined(separator: " and ")) in the destination \(plural) in Photos. \(pronoun) left untouched."
  }

  func fingerprint(_ asset: PHAsset) -> String {
    let details =
      "\(asset.localIdentifier)|\(asset.modificationDate?.timeIntervalSince1970 ?? 0)|\(asset.pixelWidth)x\(asset.pixelHeight)|\(asset.mediaType.rawValue)"
    return SHA256.hash(data: Data(details.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func load() {
    guard let data = try? Data(contentsOf: storeURL),
      let state = try? decoder.decode(PersistedState.self, from: data)
    else { return }
    records = Dictionary(uniqueKeysWithValues: state.records.map { ($0.id, $0) })
    removedExports = state.removed
    unmatchedDestinationItems = state.unmatchedDestinationItems
    dismissedRemovalIDs = state.dismissedRemovalIDs
  }

  private func persist() {
    let state = PersistedState(
      records: Array(records.values), removed: removedExports,
      unmatchedDestinationItems: unmatchedDestinationItems,
      dismissedRemovalIDs: dismissedRemovalIDs)
    guard let data = try? encoder.encode(state) else { return }
    try? data.write(to: storeURL, options: .atomic)
  }
}

private struct PersistedState: Codable {
  let records: [ExportRecord]
  let removed: [RemovedExport]
  let unmatchedDestinationItems: [DestinationItem]
  let dismissedRemovalIDs: Set<String>

  private enum CodingKeys: String, CodingKey {
    case records, removed, unmatchedDestinationItems, dismissedRemovalIDs
  }

  init(
    records: [ExportRecord], removed: [RemovedExport],
    unmatchedDestinationItems: [DestinationItem] = [], dismissedRemovalIDs: Set<String> = []
  ) {
    self.records = records
    self.removed = removed
    self.unmatchedDestinationItems = unmatchedDestinationItems
    self.dismissedRemovalIDs = dismissedRemovalIDs
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    records = try values.decode([ExportRecord].self, forKey: .records)
    removed = try values.decode([RemovedExport].self, forKey: .removed)
    unmatchedDestinationItems =
      try values.decodeIfPresent([DestinationItem].self, forKey: .unmatchedDestinationItems) ?? []
    dismissedRemovalIDs =
      try values.decodeIfPresent(Set<String>.self, forKey: .dismissedRemovalIDs) ?? []
  }
}
