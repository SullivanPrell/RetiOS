import SwiftUI
import ReticulumSwift

// MARK: - InterfacesView

struct InterfacesView: View {
    @EnvironmentObject var stack: StackController
    @State private var showAddSheet = false
    @State private var showDirectorySheet = false
    @State private var showYggdrasilSheet = false
    @State private var showYggdrasilNodeSheet = false
    @State private var showI2PSheet = false

    var body: some View {
        List {
            activeSection
            radioSection
            overlayNetworksSection
            addSection
        }
        // Match SettingsView's grouped list treatment (this screen is pushed
        // from Settings on iPhone) rather than inheriting the default style.
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .rnsScreenBackground()
        .navigationTitle("Interfaces")
        .rnsInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .rnsTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Interface")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddInterfaceSheet(mode: .tcp)
                .environmentObject(stack)
        }
        .sheet(isPresented: $showDirectorySheet) {
            InterfaceDirectorySheet()
                .environmentObject(stack)
        }
        .sheet(isPresented: $showYggdrasilSheet) {
            AddInterfaceSheet(mode: .yggdrasil)
                .environmentObject(stack)
        }
        .sheet(isPresented: $showYggdrasilNodeSheet) {
            YggdrasilNodeSheet(vpn: stack.yggdrasilVPN)
                .environmentObject(stack)
        }
        .sheet(isPresented: $showI2PSheet) {
            I2PConfigSheet()
                .environmentObject(stack)
        }
    }

    // MARK: Active interfaces

    private var activeSection: some View {
        Section {
            if stack.isRunning, let transport = stack.transport {
                // Key rows by the interface's unique name, not array offset.
                // Offset-keyed rows mis-associate identity when an interface is
                // added/removed (offsets shift), corrupting remove animations
                // and swipe/context-menu state.
                ForEach(transport.interfaces, id: \.name) { iface in
                    let isSaved = stack.savedInterfaces.contains(where: { $0.name == iface.name })
                        || stack.savedI2PConfig?.name == iface.name
                    InterfaceRow(interface: iface)
                        // allowsFullSwipe:false so a full swipe can't silently
                        // tear down an interface; the revealed button (and the
                        // context menu) require a deliberate tap.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if isSaved {
                                Button(role: .destructive) {
                                    stack.removeInterface(named: iface.name)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            if isSaved {
                                Button(role: .destructive) {
                                    stack.removeInterface(named: iface.name)
                                } label: {
                                    Label("Remove Interface", systemImage: "trash")
                                }
                            }
                        }
                }
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Stack starting…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Active")
        } footer: {
            Text("AutoInterface is always active. Added interfaces are restored automatically on next launch.")
        }
        .rnsRow()
    }

    // MARK: Radio hardware

    private var radioSection: some View {
        Section("Radio Hardware") {
            NavigationLink(destination: RNodeView()) {
                Label("RNode (LoRa / BLE)", systemImage: "dot.radiowaves.left.and.right")
            }
            NavigationLink(destination: BLEMeshView()) {
                Label("BLE Mesh", systemImage: "personalhotspot")
            }
        }
        .rnsRow()
    }

    // MARK: Overlay networks (I2P, Yggdrasil)

    private var overlayNetworksSection: some View {
        Section {
            // I2P
            Button {
                showI2PSheet = true
            } label: {
                HStack {
                    Label("I2P Network", systemImage: "lock.shield")
                    Spacer()
                    if stack.savedI2PConfig != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.rnsSuccess)
                            .font(.caption)
                    } else {
                        Text("Configure")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Yggdrasil — run an embedded node (system VPN packet tunnel).
            Button {
                showYggdrasilNodeSheet = true
            } label: {
                HStack {
                    Label("Yggdrasil Node", systemImage: "globe.europe.africa")
                    Spacer()
                    switch stack.yggdrasilVPN.status {
                    case .connected:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.rnsSuccess)
                            .font(.caption)
                    case .connecting, .reasserting:
                        ProgressView().controlSize(.small)
                    default:
                        Text(stack.savedYggdrasilConfig?.enabled == true ? "Enabled" : "Configure")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Yggdrasil — dial a specific peer over its IPv6 address.
            Button {
                showYggdrasilSheet = true
            } label: {
                Label("Add Yggdrasil Peer…", systemImage: "point.3.connected.trianglepath.dotted")
            }
        } header: {
            Text("Overlay Networks")
        } footer: {
            Text("I2P routes Reticulum over the anonymous I2P network. Run a Yggdrasil Node to give this device its own Yggdrasil IPv6 (a cryptographic mesh overlay); Reticulum then rides over it, interoperable with Python RNS-over-Yggdrasil. Or add a single Yggdrasil peer by its IPv6 address.")
        }
        .rnsRow()
        // These rows present sheets; render them like the adjacent navigation
        // rows (primary text) rather than full-blue Button labels.
        .buttonStyle(.plain)
    }

    // MARK: Add / reference

    private var addSection: some View {
        Section {
            Button {
                showDirectorySheet = true
            } label: {
                Label("Quick Add from Public Directory…", systemImage: "list.bullet.rectangle.portrait")
            }

            Button {
                showAddSheet = true
            } label: {
                Label("Add TCP / IPv6 Gateway…", systemImage: "network.badge.shield.half.filled")
            }

            NavigationLink(destination: InterfaceReferenceView()) {
                Label("Interface types reference", systemImage: "book.pages")
            }
        } header: {
            Text("Add Interface")
        } footer: {
            Text("The public directory lists community-run gateways at directory.rns.recipes — pick one to connect with one tap. IPv4 and IPv6 addresses are both supported.")
        }
        .rnsRow()
        .buttonStyle(.plain)
    }
}

// MARK: - Interface row

private struct InterfaceRow: View {
    let interface: any Interface

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .frame(width: 28)
                .foregroundStyle(Color.rnsAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text(interface.name)
                    .font(.body)

                Text(interfaceTypeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Reflect the interface's real online state instead of a hardcoded
            // green dot — a down/failed interface must not read as "active".
            Circle()
                .fill(interface.isOnline ? Color.rnsSuccess : Color.rnsTextMuted)
                .frame(width: 8, height: 8)
                .accessibilityLabel(interface.isOnline ? "Online" : "Offline")
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        let name = interface.name.lowercased()
        if name.contains("auto") { return "wifi" }
        if name.contains("ygg") || name.contains("yggdrasil") { return "globe.europe.africa" }
        if name.contains("i2p") { return "lock.shield" }
        if name.contains("tcp") { return "network" }
        if name.contains("udp") { return "bolt.horizontal" }
        if name.contains("rnode") || name.contains("ble") || name.contains("serial") {
            return "antenna.radiowaves.left.and.right"
        }
        if name.contains("local") { return "bolt.ring.closed" }
        return "circle.hexagongrid"
    }

    private var interfaceTypeName: String {
        String(describing: type(of: interface))
    }
}

// MARK: - Add interface sheet (TCP / Backbone / Yggdrasil)

struct AddInterfaceSheet: View {
    enum Mode {
        case tcp, backbone, yggdrasil

        var defaultName: String {
            switch self {
            case .tcp:        return "TCP Gateway"
            case .backbone:   return "Backbone Gateway"
            case .yggdrasil:  return "Yggdrasil Peer"
            }
        }

        var defaultPort: String {
            switch self {
            case .tcp, .yggdrasil: return "4242"
            case .backbone:        return "4242"
            }
        }

        var hostPlaceholder: String {
            switch self {
            case .tcp:       return "hostname or IP (IPv4 or IPv6)"
            case .backbone:  return "hostname or IP (IPv4 or IPv6)"
            case .yggdrasil: return "200:xxxx:xxxx:xxxx::1"
            }
        }

        var title: String {
            switch self {
            case .tcp:       return "Add TCP Gateway"
            case .backbone:  return "Add Backbone Gateway"
            case .yggdrasil: return "Add Yggdrasil Peer"
            }
        }

        var sectionHeader: String {
            switch self {
            case .tcp:       return "TCP Gateway"
            case .backbone:  return "Backbone Gateway"
            case .yggdrasil: return "Yggdrasil Peer"
            }
        }

        var footerText: String {
            switch self {
            case .tcp:
                return "Connects RetiOS to a remote Reticulum node over TCP. Both IPv4 addresses and IPv6 addresses (with or without brackets) are accepted."
            case .backbone:
                return "BackboneInterface is optimised for high-bandwidth links (1 MB MTU)."
            case .yggdrasil:
                return "Enter the Yggdrasil IPv6 address of a peer node (starts with 200:). Reticulum routes normally over the Yggdrasil IPv6 mesh."
            }
        }

        var savedKind: StackController.SavedInterfaceKind {
            switch self {
            case .tcp:       return .tcp
            case .backbone:  return .backbone
            case .yggdrasil: return .yggdrasil
            }
        }

        var interfaceTypeLabel: String {
            switch self {
            case .tcp:       return "TCPClientInterface"
            case .backbone:  return "BackboneInterface"
            case .yggdrasil: return "TCPClientInterface (Yggdrasil)"
            }
        }
    }

    let mode: Mode

    @EnvironmentObject var stack: StackController
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port: String
    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var portFocused: Bool

    init(mode: Mode) {
        self.mode = mode
        _name = State(initialValue: mode.defaultName)
        _port = State(initialValue: mode.defaultPort)
    }

    private var canAdd: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && stack.isRunning
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Type") { Text(mode.interfaceTypeLabel) }
                    TextField("Name", text: $name)
                    TextField("Host", text: $host, prompt: Text(mode.hostPlaceholder))
                        .autocorrectionDisabled()
                        .rnsNoAutocapitalization()
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                    TextField("Port", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .focused($portFocused)
                } header: {
                    Text(mode.sectionHeader)
                } footer: {
                    if !stack.isRunning {
                        Text("Waiting for Reticulum stack to start…")
                            .foregroundStyle(Color.rnsWarning)
                    } else {
                        Text(mode.footerText)
                    }
                }
                .rnsRow()

                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.rnsError)
                    }
                    .rnsRow()
                }
            }
            .rnsScreenBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(mode.title)
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addInterface() }
                        .disabled(!canAdd)
                }
                // iOS-only keyboard-accessory "Done"; see IdentityView note.
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { portFocused = false }
                }
                #endif
            }
        }
    }

    private func addInterface() {
        // Strip square brackets from IPv6 literals and trim whitespace.
        let rawHost = host.trimmingCharacters(in: .whitespaces)
        let trimHost = StackController.normalizeHost(rawHost)
        let trimName = name.trimmingCharacters(in: .whitespaces).isEmpty
                       ? mode.defaultName
                       : name.trimmingCharacters(in: .whitespaces)
        guard let portNum = UInt16(port), portNum > 0 else {
            errorMessage = "Port must be a number between 1 and 65535."
            return
        }
        guard let transport = stack.transport else {
            errorMessage = "Stack is not running yet."
            return
        }

        let iface: any Interface
        switch mode {
        case .backbone:
            iface = BackboneInterface(name: trimName, host: trimHost, port: portNum)
        case .tcp, .yggdrasil:
            iface = TCPClientInterface(name: trimName, host: trimHost, port: portNum)
        }
        transport.register(interface: iface)
        do {
            try iface.start()
            stack.saveInterface(name: trimName, host: trimHost, port: portNum, kind: mode.savedKind)
            dismiss()
        } catch {
            transport.halt(interfaceName: trimName)
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - I2P configuration sheet

struct I2PConfigSheet: View {
    @EnvironmentObject var stack: StackController
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var peersText: String = ""
    @State private var connectable: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                configSection
                peersSection

                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.rnsError)
                    }
                    .rnsRow()
                }
            }
            .rnsScreenBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("I2P Network")
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveConfig() }
                }
            }
            .onAppear { loadExistingConfig() }
        }
    }

    // MARK: Sections

    private var configSection: some View {
        Section {
            TextField("Name", text: $name)
        } header: {
            Text("Interface")
        } footer: {
            Text("The embedded i2pd daemon starts automatically with Reticulum and provides an anonymous I2P tunnel. Add peer b32 addresses below to dial out — outbound connections are fully supported. Inbound accept is not yet implemented.")
        }
        .rnsRow()
    }

    private var peersSection: some View {
        Section {
            TextEditor(text: $peersText)
                .font(.caption.monospaced())
                .frame(minHeight: 120)
                .autocorrectionDisabled()
                .rnsNoAutocapitalization()
        } header: {
            Text("Peers (b32 addresses)")
        } footer: {
            Text("One b32 address per line, e.g. abc123xyz…qrs.b32.i2p")
        }
        .rnsRow()
    }

    // MARK: Actions

    private func loadExistingConfig() {
        guard let config = stack.savedI2PConfig else {
            name = "I2P"
            return
        }
        name = config.name
        peersText = config.peers.joined(separator: "\n")
        connectable = config.connectable
    }

    private func saveConfig() {
        let trimName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "I2P" : name.trimmingCharacters(in: .whitespaces)
        let peers = peersText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Validate the peer addresses. This wires up the error Section that was
        // previously dead code — malformed lines used to save silently. The
        // message states the rule the check actually enforces (a `.i2p` suffix,
        // which covers `.b32.i2p`); base64 destinations are dialed via a separate
        // path and aren't entered here.
        if let bad = peers.first(where: { !$0.lowercased().hasSuffix(".i2p") }) {
            errorMessage = "“\(bad)” is not a valid I2P address — addresses must end in .i2p (such as a .b32.i2p address)"
            return
        }
        errorMessage = nil

        let config = StackController.SavedI2PConfig(name: trimName, peers: peers, connectable: connectable)
        stack.saveI2PConfig(config)
        dismiss()
    }
}

// MARK: - Yggdrasil node sheet

/// Configure and control the embedded Yggdrasil node (a system-VPN packet
/// tunnel). Enabling it gives the device a real Yggdrasil IPv6 address; Reticulum
/// then rides over it, interoperable with Python RNS-over-Yggdrasil nodes.
struct YggdrasilNodeSheet: View {
    @EnvironmentObject var stack: StackController
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vpn: YggdrasilVPNManager

    @State private var enabled = false
    @State private var nodeName = ""
    @State private var peersText = ""
    @State private var multicastEnabled = false
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                if vpn.isConfigured || stack.savedYggdrasilConfig != nil {
                    statusSection
                }
                enableSection
                peersSection
                advancedSection

                if hasNoReachability {
                    Section {
                        Label("This node has no peers and LAN discovery is off, so it can't reach the mesh. Add at least one peer URI above.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Color.rnsWarning)
                    }
                    .rnsRow()
                }

                if let err = errorMessage ?? vpn.lastError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.rnsError)
                    }
                    .rnsRow()
                }
            }
            .rnsScreenBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Yggdrasil Node")
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { save() }.disabled(isBusy)
                }
            }
            .onAppear { load() }
            .task { await vpn.refreshManager() }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(vpn.status.rawValue.capitalized)
                }
            }
            if let addr = vpn.nodeAddress {
                LabeledContent("IPv6 address") {
                    Text(addr).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let subnet = vpn.nodeSubnet {
                LabeledContent("Subnet") {
                    Text(subnet).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if !vpn.peers.isEmpty {
                LabeledContent("Peers") {
                    Text("\(vpn.peers.filter { $0.up }.count) up / \(vpn.peers.count)")
                }
            }
            if vpn.status == .connected {
                Button("Retry peers now") { vpn.retryPeers() }
                    .font(.caption)
            }
        } header: {
            Text("Status")
        }
        .rnsRow()
    }

    private var enableSection: some View {
        Section {
            Toggle("Run Yggdrasil node", isOn: $enabled)
            TextField("Node name (optional)", text: $nodeName)
                .autocorrectionDisabled()
        } header: {
            Text("Node")
        } footer: {
            Text("Runs the Yggdrasil engine in a network extension and adds a system VPN carrying only the Yggdrasil range (0200::/7) — your normal traffic is untouched. Requires a Network Extension + App Group enabled Apple Developer team (see YGGDRASIL.md).")
        }
        .rnsRow()
    }

    private var peersSection: some View {
        Section {
            TextEditor(text: $peersText)
                .font(.caption.monospaced())
                .frame(minHeight: 100)
                .autocorrectionDisabled()
                .rnsNoAutocapitalization()
        } header: {
            Text("Peers")
        } footer: {
            Text("One peer URI per line, e.g. tls://host:port or quic://host:port. Find public peers at publicpeers.neilalexander.dev.")
        }
        .rnsRow()
    }

    private var advancedSection: some View {
        Section {
            Toggle("LAN peer discovery (multicast)", isOn: $multicastEnabled)
            if stack.savedYggdrasilConfig != nil {
                Button(role: .destructive) { removeNode() } label: {
                    Text("Remove Yggdrasil node")
                }
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Multicast discovers other Yggdrasil nodes on the local network. It needs the Multicast Networking entitlement (a separate Apple approval) — leave off unless you have it. See YGGDRASIL.md.")
        }
        .rnsRow()
    }

    // MARK: Derived

    private var statusColor: Color {
        switch vpn.status {
        case .connected: return .rnsSuccess
        case .connecting, .reasserting: return .rnsWarning
        default: return .rnsTextMuted
        }
    }

    /// Enabling a node with no peers and no LAN discovery yields a valid address
    /// that can reach no one — warn before that surprises the user.
    private var hasNoReachability: Bool {
        enabled
            && !multicastEnabled
            && peersText.components(separatedBy: .newlines)
                .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Actions

    private func load() {
        if let saved = stack.savedYggdrasilConfig {
            enabled = saved.enabled
            nodeName = saved.nodeName
            peersText = saved.peers.joined(separator: "\n")
            multicastEnabled = saved.multicastEnabled
        }
    }

    private func save() {
        let peers = peersText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if let bad = peers.first(where: { !$0.contains("://") }) {
            errorMessage = "“\(bad)” is not a valid peer URI — use a scheme like tls://host:port."
            return
        }
        errorMessage = nil

        let config = StackController.SavedYggdrasilConfig(
            enabled: enabled,
            peers: peers,
            nodeName: nodeName.trimmingCharacters(in: .whitespaces),
            multicastEnabled: multicastEnabled
        )
        isBusy = true
        Task {
            await stack.saveYggdrasilConfig(config)
            isBusy = false
        }
    }

    private func removeNode() {
        isBusy = true
        Task {
            await stack.removeYggdrasilConfig()
            isBusy = false
            enabled = false
            peersText = ""
            nodeName = ""
            multicastEnabled = false
        }
    }
}

// MARK: - Interface reference

private struct InterfaceReferenceView: View {
    struct InterfaceType: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        let description: String
        let swiftStatus: String
    }

    private let types: [InterfaceType] = [
        .init(name: "AutoInterface", icon: "wifi",
              description: "UDP multicast on the local LAN. Automatically discovers nearby Reticulum nodes. Works on the same subnet without any configuration.",
              swiftStatus: "Complete"),
        .init(name: "TCPClientInterface", icon: "network",
              description: "Connects to a remote Reticulum node or gateway over TCP. Accepts IPv4 and IPv6 addresses. Use this to bridge to the internet mesh.",
              swiftStatus: "Complete"),
        .init(name: "TCPServerInterface", icon: "server.rack",
              description: "Listens for inbound TCP connections. Lets other nodes connect to this device.",
              swiftStatus: "Complete"),
        .init(name: "UDPInterface", icon: "bolt.horizontal",
              description: "Point-to-point or broadcast UDP over IPv4 or IPv6. Useful for custom radio links and tunnels.",
              swiftStatus: "Complete"),
        .init(name: "Yggdrasil (TCP/IPv6)", icon: "globe.europe.africa",
              description: "Reticulum over Yggdrasil — a cryptographic mesh IPv6 network. Run an embedded Yggdrasil Node (Overlay Networks) to give this device its own Yggdrasil IPv6 via a system VPN, then reach peers with ordinary TCP/Backbone over their 0200::/7 addresses. Wire-compatible with Python RNS-over-Yggdrasil.",
              swiftStatus: "Complete"),
        .init(name: "RNodeInterface", icon: "antenna.radiowaves.left.and.right",
              description: "RNode LoRa hardware over BLE or USB serial. Physical radio mesh.",
              swiftStatus: "In progress"),
        .init(name: "I2PInterface", icon: "lock.shield",
              description: "Routes traffic through the I2P anonymity network using an embedded i2pd daemon. Works on iOS and macOS — run build_ci2pd_ios.sh once to add the iOS xcframework slice.",
              swiftStatus: "Complete"),
        .init(name: "LocalInterface", icon: "bolt.ring.closed",
              description: "Connects to an existing rnsd daemon running on the same machine (macOS / Linux).",
              swiftStatus: "Complete"),
    ]

    var body: some View {
        List(types) { t in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: t.icon)
                        .foregroundStyle(Color.rnsAccent)
                        .frame(width: 24)
                    Text(t.name)
                        .font(.headline)
                    Spacer()
                    RNSBadge(text: t.swiftStatus, color: statusColor(t.swiftStatus))
                }
                Text(t.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .rnsRow()
        }
        .rnsScreenBackground()
        .navigationTitle("Interface Types")
        .rnsInlineNavigationTitle()
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "Complete":    return .rnsSuccess
        case "In progress": return .rnsWarning
        default:            return .rnsTextMuted
        }
    }
}
