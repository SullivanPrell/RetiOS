import SwiftUI
import SwiftData
import ReticulumSwift

@main
struct RetiOSApp: App {
    // RNSLogStore is created first so it installs the log handler before bringUp().
    // @Observable model → owned with @State and shared via .environment (NOT
    // @StateObject/.environmentObject, which are the ObservableObject spelling).
    @State private var logStore = RNSLogStore()
    @StateObject private var stack     = StackController()
    @StateObject private var calls     = CallsController()
    @StateObject private var nomadNet  = NomadNetController()
    // Owned here (not as a per-view @StateObject in BLEMeshView) so the mesh
    // radio — and the UI state that reflects it — survives navigation. A
    // view-scoped controller would be torn down and recreated every time the
    // user left and returned to the BLE Mesh screen: the radio it started
    // would keep running (registered with `stack.transport`), but the fresh
    // controller would show "Off"/0 peers, and re-toggling would spin up a
    // *second*, conflicting CoreBluetooth stack on top of the first.
    @StateObject private var bleMesh   = BLEMeshController()
    // NotificationManager is a singleton but injected as an EnvironmentObject so
    // views can observe navigateTo / openConversationHash reactively.
    @StateObject private var notifs    = NotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase

    private let container = PersistenceController.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(logStore)
                .environmentObject(stack)
                .environmentObject(calls)
                .environmentObject(nomadNet)
                .environmentObject(bleMesh)
                .environmentObject(notifs)
                .modelContainer(container)
                .rnsTheme()
                .task {
                    // Wire the notification manager to CallsController before
                    // bringing up the stack so no incoming calls are missed.
                    notifs.callsController = calls

                    // Request notification permission early — before the first
                    // message or call could arrive — so the system dialog appears
                    // at a natural moment rather than mid-call.
                    await notifs.requestPermission()

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
                        bleMesh.setup(transport: transport)
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
                // iOS tears down idle TCP links while the app is backgrounded,
                // leaving RRC hubs in .disconnected/.failed when the user
                // comes back. Reconnect them the moment the scene is active.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
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
            NavigationStack { SettingsView() }
                .environmentObject(stack)
                .environmentObject(calls)
                .environment(logStore)
                .modelContainer(container)
                .rnsTheme()
                .frame(minWidth: 520, minHeight: 560)
        }
        #endif
    }

    // MARK: - Menu-bar commands
    //
    // Routed through `NotificationManager.shared` (not the @StateObject
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
