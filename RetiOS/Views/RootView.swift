import SwiftUI

// MARK: - RootView
//
// iPhone / compact width : TabView (4 tabs: Messages, Calls, NomadNet, Settings)
// iPad / regular width   : NavigationSplitView with the same 4 sections in a sidebar
//
// Both layouts observe NotificationManager.navigateTo and switch to the correct
// section when the user taps a notification banner or action button.

struct RootView: View {
    @Environment(StackController.self) private var stack
    @Environment(NotificationManager.self) private var notifs
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        layout
            // Menu-bar "Reticulum ▸ Announce Now / Sync" intents. Handled here
            // because RootView is always present and carries the stack.
            .onChange(of: notifs.requestAnnounce) { _, _ in stack.announceLXMFNow() }
            .onChange(of: notifs.requestSync)     { _, _ in stack.syncFromPropagationNode() }
        #if os(macOS)
            .frame(minWidth: 820, minHeight: 520)
        #endif
            .onAppear { showOnboarding = !hasCompletedOnboarding }
            .modifier(OnboardingPresenter(isPresented: $showOnboarding) {
                hasCompletedOnboarding = true
                showOnboarding = false
            })
    }

    @ViewBuilder
    private var layout: some View {
        // macOS has no `UserInterfaceSizeClass` concept at all — AppKit-hosted
        // SwiftUI always reports `horizontalSizeClass == nil` there (it's an
        // iOS/iPadOS/Mac-Catalyst/tvOS trait). `nil == .regular` is `false`,
        // so without this branch every Mac window fell through to
        // `TabRootView` — the *phone* layout: a `TabView` with each tab
        // independently wrapping itself in `NavigationStack` and applying
        // `.rnsNavigationBar()` / `.rnsInlineNavigationTitle()`, which are
        // no-ops on macOS (there's no navigation bar or nav-bar title-display
        // mode in a window toolbar). That's what "Mac styles are wildly
        // inconsistent" was: a touch-first tab-bar UI rendered through
        // AppKit's window chrome, with none of the iOS-only styling that
        // made it cohere — instead of `SidebarRootView`, the
        // `NavigationSplitView` layout literally labelled "iPad / Mac
        // sidebar" below, which both `rnsNavigationBar()`'s doc comment and
        // that label make clear was always the intended Mac experience.
        //
        // macOS windows are always effectively "regular" width — there's no
        // compact/phone-sized macOS window — so route unconditionally there.
        #if os(macOS)
        SidebarRootView()
        #else
        if sizeClass == .regular {
            SidebarRootView()
        } else {
            TabRootView()
        }
        #endif
    }
}

// MARK: - Phone / compact tab bar

private struct TabRootView: View {
    @Environment(NotificationManager.self) private var notifs
    @State private var selectedTab: AppTab = .messages

    var body: some View {
        TabView(selection: $selectedTab) {
            ConversationsView()
                .tag(AppTab.messages)
                .tabItem { Label("Messages", systemImage: "message.fill") }

            CallsView()
                .tag(AppTab.calls)
                .tabItem { Label("Calls", systemImage: "phone.fill") }

            NomadNetContainerView()
                .tag(AppTab.nomadNet)
                .tabItem { Label("NomadNet", systemImage: "globe.americas.fill") }

            MapView()
                .tag(AppTab.map)
                .tabItem { Label("Map", systemImage: "map.fill") }

            // NOTE: deliberately only 5 tabs here (not 6).
            //
            // `UITabBarController` — which backs SwiftUI's `TabView` on
            // iPhone / compact width — only displays 5 tabs directly; a 6th
            // gets silently folded into an automatic "More" tab managed by
            // `UIMoreNavigationController`. That controller fights with each
            // tab's own `NavigationStack` for ownership of the navigation
            // chrome, producing a duplicated/stacked back button AND
            // intermittent toolbar corruption (observed firsthand as
            // `[Assert] UIScrollView does not support multiple observers...
            // removing old observer <UIMoreNavigationController>` in the
            // console — which is what made the "download logs" share button
            // vanish on tap).
            //
            // "Tools" is reachable instead via a NavigationLink from
            // `SettingsView` (see its `interfacesSection`/`networkSection`),
            // keeping the tab bar at the safe 5-tab limit. `AppTab.tools`
            // still exists for the iPad/Mac sidebar (`SidebarRootView`),
            // which has no such limit.

            // `SettingsView` no longer wraps itself in a `NavigationStack`
            // (see its body comment) — `TabView` provides no navigation
            // context of its own, so this is the one place that must supply
            // it. `SidebarRootView.detailView` deliberately does NOT, since
            // `NavigationSplitView` already manages the detail column's stack.
            NavigationStack { SettingsView() }
                .tag(AppTab.settings)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .suppressTabBarMinimize()
        .onChange(of: notifs.navigateTo) { _, tab in
            guard let tab else { return }
            // `.tools` and `.interfaces` have no phone tabs — route both to
            // Settings, which carries NavigationLinks to both.
            let phoneTab: AppTab
            switch tab {
            case .tools, .interfaces: phoneTab = .settings
            default:                  phoneTab = tab
            }
            selectedTab = phoneTab
            notifs.navigateTo = nil
        }
    }
}

private extension View {
    @ViewBuilder
    func suppressTabBarMinimize() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.never)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - iPad / Mac sidebar
//
// Four sections mirror the four phone tabs exactly.

private struct SidebarRootView: View {
    @Environment(StackController.self) private var stack
    @Environment(NotificationManager.self) private var notifs
    @State private var selection: AppTab? = .messages

    // On macOS, Settings lives in its own ⌘, Preferences window (see RetiOSApp),
    // so it's dropped from the sidebar. iPad keeps it (no Settings scene there).
    private var sidebarTabs: [AppTab] {
        #if os(macOS)
        AppTab.allCases.filter { $0 != .settings }
        #else
        AppTab.allCases
        #endif
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(sidebarTabs, id: \.self, selection: $selection) { tab in
                Label(tab.displayName, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationTitle("RetiOS")
            .toolbar { sidebarToolbar }
            .overlay(alignment: .bottom) { stackStatusBar }
        } detail: {
            detailView(for: selection ?? .messages)
        }
        .onChange(of: notifs.navigateTo) { _, tab in
            guard let tab else { return }
            selection = tab
            notifs.navigateTo = nil
        }
    }

    // MARK: Stack status bar (sidebar footer)

    /// One-line status footer pinned to the bottom of the sidebar.
    ///
    /// Laid out with `ViewThatFits` rather than truncation. The Mac sidebar is
    /// far narrower (~200 pt) than any iPhone this was originally sized for,
    /// and the naive version let the status text and the identity hash fight
    /// for width until *both* wrapped — the footer read "Stack run-/ning" over
    /// two rows with the hash broken across three.
    ///
    /// Truncating instead is no better: squeezing a 32-char hash into the
    /// leftover space renders it as a lone "…", which carries no information at
    /// all. So the hash is treated as genuinely optional — shown whole when it
    /// fits, dropped when it doesn't, and always available via the tooltip.
    private var stackStatusBar: some View {
        ViewThatFits(in: .horizontal) {
            statusRow(includeHash: true)
            statusRow(includeHash: false)
        }
        // 16 pt was an iOS-phone inset; the Mac sidebar adds its own margins,
        // so stacking another 16 on top just wasted scarce width.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .rnsBarMaterial()
        .help(stack.identity.map { "Identity \($0.hexHash)" } ?? "Reticulum stack")
    }

    private func statusRow(includeHash: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stack.isRunning ? Color.rnsSuccess : Color.rnsWarning)
                // A bare Circle in an HStack will happily be squeezed to a
                // sliver when the row is tight; pin it.
                .frame(width: 7, height: 7)
                .fixedSize()
            Text(stack.isRunning ? "Stack running" : "Starting…")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            if includeHash, let id = stack.identity {
                Text(id.hexHash.truncatedHash)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()   // whole or not at all — never a lone "…"
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .rnsTrailing) {
            RNSLogoView(size: 28)
        }
    }

    // MARK: Detail view — mirrors the tab bar exactly

    @ViewBuilder
    private func detailView(for tab: AppTab) -> some View {
        switch tab {
        case .messages:   ConversationsView()
        case .calls:      CallsView()
        case .nomadNet:   NomadNetContainerView()
        case .map:        MapView()
        case .interfaces: NavigationStack { InterfacesView() }
        case .tools:      NavigationStack { ToolsView() }
        case .settings:   SettingsView()
        }
    }
}

// MARK: - AppTab display helpers

private extension AppTab {
    var displayName: String {
        switch self {
        case .messages:   return "Messages"
        case .calls:      return "Calls"
        case .nomadNet:   return "NomadNet"
        case .map:        return "Map"
        case .interfaces: return "Interfaces"
        case .tools:      return "Tools"
        case .settings:   return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .messages:   return "message.fill"
        case .calls:      return "phone.fill"
        case .nomadNet:   return "globe.americas.fill"
        case .map:        return "map.fill"
        case .interfaces: return "antenna.radiowaves.left.and.right"
        case .tools:      return "wrench.and.screwdriver.fill"
        case .settings:   return "gear"
        }
    }
}

// MARK: - First-run onboarding
//
// Presented once (gated on the `hasCompletedOnboarding` AppStorage flag) over
// the whole app. Full-screen on iOS, a sized sheet on macOS. Composes existing
// building blocks — `stack.setNodeDisplayName`, the shared `rnsQRImage`, and
// `InterfaceDirectory` quick-add — into a 3-step welcome.

private struct OnboardingPresenter: ViewModifier {
    @Environment(StackController.self) private var stack
    @Binding var isPresented: Bool
    let onFinish: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) {
            OnboardingView(onFinish: onFinish).environment(stack)
        }
        #else
        content.sheet(isPresented: $isPresented) {
            OnboardingView(onFinish: onFinish)
                .environment(stack)
                .frame(minWidth: 540, minHeight: 620)
        }
        #endif
    }
}

private struct OnboardingView: View {
    @Environment(StackController.self) private var stack
    let onFinish: () -> Void

    @State private var step = 0
    @State private var draftName = ""
    /// Rendered once, off the main thread. Calling `rnsQRImage` inline in `body`
    /// re-rendered the whole QR (including a fresh CIContext) on *every* body
    /// evaluation — on the very first screen a new user ever sees.
    @State private var qrImage: Image?

    private let lastStep = 2

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finish() }
                    .padding()
            }

            Group {
                switch step {
                case 0:  welcomeStep
                case 1:  addressStep
                default: OnboardingConnectStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal)

            // Progress dots
            HStack(spacing: 8) {
                ForEach(0...lastStep, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.rnsAccent : Color.rnsBorder)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 12)
            .accessibilityHidden(true)

            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(step == lastStep ? "Get Started" : "Next") {
                    if step == lastStep { finish() }
                    else { withAnimation { step += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .rnsCanvasBackground()
        .interactiveDismissDisabled()
        .onAppear { draftName = stack.nodeDisplayName }
    }

    private func finish() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { stack.setNodeDisplayName(trimmed) }
        onFinish()
    }

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer()
            RNSLogoView(size: 88)
            Text("Welcome to RetiOS")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("A complete client for the Reticulum mesh — messaging, calls, and pages, with no servers or accounts.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose a display name")
                    .font(.headline)
                TextField("Your name (shown to peers)", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Text("Included in your announces so peers see a name instead of a raw address. You can change it anytime in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private var addressStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Your address")
                .font(.title.bold())
            Text("Your identity hash is your address on the network. Share it — or its QR code — so others can message or call you.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let hex = stack.identity?.hexHash {
                if let qr = qrImage {
                    qr
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                }
                Text(hex)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                ProgressView("Generating your identity…")
                    .padding()
            }
            Spacer()
        }
        .task(id: stack.identity?.hexHash) {
            guard let hex = stack.identity?.hexHash else { qrImage = nil; return }
            qrImage = await rnsQRImageAsync(hex)
        }
    }
}

// Separate view so the directory fetch lives only while step 3 is on screen.
private struct OnboardingConnectStep: View {
    @Environment(StackController.self) private var stack
    @State private var entries: [InterfaceDirectory.Entry] = []
    @State private var loadFailed = false
    @State private var added: Set<String> = []

    private var quickAddable: [InterfaceDirectory.Entry] {
        Array(entries.filter(\.isQuickAddable).prefix(8))
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Connect to the mesh")
                .font(.title.bold())
            Text("Add a community gateway to reach the wider network over the internet. Optional — you can mesh locally or add interfaces later in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if entries.isEmpty && !loadFailed {
                ProgressView("Finding gateways…")
                    .padding()
            } else if quickAddable.isEmpty {
                Label("No gateways available right now. You can add one later in Settings ▸ Interfaces.",
                      systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                List(quickAddable) { entry in
                    gatewayRow(entry)
                }
                .listStyle(.plain)
                .frame(maxHeight: 300)
            }
            Spacer(minLength: 0)
        }
        .task {
            guard entries.isEmpty else { return }
            do { entries = try await InterfaceDirectory.fetchOnline() }
            catch { loadFailed = true }
        }
    }

    @ViewBuilder
    private func gatewayRow(_ entry: InterfaceDirectory.Entry) -> some View {
        let isAdded = added.contains(entry.name) || stack.savedInterfaces.contains { $0.name == entry.name }
        HStack(spacing: 12) {
            Image(systemName: "network")
                .foregroundStyle(Color.rnsAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body).lineLimit(1)
                Text(entry.hostPort)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.rnsSuccess)
                    .accessibilityLabel("Added")
            } else {
                Button("Add") { add(entry) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Add \(entry.name)")
            }
        }
        .padding(.vertical, 2)
    }

    private func add(_ entry: InterfaceDirectory.Entry) {
        guard let kind = entry.savedKind,
              let port = entry.port,
              let portNum = UInt16(exactly: port) else { return }
        try? stack.addAndSaveInterface(name: entry.name, host: entry.host, port: portNum, kind: kind)
        added.insert(entry.name)
    }
}
