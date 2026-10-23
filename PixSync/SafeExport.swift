import Foundation

enum SafeExportPath {
  static func make(
    originalFilename: String,
    assetID: String,
    kind: ExportKind,
    date: Date,
    destination: URL,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
  ) -> String {
    let original = URL(fileURLWithPath: originalFilename)
    let stem = original.deletingPathExtension().lastPathComponent
    let ext = original.pathExtension.isEmpty ? "bin" : original.pathExtension
    let editedSuffix = kind == .edited ? "-edited" : ""
    let plain = "\(stem)\(editedSuffix).\(ext)"
    let shortID = String(assetID.suffix(6))
    let dateString = date.formatted(.iso8601.year().month().day())
    let candidates = [
      plain,
      "\(stem)-\(dateString)-\(shortID)\(editedSuffix).\(ext)",
    ]

    for candidate in candidates where !fileExists(destination.appendingPathComponent(candidate)) {
      return candidate
    }

    var index = 2
    while true {
      let candidate = "\(stem)-\(dateString)-\(shortID)\(editedSuffix)-\(index).\(ext)"
      if !fileExists(destination.appendingPathComponent(candidate)) { return candidate }
      index += 1
    }
  }
}

enum SafeExportFileCommitter {
  static func commit(
    _ temporaryURL: URL, to destinationURL: URL, fileManager: FileManager = .default
  ) throws {
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destinationURL.path])
    }
    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
  }
}
