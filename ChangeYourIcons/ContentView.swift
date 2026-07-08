import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
            MacOSIconsWebView()
                .frame(minWidth: 600)
        }
        .onAppear { state.loadLibraries() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change app icon")
                .font(.title2).bold()

            Picker("", selection: $state.source) {
                ForEach(AppSource.allCases) { src in
                    Text(src.rawValue).tag(src)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("Search apps…", text: $state.query)
                .textFieldStyle(.roundedBorder)

            appList

            HStack {
                Button {
                    chooseApp()
                } label: {
                    Label("Other location…", systemImage: "folder")
                }
                Spacer()
                Button {
                    state.loadLibraries()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload lists")
            }

            Divider()

            if let target = state.target {
                targetCard(target)
            } else {
                Text("No app selected.")
                    .foregroundStyle(.secondary)
            }

            statusView
        }
        .padding(16)
    }

    private var appList: some View {
        List(state.visibleApps, selection: Binding(
            get: { state.target?.id },
            set: { newID in
                if let app = state.visibleApps.first(where: { $0.id == newID }) {
                    state.select(app)
                }
            })
        ) { app in
            HStack(spacing: 8) {
                Image(nsImage: app.currentIcon)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if app.isSystemProtected {
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
            .tag(app.id)
            .onTapGesture { state.select(app) }
        }
        .listStyle(.inset)
        .frame(minHeight: 220)
    }

    @ViewBuilder
    private func targetCard(_ target: AppTarget) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: target.currentIcon)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.headline)
                Text(target.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }

        if target.isSystemProtected {
            Label("System app protected by SIP: its icon can't be changed.",
                  systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }

        VStack(spacing: 8) {
            Button {
                if let icon = state.lastDownloadedIcon {
                    state.apply(iconURL: icon)
                } else {
                    state.setStatus("Download an icon from macosicons.com first.", error: true)
                }
            } label: {
                Label("Apply last downloaded icon", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(target.isSystemProtected)

            Button(role: .destructive) {
                state.restore()
            } label: {
                Label("Restore original icon", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(target.isSystemProtected)
        }
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.status)
                .font(.callout)
                .foregroundStyle(state.isError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.needsPermission {
                Button {
                    state.openAppManagementSettings()
                } label: {
                    Label("Open Settings → Privacy → App Management", systemImage: "gearshape")
                }
                .controlSize(.small)
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            state.select(AppTarget(url: url))
        }
    }
}
