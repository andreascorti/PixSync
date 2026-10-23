import AppKit
import SwiftUI

@main
struct PixSyncApp: App {
  @StateObject private var syncService = PhotoSyncService(
    isUITesting: ProcessInfo.processInfo.arguments.contains("--ui-testing")
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  )

  var body: some Scene {
    MenuBarExtra {
      MenuView(service: syncService)
    } label: {
      MenuBarStatusIcon(service: syncService)
    }
    .menuBarExtraStyle(.window)

    Window("PixSync", id: "main") {
      MainWindowView(service: syncService)
    }
    .defaultSize(width: 540, height: 420)
    .windowResizability(.contentSize)

    Window("PixSync Settings", id: "settings") {
      SettingsView(service: syncService)
    }
    .defaultSize(width: 460, height: 380)
    .windowResizability(.contentSize)
  }
}

private struct MenuBarStatusIcon: View {
  @ObservedObject var service: PhotoSyncService

  var body: some View {
    Image("PixSyncMenuBar")
      .renderingMode(.template)
      .overlay(alignment: .bottomTrailing) {
        if service.isUpToDate {
          statusBadge(color: .green, symbol: "checkmark")
        } else if service.isSyncing {
          statusBadge(color: .blue, symbol: "arrow.triangle.2.circlepath")
        } else if service.destinationURL != nil && !service.driveConnected {
          statusBadge(color: .orange, symbol: "exclamationmark")
        } else if service.needsSync && service.driveConnected {
          statusBadge(color: .orange, symbol: "arrow.triangle.2.circlepath")
        }
      }
      .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    if service.isUpToDate { return "PixSync, everything is synced" }
    if service.isSyncing { return "PixSync, syncing" }
    if service.destinationURL != nil && !service.driveConnected {
      return "PixSync, destination unavailable"
    }
    if service.needsSync { return "PixSync, sync needed" }
    return "PixSync"
  }

  private func statusBadge(color: Color, symbol: String) -> some View {
    Circle()
      .fill(color)
      .frame(width: 9, height: 9)
      .overlay {
        Image(systemName: symbol)
          .font(.system(size: 5, weight: .bold))
          .foregroundStyle(.white)
      }
      .overlay(Circle().stroke(.white, lineWidth: 0.7))
      .offset(x: 2, y: 2)
  }
}

struct MainWindowView: View {
  @ObservedObject var service: PhotoSyncService
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 12) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .frame(width: 44, height: 44)
        VStack(alignment: .leading, spacing: 3) {
          Text("PixSync").font(.title2.weight(.semibold))
          Text("Keep a folder in sync with Photos")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Settings…") { openWindow(id: "settings") }
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("DESTINATION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        HStack(spacing: 12) {
          Image(systemName: "externaldrive")
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(width: 34)
          VStack(alignment: .leading, spacing: 3) {
            Text(service.destinationURL?.path ?? "No folder selected")
              .font(.body.weight(.medium))
              .lineLimit(1)
              .truncationMode(.middle)
            Text(destinationStatus)
              .font(.caption)
              .foregroundStyle(service.driveConnected ? Color.secondary : Color.orange)
          }
          Spacer(minLength: 8)
          Button(service.destinationURL == nil ? "Choose Folder…" : "Change…") {
            DestinationChooser.present(for: service)
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
      }

      VStack(alignment: .leading, spacing: 8) {
        SyncStatusView(service: service)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if !service.store.removedExports.isEmpty {
        Label(
          "\(service.store.removedExports.count) exported item(s) were removed from Photos",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.orange)
      }

      Spacer(minLength: 0)

      HStack {
        Text("Original photos are copied. Existing files are never overwritten.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          Task { await service.sync() }
        } label: {
          Label(
            syncButtonTitle,
            systemImage: service.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .disabled(service.isSyncing || !service.driveConnected)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(minWidth: 500, minHeight: 360)
  }

  private var destinationStatus: String {
    guard service.destinationURL != nil else { return "Choose a folder on this Mac or an SSD" }
    return service.driveConnected ? "Folder available" : "Drive disconnected or folder unavailable"
  }

  private var syncButtonTitle: String {
    service.isSyncing ? "Syncing…" : "Sync Now"
  }

}

struct MenuView: View {
  @ObservedObject var service: PhotoSyncService
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: "externaldrive")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(service.destinationURL?.lastPathComponent ?? "No folder selected")
            .font(.headline)
          Text(destinationStatus).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      }

      Button(service.destinationURL == nil ? "Choose Folder…" : "Change Folder…") {
        DestinationChooser.present(for: service)
      }
      .buttonStyle(.bordered)
      .frame(maxWidth: .infinity, alignment: .leading)

      SyncStatusView(service: service)

      if !service.store.removedExports.isEmpty {
        Label(
          "\(service.store.removedExports.count) exported item(s) removed from Photos",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }

      HStack {
        Button("Open PixSync Window…") { openWindow(id: "main") }
          .buttonStyle(.plain)
        Spacer()
        Button {
          Task { await service.sync() }
        } label: {
          Label(
            syncButtonTitle,
            systemImage: service.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
        }
        .disabled(service.isSyncing || !service.driveConnected)
        .keyboardShortcut(.defaultAction)
      }
      Divider()
      HStack {
        Button("Settings…") { openWindow(id: "settings") }
          .buttonStyle(.plain)
        Spacer()
        Button("Quit PixSync") { NSApplication.shared.terminate(nil) }
          .buttonStyle(.plain).foregroundStyle(.secondary)
      }.font(.caption)
    }
    .padding(16)
    .frame(width: 360)
  }

  private var destinationStatus: String {
    guard service.destinationURL != nil else { return "Choose a folder on this Mac or SSD" }
    return service.driveConnected ? "Destination available" : "Destination unavailable"
  }

  private var syncButtonTitle: String {
    service.isSyncing ? "Syncing…" : "Sync Now"
  }
}

struct SettingsView: View {
  @ObservedObject var service: PhotoSyncService
  @AppStorage("includeEdited") private var includeEdited = false
  @AppStorage("syncEnabled") private var syncEnabled = true

  var body: some View {
    Form {
      Section("Export") {
        Toggle("Include edited versions", isOn: $includeEdited)
          .onChange(of: includeEdited) { _, value in service.setIncludeEdited(value) }
        Text(
          "Originals are always exported. When enabled, PixSync also saves the edited version shown in Photos."
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle("Sync automatically when SSD connects", isOn: $syncEnabled)
          .onChange(of: syncEnabled) { _, value in service.setAutomaticSyncEnabled(value) }
      }
      Section("Existing files") {
        Text(
          "On first setup, PixSync scans the destination and matches files by original filename. Ambiguous name matches are flagged for review. Unmatched files are left untouched."
        )
        .font(.caption).foregroundStyle(.secondary)
        if !service.store.ambiguousMatches.isEmpty {
          ForEach(service.store.ambiguousMatches) { match in
            Label(
              "\(match.filename): \(match.candidateCount) possible Photos matches",
              systemImage: "questionmark.folder"
            )
            .font(.caption)
          }
        }
        if !service.store.unmatchedDestinationItems.isEmpty {
          ForEach(service.store.unmatchedDestinationItems) { item in
            Label(
              item.relativePath,
              systemImage: item.isDirectory ? "folder" : "doc"
            )
            .font(.caption)
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding(20)
    .frame(width: 460)
    .onAppear {
      service.includeEdited = includeEdited
      service.syncEnabled = syncEnabled
    }
  }
}

private struct SyncStatusView: View {
  @ObservedObject var service: PhotoSyncService

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if service.isSyncing {
        ProgressView(value: service.progress)
        Label(service.progressLabel, systemImage: "arrow.triangle.2.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if let error = service.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      } else if service.isUpToDate {
        Label("Everything is synced", systemImage: "checkmark.circle.fill")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.green)
      } else if service.destinationURL == nil {
        Label("Choose a destination to get started", systemImage: "folder")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if !service.driveConnected {
        Label("Destination unavailable", systemImage: "externaldrive.badge.exclamationmark")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if service.needsSync {
        Label("Changes need syncing", systemImage: "arrow.triangle.2.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Label("Automatic sync is off", systemImage: "pause.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let summary = service.store.unmatchedDestinationSummary {
        Label(summary, systemImage: "questionmark.folder")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let lastSyncDate = service.lastSyncDate, !service.isSyncing {
        Text("Last synced \(lastSyncDate.formatted(.relative(presentation: .named)))")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private enum DestinationChooser {
  @MainActor
  static func present(for service: PhotoSyncService) {
    let panel = NSOpenPanel()
    panel.title = "Choose PixSync Destination"
    panel.prompt = "Use Folder"
    panel.message = "Choose a folder on this Mac or an external SSD."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    if let destinationURL = service.destinationURL,
      FileManager.default.fileExists(atPath: destinationURL.path)
    {
      panel.directoryURL = destinationURL
    }

    NSApplication.shared.activate(ignoringOtherApps: true)
    panel.begin { response in
      guard response == .OK, let folderURL = panel.url else { return }
      Task { @MainActor in
        guard folderURL.startAccessingSecurityScopedResource() else {
          service.errorMessage = "PixSync could not access the selected folder. Choose it again."
          return
        }
        service.setDestination(folderURL)
        folderURL.stopAccessingSecurityScopedResource()
        await service.initialReconcileAndSync()
      }
    }
  }
}
