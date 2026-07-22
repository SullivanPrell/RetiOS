import SwiftUI
import ReticulumSwift

struct SettingsView: View {
    @Environment(StackController.self) private var stack
    @Environment(CallsController.self) private var calls
    // @Observable + @Environment, so this view depends only on the property it
    // reads (`logLevel`). Under the old @EnvironmentObject/ObservableObject
    // spelling, every appended log line invalidated this whole screen.
    @Environment(RNSLogStore.self) private var logStore

    private static let availableLogLevels: [Reticulum.LogLevel] = [
        .critical, .error, .warning, .notice, .info, .verbose, .debug
    ]

    // Cached stats — refreshed on appear and every 5 s rather than computed in body.
    // Calling transport.getPathTable() inline blocks the main thread for O(n) work
    // on every re-render, causing visible hitches when typing in forms.
    @State private var cachedPathCount: Int = 0

    // NOTE: deliberately NOT wrapped in its own `NavigationStack` here.
    //
    // `SettingsView` is presented two different ways (see `RootView`):
    //   - `TabRootView` (compact width): as a `TabView` tab, which provides no
    //     navigation context of its own — the call site wraps it in
    //     `NavigationStack { SettingsView() }`.
    //   - `SidebarRootView` (regular width): as the `detail` of a
    //     `NavigationSplitView`, which *already* manages its own navigation
    //     stack for the detail column.
    //
    // Nesting a second `NavigationStack` inside `NavigationSplitView`'s detail
    // produces a duplicated/stacked back button the moment you push a
    // `NavigationLink` destination (exactly what this view's "Identity",
    // "Interfaces", "RNode", "BLE Mesh", "Logs" links do) — the split view's
    // own back-navigation chrome and the inner stack's back button both render.
    // Owning the wrapper at each call site (mirroring `ToolsView`'s existing
    // pattern) lets each presentation context supply exactly one stack.
    var body: some View {
        List {
            nodeSection
            #if os(iOS)
            interfacesSection
            #endif
            networkSection
            announceSection
            debugSection
            aboutSection
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .rnsScreenBackground()
        // Flush pinned title (no large-title dead space) — matches the other
        // tabs. Replaces `.navigationTitle` + `.rnsNavigationBar()`.
        .rnsPinnedTitle("Settings")
        .task {
            // Initial load + periodic refresh every 5 s.
            while !Task.isCancelled {
                refreshCachedStats()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func refreshCachedStats() {
        guard let transport = stack.transport else { return }
        // Assign only on change — writing @State unconditionally re-rendered the
        // whole Settings list every 5 s even when the path count was identical.
        let count = transport.getPathTable().count
        if cachedPathCount != count { cachedPathCount = count }
    }

    // MARK: - Sections

    private var nodeSection: some View {
        Section("This Node") {
            LabeledContent("Stack") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stack.isRunning ? Color.rnsSuccess : Color.rnsWarning)
                        .frame(width: 8, height: 8)
                    Text(stack.isRunning ? "Running" : "Idle")
                        .foregroundStyle(.secondary)
                }
            }

            #if os(macOS)
            LabeledContent("Mode") {
                Text(stack.isClientMode ? "Daemon client" : "Embedded")
                    .foregroundStyle(.secondary)
            }
            #endif

            if !stack.nodeDisplayName.isEmpty {
                LabeledContent("Display name") {
                    Text(stack.nodeDisplayName)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Identity hash") {
                Text(stack.identity?.hexHash ?? "—")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            NavigationLink(destination: IdentityView()) {
                Label("Identity & Name", systemImage: "key")
            }
        }
        .rnsRow()
    }

    // Shown on iPhone only — iPad and macOS reach Interfaces via the sidebar.
    private var interfacesSection: some View {
        Section("Interfaces") {
            NavigationLink(destination: InterfacesView()) {
                Label("Interfaces", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .rnsRow()
    }

    private var networkSection: some View {
        Section("Network") {
            // Lives here (rather than its own tab bar item) so the iPhone
            // tab bar stays at 5 tabs — see `TabRootView`'s comment for why
            // a 6th tab silently breaks navigation chrome via iOS's
            // automatic "More" tab folding.
            NavigationLink(destination: ToolsView()) {
                Label("RNS Tools", systemImage: "wrench.and.screwdriver.fill")
            }

            NavigationLink(destination: PropagationNodeView()) {
                LabeledContent("Propagation node") {
                    if let hex = stack.propagationNodeHash {
                        Text(String(hex.prefix(8)) + "…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent("Known paths") {
                Text(stack.isRunning ? "\(cachedPathCount)" : "—")
                    .foregroundStyle(.secondary)
            }
        }
        .rnsRow()
    }

    private var announceSection: some View {
        Section("Announce") {
            // LXMF messaging
            Toggle(isOn: Binding(
                get: { stack.lxmfAnnounceEnabled },
                set: { stack.setLXMFAnnounce($0) }
            )) {
                Label("LXMF Messaging", systemImage: "bubble.left.and.bubble.right")
            }
            .disabled(!stack.isRunning)

            if let hash = stack.lxmfDeliveryHash {
                AddressActionRow(
                    label: "Messaging address",
                    fullHex: hash.map { String(format: "%02x", $0) }.joined(),
                    isRunning: stack.isRunning,
                    onAnnounce: { stack.announceLXMFNow() }
                )
            }

            // LXST voice calls
            Toggle(isOn: Binding(
                get: { calls.lxstAnnounceEnabled },
                set: { calls.setLXSTAnnounce($0) }
            )) {
                Label("LXST Voice Calls", systemImage: "phone.arrow.up.right")
            }
            .disabled(!stack.isRunning)

            if let hash = calls.lxstCallHash {
                AddressActionRow(
                    label: "Call address",
                    fullHex: hash.map { String(format: "%02x", $0) }.joined(),
                    isRunning: stack.isRunning,
                    onAnnounce: { calls.announceLXSTNow() }
                )
            }
        }
        .rnsRow()
    }

    private var debugSection: some View {
        Section("Debug") {
            Picker("Log Level", selection: Binding(
                get: { logStore.logLevel },
                set: { logStore.setLogLevel($0) }
            )) {
                ForEach(Self.availableLogLevels, id: \.rawValue) { level in
                    Text(level.displayName).tag(level)
                }
            }

            NavigationLink(destination: LogsView()) {
                Label("RNS Logs", systemImage: "terminal")
            }
        }
        .rnsRow()
    }

    private var aboutSection: some View {
        Section("About") {
            // The app's own version first — otherwise "About" showed only the
            // ReticulumSwift library's self-reported constant, which made the
            // app look like it was at that version (and never surfaced RetiOS's
            // real version/build at all).
            LabeledContent("RetiOS") {
                Text(Self.appVersion)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("ReticulumSwift") {
                Text(Reticulum.version)
                    .foregroundStyle(.secondary)
            }
        }
        .rnsRow()
    }

    /// "0.3.0 (6)" — from the bundle's short version + build number.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

// MARK: - Address action row

/// A settings row showing a truncated hash with Copy and Announce Now buttons.
private struct AddressActionRow: View {
    let label: String
    let fullHex: String
    let isRunning: Bool
    let onAnnounce: () -> Void

    @State private var showCopied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(fullHex.truncatedHash)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            // Copy button — briefly shows a checkmark on success.
            Button {
                rnsCopyToPasteboard(fullHex)
                showCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    showCopied = false
                }
            } label: {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 16)
                    .animation(.easeInOut(duration: 0.15), value: showCopied)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(showCopied ? Color.rnsSuccess : Color.secondary)
            .accessibilityLabel(showCopied ? "Copied" : "Copy address")

            // Ad-hoc announce button — sends an announce immediately.
            Button(action: onAnnounce) {
                Image(systemName: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.rnsAccent)
            .disabled(!isRunning)
            .accessibilityLabel("Announce now")
        }
        .padding(.vertical, 2)
        .rnsFeedback(trigger: showCopied) { _, new in new ? .success : nil }
    }
}

// Clipboard is handled by the shared `rnsCopyToPasteboard(_:)` in RNSBrand.
