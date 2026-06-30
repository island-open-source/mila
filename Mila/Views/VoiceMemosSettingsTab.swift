import SwiftUI
import AppKit

/// Settings → Voice Memos. Lets the user sync recordings made on their iPhone
/// (synced to this Mac via iCloud) into Mila, picking which Voice Memos
/// folders to watch. New recordings in those folders are imported and
/// transcribed automatically; see `VoiceMemosImporter`.
struct VoiceMemosSettingsTab: View {
    @EnvironmentObject private var settings: VoiceMemosSettings
    @EnvironmentObject private var importer: VoiceMemosImporter

    @State private var folders: [VoiceMemosLibrary.Folder] = []
    @State private var unfiledCount = 0
    @State private var loadError: String?
    @State private var isLoading = false

    private let library = VoiceMemosLibrary()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // Always render the master toggle — otherwise a user who enabled
            // sync and then lost the library (iCloud off, etc.) would have no
            // control left to turn the integration back off.
            Toggle("Sync recordings from iPhone Voice Memos", isOn: $settings.isEnabled)
                .toggleStyle(.switch)

            switch library.availability {
            case .available:
                if settings.isEnabled {
                    folderPicker
                    statusFooter
                }
            case .databaseMissing:
                unavailableNotice
            case .accessDenied:
                accessDeniedNotice
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: settings.isEnabled) {
            if settings.isEnabled { await loadFolders() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Voice Memos")
                .font(.title2).bold()
            Text("Automatically transcribe recordings you make on your iPhone. "
                 + "Mila watches the Voice Memos folders you choose and imports new recordings as they sync over iCloud.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unavailableNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "iphone.slash")
                .foregroundStyle(.secondary)
            Text("No Voice Memos library was found on this Mac. Make sure Voice Memos iCloud sync "
                 + "is turned on for both your iPhone and this Mac, then reopen this tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// Shown when the Voice Memos DB exists but macOS blocked access. Mila is
    /// not sandboxed, so reading the Voice Memos group container needs Full
    /// Disk Access — point the user straight at the right pane (issue #45).
    private var accessDeniedNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("Mila can't read your Voice Memos library. macOS needs you to grant "
                     + "Mila Full Disk Access, then reopen this tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Full Disk Access Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Folders to watch")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await loadFolders() }
                    importer.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || importer.isSyncing)
            }

            if let loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                Toggle(isOn: $settings.includeUnfiled) {
                    folderRow(name: "Unfiled", count: unfiledCount, systemImage: "tray")
                }
                ForEach(folders) { folder in
                    Toggle(isOn: binding(for: folder)) {
                        folderRow(name: folder.name, count: folder.count, systemImage: "folder")
                    }
                }
            }
            .frame(height: 220)
            .overlay {
                if folders.isEmpty && unfiledCount == 0 && !isLoading && loadError == nil {
                    Text("No recordings found.")
                        .foregroundStyle(.secondary)
                }
            }

            if !settings.hasSelection {
                Text("Choose at least one folder to start syncing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func folderRow(name: String, count: Int, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(name)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 6) {
            if importer.isSyncing {
                ProgressView().controlSize(.small)
                Text("Syncing…").foregroundStyle(.secondary)
            } else if let error = importer.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).foregroundStyle(.secondary)
            } else if let date = importer.lastSyncDate {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened)) — "
                     + "\(importer.totalImported) imported this session")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding(for folder: VoiceMemosLibrary.Folder) -> Binding<Bool> {
        Binding(
            get: { settings.selectedFolderUUIDs.contains(folder.uuid) },
            set: { settings.setFolder(folder.uuid, selected: $0) }
        )
    }

    private func loadFolders() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        let lib = library
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                (folders: try lib.folders(), unfiled: try lib.unfiledCount())
            }.value
            folders = loaded.folders
            unfiledCount = loaded.unfiled
        } catch {
            // Drop stale data so a failed refresh can't leave the user
            // interacting with folder choices that no longer reflect the DB.
            folders = []
            unfiledCount = 0
            loadError = error.localizedDescription
        }
    }
}
