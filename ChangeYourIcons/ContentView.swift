import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
            VStack(spacing: 0) {
                webToolbar
                MacOSIconsWebView()
            }
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

            if !state.savedIcons.isEmpty {
                savedIconsGallery
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

        VStack(spacing: 8) {
            Button {
                if let icon = state.lastDownloadedIcon {
                    state.apply(iconURL: icon)
                } else {
                    state.setStatus("Download an icon from the panel on the right first.", error: true)
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

    private var webToolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $state.webSource) {
                ForEach(IconWebSource.allCases) { src in
                    Text(src.rawValue).tag(src)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Choose the icon source")

            Button {
                state.reloadWeb()
            } label: {
                Label("Reload icons", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .help("Reload the icon gallery (fixes thumbnails that failed to load)")

            Text("If some icons appear blank, click Reload — previews load lazily.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var savedIconsGallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloaded icons")
                .font(.subheadline).bold()
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                    ForEach(state.savedIcons) { icon in
                        savedIconCell(icon)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    @ViewBuilder
    private func savedIconCell(_ icon: SavedIcon) -> some View {
        Group {
            if let thumb = icon.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(icon.name)
        .contentShape(Rectangle())
        .onTapGesture { state.apply(iconURL: icon.url) }
        .contextMenu {
            Button(role: .destructive) {
                state.deleteSavedIcon(icon)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.status)
                .font(.callout)
                .foregroundStyle(state.isError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionCard
        }
    }

    @ViewBuilder
    private var permissionCard: some View {
        switch state.permissionHint {
        case .appManagement:
            VStack(alignment: .leading, spacing: 8) {
                Label("ChangeYourIcons needs the “App Management” permission",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).bold()
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    permissionStep(1, "Click **Open Settings** below.")
                    permissionStep(2, "Turn on **ChangeYourIcons** under *Privacy & Security → App Management*.")
                    permissionStep(3, "Come back here and click **Apply**.")
                }

                Text("After you rebuild the app, macOS may ask for this permission again (the ad-hoc signature changes on every build).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    state.openAppManagementSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

        case .sip:
            VStack(alignment: .leading, spacing: 6) {
                Label("Protected by System Integrity Protection (SIP)",
                      systemImage: "lock.fill")
                    .font(.callout).bold()
                    .foregroundStyle(.orange)
                Text("Apps in the system folder can't have their icon changed. This is a macOS security protection and there is no setting to allow it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

        case .none:
            EmptyView()
        }
    }

    private func permissionStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
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
