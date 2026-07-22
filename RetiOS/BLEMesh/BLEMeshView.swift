import SwiftUI
import ReticulumSwift

// MARK: - BLEMeshView

/// Status & control screen for the BLE mesh radio — the BLE-mesh counterpart
/// to `RNodeView`.
///
/// Where `RNodeView` walks the user through scanning for and connecting to
/// one specific piece of hardware, BLE Mesh has nothing to pick: it's a
/// single on/off toggle. Once enabled, `BLEMeshController` brings up dual-role
/// CoreBluetooth and `CoreBluetoothMeshTransport` links with whoever it finds,
/// fully automatically — so this view's job is simply to surface that state
/// (on/off/unavailable/failed) and a live peer count, mirroring the
/// "Active interfaces" / radio-readout style used elsewhere in Settings.
struct BLEMeshView: View {
    @Environment(StackController.self) private var stack
    // Owned at the app level (see `RetiOSApp`) and shared via the environment
    // — not a per-view @State controller. The mesh radio must keep running (and
    // this view must keep reflecting its real state) whether or not the user
    // is currently looking at this screen; a view-scoped controller would be
    // torn down on navigation while its radio kept running headless beneath it.
    @Environment(BLEMeshController.self) private var controller

    var body: some View {
        List {
            statusSection
            if controller.state.isOnline {
                meshSection
            }
            aboutSection
        }
        .rnsScreenBackground()
        .navigationTitle("BLE Mesh")
        // Inline title (flush, no large-title dead space) — matches the other
        // pushed detail screens (Interfaces, Logs, Identity).
        .rnsInlineNavigationTitle()
        .onAppear {
            if let t = stack.transport { controller.setup(transport: t) }
        }
    }

    // MARK: - Status section

    private var statusSection: some View {
        Section {
            HStack(spacing: 10) {
                stateIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.state.label)
                        .font(.body)
                    if controller.state.isOnline {
                        Text(peerSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: meshEnabledBinding)
                    .labelsHidden()
                    .disabled(toggleDisabled)
                    .accessibilityLabel("BLE Mesh")
            }
            .padding(.vertical, 2)

            Toggle("Enable on start", isOn: Binding(
                get:  { controller.enableOnStart },
                set:  { controller.setEnableOnStart($0) }
            ))
        } header: {
            Text("Status")
        } footer: {
            if controller.state == .bluetoothUnavailable {
                Text("Bluetooth is unavailable or not authorized. Enable it in Settings to mesh with nearby devices.")
                    .foregroundStyle(Color.rnsError)
            }
        }
        .rnsRow()
    }

    private var peerSummary: String {
        switch controller.peerCount {
        case 0:  return "Searching for nearby devices…"
        case 1:  return "1 peer in range"
        default: return "\(controller.peerCount) peers in range"
        }
    }

    private var toggleDisabled: Bool {
        switch controller.state {
        case .bluetoothUnavailable, .starting: return true
        default: return false
        }
    }

    private var meshEnabledBinding: Binding<Bool> {
        Binding(
            get: { controller.state.isOnline || controller.state == .starting },
            set: { isOn in
                if isOn {
                    let name = stack.nodeDisplayName.isEmpty ? "RetiOS" : stack.nodeDisplayName
                    controller.enable(localName: name)
                } else {
                    controller.disable()
                }
            }
        )
    }

    @ViewBuilder
    private var stateIcon: some View {
        // NOTE: there is no "bluetooth" SF Symbol — Apple ships none of
        // `bluetooth`/`bluetooth.circle`/`bluetooth.circle.fill`/`bluetooth.slash`
        // (likely a Bluetooth-SIG trademark/licensing restriction on the rune);
        // referencing them silently renders nothing, which is what was here.
        //
        // `personalhotspot` is the closest *real* glyph to the original intent:
        // a deliberately distinct family from `antenna.radiowaves.left.and.right`
        // (`RNodeView`'s LoRa-radio icons, and "Manage Interfaces" in Settings),
        // so this screen — specifically about the BLE radio — still reads at a
        // glance as a different kind of radio. Mirrors `RNodeView`'s online/idle
        // pairing: filled circle while active, plain outline while idle.
        switch controller.state {
        case .online:
            Image(systemName: "personalhotspot.circle.fill")
                .foregroundStyle(Color.rnsSuccess)
                .font(.title2)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.rnsError)
                .font(.title2)
        case .bluetoothUnavailable:
            Image(systemName: "personalhotspot.slash")
                .foregroundStyle(Color.rnsError)
                .font(.title2)
        case .starting:
            ProgressView()
                .controlSize(.regular)
        case .idle:
            Image(systemName: "personalhotspot.circle")
                .foregroundStyle(Color.secondary)
                .font(.title2)
        }
    }

    // MARK: - Mesh readout (shown when online)

    private var meshSection: some View {
        Section("Mesh") {
            LabeledContent("Connected peers") {
                Text("\(controller.peerCount)")
                    .foregroundStyle(.secondary)
                    .font(.caption.monospaced())
            }
            // Read the controller's mirrored counters, not the interface's own.
            // `BLEMeshInterface` is not observable, so reading it here would
            // register no dependency and the rows would never refresh.
            if controller.meshInterface != nil {
                LabeledContent("Sent") {
                    Text(prettyCount(controller.txPackets, bytes: controller.txBytes))
                        .foregroundStyle(.secondary)
                        .font(.caption.monospaced())
                }
                LabeledContent("Received") {
                    Text(prettyCount(controller.rxPackets, bytes: controller.rxBytes))
                        .foregroundStyle(.secondary)
                        .font(.caption.monospaced())
                }
            }
        }
        .rnsRow()
    }

    private func prettyCount(_ packets: Int, bytes: Int) -> String {
        "\(packets) pkt\(packets == 1 ? "" : "s") · \(prettyByteCount(bytes))"
    }

    private func prettyByteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - About section

    private var aboutSection: some View {
        Section {
            Text("BLE Mesh lets this device mesh directly with nearby phones running RetiOS over Bluetooth Low Energy — no RNode hardware, router, or internet connection required. Every device that joins extends the reach of the mesh for everyone nearby.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("About")
        } footer: {
            Text("Uses Bluetooth Low Energy. Range is short — typically tens of meters indoors. Keeping the mesh on increases battery use.")
        }
        .rnsRow()
    }
}
