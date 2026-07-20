import SwiftUI
import ReticulumSwift

/// Scan for a MeshCore companion device, configure the tunnel channel, and bring up
/// a `MeshCoreDynamicInterface` over BLE. Mirrors `RNodeView`'s scan/connect flow,
/// with a channel-configuration section (all tunnel nodes must share the channel
/// name, secret, and index).
struct MeshCoreView: View {
    @EnvironmentObject var stack: StackController
    @StateObject private var scanner = MeshCoreScannerController()

    var body: some View {
        List {
            connectionSection
            if scanner.state.isOnline {
                statusSection
            } else {
                configSection
                scanSection
            }
        }
        .rnsScreenBackground()
        .navigationTitle("MeshCore (BLE)")
        .toolbar { scanToolbar }
        .onAppear {
            if let t = stack.transport { scanner.setup(transport: t, stack: stack) }
        }
        .onDisappear { scanner.stopScanning() }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("Connection") {
            HStack(spacing: 10) {
                stateIcon
                Text(scanner.state.label).font(.body)
                Spacer()
                if scanner.state.isOnline {
                    Button("Disconnect", role: .destructive) { scanner.disconnect() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }
        .rnsRow()
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch scanner.state {
        case .online:
            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .foregroundStyle(Color.rnsSuccess).font(.title2)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.rnsError).font(.title2)
        case .bluetoothUnavailable:
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(Color.rnsError).font(.title2)
        case .scanning, .connecting, .discoveringServices, .bringingUp:
            ProgressView().controlSize(.regular)
        case .idle:
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.secondary).font(.title2)
        }
    }

    // MARK: - Channel configuration

    private var configSection: some View {
        Section {
            TextField("Interface name", text: $scanner.interfaceName)
            TextField("Channel name", text: $scanner.channelName)

            HStack {
                TextField("Channel secret (32 hex)", text: $scanner.channelSecretHex)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !scanner.secretIsValid {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.rnsWarning)
                }
                Button("Generate") { scanner.channelSecretHex = Self.randomSecretHex() }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            Stepper("Channel slot: \(scanner.channelIndex)", value: $scanner.channelIndex, in: 0...7)
            Toggle("Access-point mode", isOn: $scanner.accessPointMode)
            Toggle("Route for the mesh", isOn: $scanner.canRoute)
        } header: {
            Text("Tunnel Channel")
        } footer: {
            Text("All nodes on the tunnel must share the same channel name, secret, and slot. Access-point mode is recommended on LoRa segments.")
        }
        .rnsRow()
    }

    // MARK: - Scan

    private var scanSection: some View {
        Section {
            if case .bluetoothUnavailable = scanner.state {
                Label("Bluetooth is unavailable or not authorized.",
                      systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(Color.rnsError)
            } else if scanner.discovered.isEmpty {
                ContentUnavailableView(
                    "No MeshCore devices found",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Power on a MeshCore companion device and tap Scan.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(scanner.discovered) { device in
                    DeviceRow(device: device, connectEnabled: scanner.secretIsValid) {
                        scanner.connect(to: device)
                    }
                }
            }
        } header: {
            Text("Nearby Devices")
        } footer: {
            Text(scanner.secretIsValid
                 ? "Only MeshCore companion devices appear here."
                 : "Enter a valid 32-hex-character channel secret before connecting.")
        }
        .rnsRow()
    }

    // MARK: - Online status

    private var statusSection: some View {
        Section("Interface") {
            if let iface = scanner.meshInterface {
                LabeledContent("Name", value: iface.name)
                LabeledContent("Mode", value: scanner.accessPointMode ? "access_point" : "full")
                LabeledContent("Channel", value: "\(scanner.channelName) (slot \(scanner.channelIndex))")
                LabeledContent("Routing", value: scanner.canRoute ? "router" : "edge")
                LabeledContent("RX / TX") {
                    Text("\(iface.rxPackets) / \(iface.txPackets)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .rnsRow()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var scanToolbar: some ToolbarContent {
        ToolbarItem(placement: .rnsTrailing) {
            if case .scanning = scanner.state {
                Button("Stop") { scanner.stopScanning() }
            } else if !scanner.state.isOnline {
                Button("Scan") { scanner.startScanning() }
                    .disabled(scanner.state == .bluetoothUnavailable)
            }
        }
    }

    // MARK: - Helpers

    /// Generate a fresh 16-byte channel secret as hex (`openssl rand -hex 16`).
    private static func randomSecretHex() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    let device: MeshCoreScannerController.DiscoveredDevice
    let connectEnabled: Bool
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.rnsAccent).frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body)
                Text(device.id.uuidString.prefix(8).lowercased())
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            Spacer()
            rssiIndicator(device.rssi)

            Button("Connect", action: onConnect)
                .buttonStyle(.bordered).controlSize(.small).tint(.rnsAccent)
                .disabled(!connectEnabled)
        }
        .padding(.vertical, 2)
    }

    private func rssiIndicator(_ rssi: Int) -> some View {
        let bars: Int
        switch rssi {
        case _ where rssi > -70: bars = 3
        case _ where rssi > -90: bars = 2
        default:                  bars = 1
        }
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= bars ? Color.rnsAccent : Color.rnsBorder)
                    .frame(width: 4, height: CGFloat(i * 4 + 2))
            }
        }
        .frame(width: 18)
        .accessibilityElement()
        .accessibilityLabel("Signal strength")
        .accessibilityValue("\(bars) of 3 bars, \(rssi) dBm")
    }
}
