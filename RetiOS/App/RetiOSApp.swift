import SwiftUI
import SwiftData
import ReticulumSwift

@main
struct RetiOSApp: App {
    // RNSLogStore is created first so it installs the log handler before bringUp().
    // @Observable model → owned with @State and shared via .environment (NOT
    // @StateObject/.environmentObject, which are the ObservableObject spelling).
    @State private var logStore = RNSLogStore()
    @State private var stack     = StackController()
    @State private var calls     = CallsController()
    @State private var nomadNet  = NomadNetController()
    // Owned here (not as a per-view @StateObject in BLEMeshView) so the mesh
    // radio — and the UI state that reflects it — survives navigation. A
    // view-scoped controller would be torn down and recreated every time the
    // user left and returned to the BLE Mesh screen: the radio it started
    // would keep running (registered with `stack.transport`), but the fresh
    // controller would show "Off"/0 peers, and re-toggling would spin up a
    // *second*, conflicting CoreBluetooth stack on top of the first.
    @State private var bleMesh   = BLEMeshController()
    // Owned here for the same reason as `bleMesh`, and for a sharper one: a
    // connected RNode registers a live `RNodeInterface` with `Transport`, and
    // `Transport.interfaces` holds it strongly. As a view-scoped `@State` the
    // controller died when the user navigated away from the RNode screen —
    // taking its `CBCentralManager` (and therefore the disconnect callback that
    // calls `teardown()`) with it, while the now-dead interface stayed
    // registered forever. Transport kept selecting it for outbound traffic that
    // silently went nowhere. App-scoped, the controller outlives navigation, so
    // teardown always runs and the interface is always deregistered.
    // Constructing it is inert: no `CBCentralManager` exists until the user
    // taps Scan, so this triggers no Bluetooth permission prompt at launch.
    @State private var rnode     = RNodeScannerController()
    // NotificationManager is a singleton, injected into the environment so views
    // can observe navigateTo / openConversationHash reactively.
    @State private var notifs    = NotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    private let container = PersistenceController.makeContainer()

    /// Injects every app-owned model plus the shared container and theme.
    ///
    /// Applied to BOTH scenes deliberately. The macOS Settings (⌘,) scene used
    /// to inject only three of the six models — safe at the time, because no
    /// view reachable from it read the others, but `@Environment(T.self)` is
    /// non-optional and *traps* when the type is absent. One future line under
    /// RNS Tools or Identity reading `nomadNet` would have become a crash that
    /// compiles clean, passes tests, and reproduces only in the Preferences
    /// window. Injecting a model no view reads is free (it creates no
    /// observation dependency), so there is no reason to keep the scenes apart.
    private func appEnvironment<C: View>(_ content: C) -> some View {
        content
            .environment(logStore)
            .environment(stack)
            .environment(calls)
            .environment(nomadNet)
            .environment(bleMesh)
            .environment(rnode)
            .environment(notifs)
            .modelContainer(container)
            .rnsTheme()
    }

    var body: some Scene {
        WindowGroup {
            appEnvironment(RootView())
                .task {
                    // Wire the notification manager to CallsController before
                    // bringing up the stack so no incoming calls are missed.
                    notifs.callsController = calls

                    // Request notification permission early — before the first
                    // message or call could arrive — so the system dialog appears
                    // at a natural moment rather than mid-call.
                    await notifs.requestPermission()

                    // DEBUG-only fixture rows for screenshot review; no-op
                    // unless `-seedDemoData YES` and the store is empty.
                    DemoData.seedIfNeeded(container.mainContext)

                    await stack.bringUp(
                        modelContext: container.mainContext,
                        notificationManager: notifs
                    )
                    if let transport = stack.transport,
                       let rns      = stack.reticulum,
                       let identity = stack.identity {
                        calls.setup(transport: transport, identity: identity)
                        nomadNet.setup(transport: transport,
                                       reticulum: rns,
                                       identity:  identity,
                                       modelContext: container.mainContext)
                        bleMesh.onInterfacesChanged = { [weak stack] in
                            stack?.noteInterfacesChanged()
                        }
                        bleMesh.setup(transport: transport)
                        rnode.onInterfacesChanged = { [weak stack] in
                            stack?.noteInterfacesChanged()
                        }
                        rnode.setup(transport: transport)

                        // An offline UI-test run must stay off the air and off
                        // the radios: enabling BLE mesh here would raise the
                        // system Bluetooth dialog on the developer's own Mac,
                        // which an unattended test must never do.
                        if !StackController.isOfflineUITestRun {
                            if bleMesh.enableOnStart {
                                let name = stack.nodeDisplayName.isEmpty ? "RetiOS" : stack.nodeDisplayName
                                bleMesh.enable(localName: name)
                            }
                            // Pick up messages parked at the propagation node while
                            // we were offline. No-op when no node is configured;
                            // if no path is known yet the router downloads as soon
                            // as one arrives (wantsDownloadOnPathAvailableFrom).
                            stack.syncFromPropagationNode()
                        }
                    }
                }
                // iOS tears down idle TCP links while the app is backgrounded,
                // leaving RRC hubs in .disconnected/.failed when the user
                // comes back. Reconnect them the moment the scene is active.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, !StackController.isOfflineUITestRun else { return }
                    nomadNet.reconnectHubs()
                }
        }
        #if os(macOS)
        // Native Mac window sizing — a sensible default, and a floor so the
        // three-column split view can't be crushed into uselessness.
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        #endif
        .commands { appCommands }

        // macOS Preferences window (⌘,). On iOS, Settings is reached via the
        // tab bar / sidebar; the `Settings` scene type is macOS-only.
        #if os(macOS)
        Settings {
            appEnvironment(NavigationStack { SettingsView() })
                .frame(minWidth: 520, minHeight: 560)
        }
        #endif
    }

    // MARK: - Menu-bar commands
    //
    // Routed through `NotificationManager.shared` (not the app-owned
    // controllers) because SwiftUI does not propagate the environment into the
    // `.commands` builder. Views observe the published intents and act; RootView
    // handles Announce / Sync since it always has the stack in its environment.

    @CommandsBuilder
    private var appCommands: some Commands {
        // File ▸ New Message / New Call (replaces the inert default "New").
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                let n = NotificationManager.shared
                n.navigateTo = .messages
                n.requestCompose += 1
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Call") {
                let n = NotificationManager.shared
                n.navigateTo = .calls
                n.requestNewCall += 1
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            // The Add-Contact-by-hash sheet is otherwise reachable only from the
            // Messages toolbar; a menu command is required since the toolbar can
            // be hidden/customized on macOS.
            Button("New Contact") {
                let n = NotificationManager.shared
                n.navigateTo = .messages
                n.requestAddContact += 1
            }
            .keyboardShortcut("n", modifiers: [.command, .control])
        }

        CommandMenu("Reticulum") {
            Button("Announce Now") { NotificationManager.shared.requestAnnounce += 1 }
                .keyboardShortcut("r", modifiers: .command)
            Button("Sync Propagation Node") { NotificationManager.shared.requestSync += 1 }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandMenu("Go") {
            goButton("Messages",   .messages,   "1")
            goButton("Calls",      .calls,      "2")
            goButton("NomadNet",   .nomadNet,   "3")
            goButton("Map",        .map,        "4")
            goButton("Interfaces", .interfaces, "5")
            goButton("Tools",      .tools,      "6")
        }
    }

    private func goButton(_ title: String, _ tab: AppTab, _ key: KeyEquivalent) -> some View {
        Button(title) { NotificationManager.shared.navigateTo = tab }
            .keyboardShortcut(key, modifiers: .command)
    }
}
