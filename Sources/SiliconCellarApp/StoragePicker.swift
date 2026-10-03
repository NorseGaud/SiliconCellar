import AppKit
import SiliconCellarCore
import SwiftUI

struct StoragePicker: View {
    @ObservedObject var model: LibraryModel
    @State private var choices: [StorageDestination] = []
    @State private var selected = "internal"
    @State private var loaded = false
    @State private var moving = false

    private var storage: LibraryStorage { LibraryStorage() }
    private var choice: StorageDestination? { choices.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Storage")
                .font(.title2.bold())
            Text(moving
                ? "Move the games, settings, and local saves together. Save and quit your games. Then close the launcher."
                : "Choose where to keep the games. Silicon Cellar makes a Silicon Cellar folder for them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Picker(moving ? "Move to" : "Keep games on", selection: $selected) {
                    ForEach(choices) { item in
                        Text(item.title).tag(item.id)
                    }
                    Text("Choose a folder…").tag("custom-picker")
                }
                .accessibilityIdentifier("storage-destination")
                if let available = choice?.available {
                    Text("\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if selected == "custom", let choice {
                    Text(choice.folder.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let choice, (try? LibraryStorage.volumeFormat(choice.folder)) == "exfat" {
                Text("This drive format stays the same. Your other files stay on the drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let issue = choice?.problem {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Link(
                    "About drive formats",
                    destination: URL(string: "https://support.apple.com/guide/disk-utility/file-system-formats-dsku19ed921c/mac")!
                )
                .font(.caption)
            }
            if model.storageUsesContainer {
                Button("Eject drive") { model.ejectStorage() }
                    .disabled(model.busy)
                    .accessibilityIdentifier("storage-eject")
            }
            HStack {
                Button("Cancel") { model.showStoragePicker = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(moving ? "Move games" : "Use this location") {
                    if let choice { model.chooseStorage(choice) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil || choice?.problem != nil || model.busy)
                .accessibilityIdentifier("storage-continue")
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            moving = storage.hasPayload()
            reload()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in reload() }
        .onChange(of: selected) { old, new in
            guard new == "custom-picker" else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose folder"
            panel.message = "Silicon Cellar will make a Silicon Cellar folder inside the folder you choose."
            if panel.runModal() == .OK, let base = panel.url {
                let folder = LibraryStorage.gameFolder(in: base)
                var issue: String?
                do { try LibraryStorage.validateDestination(folder) } catch { issue = (error as? PortError)?.message ?? error.localizedDescription }
                choices.removeAll { $0.id == "custom" }
                choices.append(StorageDestination(
                    id: "custom",
                    title: base.lastPathComponent,
                    folder: folder,
                    available: LibraryStorage.availableBytes(folder),
                    problem: issue
                ))
                selected = "custom"
            } else {
                selected = old == "custom-picker" ? "internal" : old
            }
        }
    }

    private func reload() {
        let previous = selected
        choices = storage.destinations()
        let current = storage.location()
        if !choices.contains(where: { LibraryStorage.sameFolder($0.folder, current) }) {
            choices.insert(StorageDestination(
                id: "current",
                title: "\(storage.displayName()) (current location)",
                folder: current,
                available: LibraryStorage.availableBytes(current),
                problem: storage.issue(mountContainers: false)
            ), at: 0)
        }
        if loaded, choices.contains(where: { $0.id == previous }) {
            selected = previous
        } else if let match = choices.first(where: { LibraryStorage.sameFolder($0.folder, current) }) {
            selected = match.id
        } else {
            selected = storage.suggestedID(choices)
        }
        loaded = true
    }
}
