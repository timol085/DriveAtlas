import SwiftUI
import DriveMapperCore

@main
struct DriveMapperApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("DriveAtlas", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 700, minHeight: 440)
                .task { model.start() }
        }
        .defaultSize(width: 980, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // The agent half: this is what makes the app catch a drive being plugged
        // in. The window can be closed; as long as this is running, drives get
        // catalogued.
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.isScanningAnything
                  ? "externaldrive.badge.timemachine"
                  : "externaldrive")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isScanningAnything {
            ForEach(Array(model.scanStatus.keys.sorted()), id: \.self) { name in
                if let status = model.scanStatus[name] {
                    Text("\(name): \(status.foldersScanned) folders…")
                }
            }
            Divider()
        }

        ForEach(model.drives) { drive in
            Button {
                model.selection = drive.id.map(AppModel.Selection.drive)
                model.searchQuery = ""
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("\(drive.name) — \(drive.kindLabel)")
            }
        }

        if model.drives.isEmpty {
            Text("No drives catalogued yet")
        }

        Divider()

        Button("Open DriveAtlas") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")

        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
