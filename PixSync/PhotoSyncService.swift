import AppKit
import Foundation
@preconcurrency import Photos

@MainActor
final class PhotoSyncService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
  @Published var isSyncing = false
  @Published var progress = 0.0
  @Published var progressLabel = "Ready"
  @Published var lastSyncDate: Date?
  @Published var needsSync = true {
    didSet { UserDefaults.standard.set(needsSync, forKey: "needsSync") }
  }
  @Published var driveConnected = false
  @Published var syncEnabled = true
  @Published var includeEdited = false
  @Published var destinationURL: URL?
  @Published var errorMessage: String?
  @Published var summary = SyncSummary()

  let store = SyncStore()
  private var destinationBookmark: Data?
  private var photoObserverRegistered = false
  private var assetFetchResult: PHFetchResult<PHAsset>?
  private var resyncRequested = false
  private var mountedObserver: NSObjectProtocol?
  private var unmountedObserver: NSObjectProtocol?

  init(isUITesting: Bool = false) {
    super.init()
    if isUITesting {
      syncEnabled = false
      progressLabel = "Ready"
      return
    }
    loadPreferences()
    registerPhotoObserverIfNeeded()
    observeVolumes()
    updateDriveStatus()
    if driveConnected && syncEnabled { Task { await sync() } }
  }

  func requestPhotoAccess() async -> Bool {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if status == .authorized || status == .limited {
      registerPhotoObserverIfNeeded()
      return true
    }
    let approved = await withCheckedContinuation { continuation in
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
        continuation.resume(returning: status == .authorized || status == .limited)
      }
    }
    if approved { registerPhotoObserverIfNeeded() }
    return approved
  }

  func setDestination(_ url: URL) {
    destinationURL = url
    needsSync = true
    errorMessage = nil
    destinationBookmark = try? url.bookmarkData(
      options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    UserDefaults.standard.set(destinationBookmark, forKey: "destinationBookmark")
    UserDefaults.standard.set(url.lastPathComponent, forKey: "destinationName")
    updateDriveStatus()
  }

  var isUpToDate: Bool {
    !isSyncing && !needsSync && syncEnabled && driveConnected && lastSyncDate != nil
      && errorMessage == nil
  }

  func setAutomaticSyncEnabled(_ enabled: Bool) {
    syncEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: "syncEnabled")
    if enabled && needsSync && driveConnected {
      Task { await sync() }
    }
  }

  func setIncludeEdited(_ include: Bool) {
    guard includeEdited != include else { return }
    includeEdited = include
    needsSync = true
    if syncEnabled && driveConnected {
      Task { await sync() }
    }
  }

  func sync() async {
    guard !isSyncing else { return }
    guard let root = resolvedDestination() else {
      needsSync = true
      errorMessage = "Choose an available destination folder to sync."
      updateDriveStatus()
      return
    }
    isSyncing = true
    needsSync = true
    errorMessage = nil
    progress = 0
    progressLabel = "Preparing Photos…"
    defer {
      isSyncing = false
      if resyncRequested {
        resyncRequested = false
        if driveConnected && syncEnabled {
          Task { await sync() }
        }
      }
    }
    guard await requestPhotoAccess() else {
      errorMessage = "Allow PixSync to access Photos in System Settings to continue."
      progressLabel = "Photos access required"
      return
    }
    summary = SyncSummary()

    let access = root.startAccessingSecurityScopedResource()
    defer { if access { root.stopAccessingSecurityScopedResource() } }
    let assets = await fetchAssets()
    let activeIDs = Set(assets.map(\.localIdentifier))
    detectRemovals(activeIDs: activeIDs)
    progressLabel = "Checking the destination…"
    await store.reconcileExistingFiles(in: root, assets: assets)
    progressLabel = "Preparing exports…"
    var queue: [(PHAsset, ExportKind)] = []
    for (index, asset) in assets.enumerated() {
      queue.append((asset, .original))
      if includeEdited { queue.append((asset, .edited)) }
      if index % 256 == 255 {
        progressLabel = "Preparing exports \(index + 1) of \(assets.count)…"
        try? await Task.sleep(for: .milliseconds(1))
      }
    }
    var processedCount = 0
    var wasInterrupted = false
    for (index, item) in queue.enumerated() {
      guard FileManager.default.fileExists(atPath: root.path) else {
        wasInterrupted = true
        break
      }
      progressLabel = "Exporting \(index + 1) of \(queue.count)"
      progress = queue.isEmpty ? 1 : Double(index) / Double(queue.count)
      do {
        if try await exportIfNeeded(asset: item.0, kind: item.1, to: root) {
          summary.exported += 1
        } else {
          summary.alreadyPresent += 1
        }
      } catch { summary.errors.append("\(item.0.localIdentifier): \(error.localizedDescription)") }
      processedCount = index + 1
    }
    progress = queue.isEmpty ? 1 : Double(processedCount) / Double(queue.count)
    if wasInterrupted {
      progressLabel = "Sync paused"
      errorMessage = "The SSD disconnected. PixSync will continue when it reconnects."
      needsSync = true
    } else if !summary.errors.isEmpty {
      progressLabel = "Sync complete with issues"
      errorMessage = summary.errors.first
      needsSync = true
    } else {
      progressLabel = "Sync complete"
      errorMessage = nil
      needsSync = false
      lastSyncDate = Date()
      UserDefaults.standard.set(lastSyncDate, forKey: "lastSyncDate")
    }
  }

  func initialReconcileAndSync() async {
    await sync()
  }

  nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      needsSync = true
      guard driveConnected, syncEnabled else { return }
      if isSyncing {
        resyncRequested = true
        return
      }
      await sync()
    }
  }

  func dismissRemoved(_ item: RemovedExport) {
    store.dismissRemoval(item)
  }

  func restoreMissing(_ record: ExportRecord) async {
    guard
      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [record.assetID], options: nil)
        .firstObject,
      let root = resolvedDestination()
    else { return }
    do {
      _ = try await exportIfNeeded(asset: asset, kind: record.kind, to: root, force: true)
    } catch { errorMessage = error.localizedDescription }
  }

  private func fetchAssets() async -> [PHAsset] {
    let result = PHAsset.fetchAssets(with: nil)
    assetFetchResult = result
    var assets: [PHAsset] = []
    assets.reserveCapacity(result.count)
    for index in 0..<result.count {
      assets.append(result.object(at: index))
      if index % 256 == 255 {
        progressLabel = "Reading Photos \(index + 1) of \(result.count)…"
        try? await Task.sleep(for: .milliseconds(1))
      }
    }
    return assets
  }

  private func registerPhotoObserverIfNeeded() {
    guard !photoObserverRegistered else { return }
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard status == .authorized || status == .limited else { return }
    PHPhotoLibrary.shared().register(self)
    photoObserverRegistered = true
  }

  private func detectRemovals(activeIDs: Set<String>) {
    let removed = store.records.values.filter { !activeIDs.contains($0.assetID) }.map {
      RemovedExport(
        assetID: $0.assetID, filename: $0.filename, relativePath: $0.relativePath,
        detectedAt: Date())
    }
    summary.removedFromPhotos = removed.count
    store.setRemoved(removed)
  }

  private func exportIfNeeded(asset: PHAsset, kind: ExportKind, to root: URL, force: Bool = false)
    async throws -> Bool
  {
    let fingerprint = store.fingerprint(asset)
    if let old = store.record(for: asset.localIdentifier, kind: kind),
      old.fingerprint == fingerprint, !force
    {
      let existing = root.appendingPathComponent(old.relativePath)
      if FileManager.default.fileExists(atPath: existing.path) { return false }
      summary.missingOnDisk += 1
      return try await write(
        asset: asset, kind: kind, root: root, fingerprint: fingerprint, preferredName: old.filename)
    }
    return try await write(asset: asset, kind: kind, root: root, fingerprint: fingerprint)
  }

  private func write(
    asset: PHAsset, kind: ExportKind, root: URL, fingerprint: String, preferredName: String? = nil
  ) async throws -> Bool {
    let resources = PHAssetResource.assetResources(for: asset)
    let resource: PHAssetResource?
    if kind == .original {
      resource =
        resources.first { $0.type == .photo } ?? resources.first { $0.type == .alternatePhoto }
        ?? resources.first { $0.type == .video }
    } else {
      resource =
        resources.first { $0.type == .fullSizePhoto }
        ?? resources.first { $0.type == .fullSizeVideo }
    }
    guard let resource else { throw SyncError.noResource(kind) }
    let filename =
      preferredName
      ?? uniqueFilename(resource.originalFilename, asset: asset, kind: kind, root: root)
    let finalURL = root.appendingPathComponent(filename)
    try FileManager.default.createDirectory(
      at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let partialURL = finalURL.appendingPathExtension("\(UUID().uuidString).pixsync-partial")
    defer { try? FileManager.default.removeItem(at: partialURL) }
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHAssetResourceManager.default().writeData(
        for: resource, toFile: partialURL, options: options
      ) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    try SafeExportFileCommitter.commit(partialURL, to: finalURL)
    let relative = String(finalURL.path.dropFirst(root.path.count + 1))
    store.save(
      ExportRecord(
        assetID: asset.localIdentifier, kind: kind, relativePath: relative,
        filename: finalURL.lastPathComponent, modificationDate: asset.modificationDate,
        fingerprint: fingerprint))
    return true
  }

  private func uniqueFilename(_ original: String, asset: PHAsset, kind: ExportKind, root: URL)
    -> String
  {
    SafeExportPath.make(
      originalFilename: original,
      assetID: asset.localIdentifier,
      kind: kind,
      date: asset.pixSyncDate,
      destination: root
    )
  }

  private func resolvedDestination() -> URL? {
    guard let bookmark = destinationBookmark else { return destinationURL }
    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
        bookmarkDataIsStale: &stale)
    else { return nil }
    if stale { setDestination(url) }
    return url
  }

  private func loadPreferences() {
    let defaults = UserDefaults.standard
    includeEdited = defaults.bool(forKey: "includeEdited")
    syncEnabled = defaults.object(forKey: "syncEnabled") as? Bool ?? true
    lastSyncDate = defaults.object(forKey: "lastSyncDate") as? Date
    needsSync = defaults.object(forKey: "needsSync") as? Bool ?? (lastSyncDate == nil)
    destinationBookmark = defaults.data(forKey: "destinationBookmark")
    if let bookmark = destinationBookmark {
      var stale = false
      destinationURL = try? URL(
        resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil,
        bookmarkDataIsStale: &stale)
    }
  }

  private func observeVolumes() {
    let center = NSWorkspace.shared.notificationCenter
    mountedObserver = center.addObserver(
      forName: NSWorkspace.didMountNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        let wasConnected = self?.driveConnected ?? false
        self?.updateDriveStatus()
        if wasConnected == false && self?.driveConnected == true {
          self?.needsSync = true
          if self?.syncEnabled == true { await self?.sync() }
        }
      }
    }
    unmountedObserver = center.addObserver(
      forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.updateDriveStatus() }
    }
  }

  private func updateDriveStatus() {
    guard let url = resolvedDestination() else {
      driveConnected = false
      return
    }
    driveConnected = FileManager.default.fileExists(atPath: url.path)
  }
}

enum SyncError: LocalizedError {
  case noResource(ExportKind)
  var errorDescription: String? { "No \(noResourceTitle) resource is available for this item." }
  private var noResourceTitle: String {
    if case .noResource(let kind) = self { return kind.title.lowercased() }
    return "photo"
  }
}
