import SwiftUI
import ReticulumSwift

struct RNodeView: View {
    @EnvironmentObject var stack: StackController
    @StateObject private var scanner = RNodeScannerController()

    var body: some View {
        List {
            connectionSection
            if scanner.state.isOnline {
                radioSection
            } else {
                scanSection
            }
        }
        .rnsScreenBackground()
        .navigationTitle("RNode (BLE)")
        .toolbar { scanToolbar }
        .onAppear {
            if let t = stack.transport { scanner.setup(transport: t) }
        }
        .onDisappear {
            scanner.stopScanning()
        }
    }

    // MARK: - Connection section

    private var connectionSection: some View {
        Section("Connection") {
            HStack(spacing: 10) {
                stateIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(scanner.state.label)
                        .font(.body)
                    if case .online = scanner.state, let iface = scanner.rNodeInterface {
                        Text("fw \(iface.majVersion).\(iface.minVersion)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if scanner.state.isOnline {
                    Button("Disconnect", role: .destructive) {
                        scanner.disconnect()
                    }
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
                .foregroundStyle(Color.rnsSuccess)
                .font(.title2)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.rnsError)
                .font(.title2)
        case .bluetoothUnavailable:
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(Color.rnsError)
                .font(.title2)
        case .scanning, .connecting, .discoveringServices, .detecting:
            ProgressView()
                .controlSize(.regular)
        case .idle:
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Color.secondary)
                .font(.title2)
        }
    }

    // MARK: - Scan section

    private var scanSection: some View {
        Section {
            if case .bluetoothUnavailable = scanner.state {
                Label("Bluetooth is unavailable or not authorized.", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(Color.rnsError)
            } else if scanner.discovered.isEmpty {
                ContentUnavailableView(
                    "No RNodes found",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Power on an RNode and tap Scan.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(scanner.discovered) { device in
                    DeviceRow(device: device) {
                        scanner.connect(to: device)
                    }
                }
            }
        } header: {
            Text("Nearby Devices")
        } footer: {
            Text("Only devices advertising the Nordic UART Service (NUS) appear here.")
        }
        .rnsRow()
    }

    // MARK: - Radio config readout (shown when online)

    private var radioSection: some View {
        Section("Radio Parameters") {
            if let iface = scanner.rNodeInterface {
                radioRow("Frequency", value: iface.rFrequency.map { formatFreq($0) })
                radioRow("Bandwidth", value: iface.rBandwidth.map { formatBandwidth($0) })
                radioRow("Spreading factor", value: iface.rSf.map { "SF\($0)" })
                radioRow("Coding rate", value: iface.rCr.map { "4/\($0)" })
                radioRow("TX power", value: iface.rTxPower.map { "\($0) dBm" })

                LabeledContent("RSSI") {
                    if let rssi = iface.rStatRssi {
                        rssiLabel(rssi)
                    } else {
                        Text("—").foregroundStyle(.secondary).font(.caption.monospaced())
                    }
                }

                LabeledContent("SNR") {
                    if let snr = iface.rStatSnr {
                        Text(String(format: "%.1f dB", snr))
                            .foregroundStyle(.secondary).font(.caption.monospaced())
                    } else {
                        Text("—").foregroundStyle(.secondary).font(.caption.monospaced())
                    }
                }

                batteryRow(iface.rBatteryState)
            }
        }
        .rnsRow()
    }

    private func radioRow(_ label: String, value: String?) -> some View {
        LabeledContent(label) {
            Text(value ?? "—")
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                .font(.caption.monospaced())
        }
    }

    private func rssiLabel(_ rssi: Int) -> some View {
        let color: Color = rssi > -90 ? .rnsSuccess : rssi > -110 ? .rnsWarning : .rnsError
        return Text("\(rssi) dBm")
            .foregroundStyle(color)
            .font(.caption.monospaced())
    }

    private func batteryRow(_ state: UInt8) -> some View {
        let label: String
        let color: Color
        switch state {
        case RNodeInterface.batteryStateCharging:
            label = "Charging";    color = .rnsInfo
        case RNodeInterface.batteryStateCharged:
            label = "Charged";     color = .rnsSuccess
        case RNodeInterface.batteryStateDischarging:
            label = "Discharging"; color = .rnsWarning
        default:
            label = "—";           color = Color.secondary
        }
        return LabeledContent("Battery") {
            Text(label).foregroundStyle(color).font(.caption.monospaced())
        }
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

    // MARK: - Formatting helpers

    private func formatFreq(_ hz: UInt32) -> String {
        let mhz = Double(hz) / 1_000_000
        return String(format: "%.3f MHz", mhz)
    }

    private func formatBandwidth(_ hz: UInt32) -> String {
        if hz >= 1000 { return "\(hz / 1000) kHz" }
        return "\(hz) Hz"
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    let device: RNodeScannerController.DiscoveredDevice
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Color.rnsAccent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body)
                Text(device.id.uuidString.prefix(8).lowercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            rssiIndicator(device.rssi)

            Button("Connect", action: onConnect)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.rnsAccent)
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
        // The bars are purely visual — expose signal strength to VoiceOver.
        .accessibilityElement()
        .accessibilityLabel("Signal strength")
        .accessibilityValue("\(bars) of 3 bars, \(rssi) dBm")
    }
}
