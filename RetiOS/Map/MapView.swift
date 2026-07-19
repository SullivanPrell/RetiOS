import SwiftUI
import MapKit
import CoreLocation
import ReticulumSwift
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - MapView
//
// Early version of a Meshtastic-style map tab: shows the device's own
// position on Apple Maps, requests location permission up front, and
// offers a GPS-source picker (device vs. an attached RNode). RNode
// firmware doesn't report position data yet — the RNode option surfaces
// connection status honestly and is wired up to flip on the moment that
// lands (see Phase 13 RNode work in tasks/todo.md). MapKit transparently
// caches recently-viewed tiles for offline use; downloadable region packs
// are a later enhancement (see the "Offline Maps" info sheet).

struct MapView: View {
    @EnvironmentObject var stack: StackController
    @StateObject private var locationManager = LocationManager()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var gpsSource: GPSSource = .device
    @State private var showOfflineInfo = false
    @State private var hasCenteredOnce = false

    enum GPSSource: String, CaseIterable, Identifiable {
        case device = "Device"
        case rnode  = "RNode"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Map(position: $cameraPosition) {
                    UserAnnotation()
                }
                .mapControls {
                    // Native user-location control — manages follow/heading
                    // tracking state itself, unlike a hand-rolled center button.
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .ignoresSafeArea(edges: .bottom)

                if needsPermissionPrompt {
                    permissionCard
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }
            }
            .rnsCanvasBackground()
            .navigationTitle("Map")
            // Inline title: a large title floating over a full-bleed map reads
            // awkwardly (cf. Apple Maps, which keeps its title compact).
            .rnsInlineNavigationTitle()
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { sourceBar }
            .onAppear { locationManager.requestAuthorizationIfNeeded() }
            .onChange(of: locationManager.location) { _, new in
                guard let new, gpsSource == .device, !hasCenteredOnce else { return }
                hasCenteredOnce = true
                center(on: new.coordinate)
            }
            .sheet(isPresented: $showOfflineInfo) { OfflineMapsInfoSheet() }
        }
    }

    private var needsPermissionPrompt: Bool {
        switch locationManager.authorizationStatus {
        case .notDetermined, .denied, .restricted: return true
        default: return false
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Centering on the user's location is handled by the native
        // MapUserLocationButton in `.mapControls`, so no custom toolbar button.
        ToolbarItem(placement: .rnsTrailing) {
            Button {
                showOfflineInfo = true
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .accessibilityLabel("Offline maps info")
        }
    }

    private func center(on coordinate: CLLocationCoordinate2D) {
        withAnimation(.easeInOut) {
            cameraPosition = .region(MKCoordinateRegion(center: coordinate,
                                                         latitudinalMeters: 1500,
                                                         longitudinalMeters: 1500))
        }
    }

    // MARK: Permission card

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Location Access Needed", systemImage: "location.slash")
                .font(.headline)
            Text(permissionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            if locationManager.authorizationStatus == .notDetermined {
                Button("Allow Location Access") {
                    locationManager.requestAuthorizationIfNeeded()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.rnsAccent)
            } else {
                Button("Open Settings") { openSystemSettings() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var permissionMessage: String {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return "RetiOS can show your position on the map and, later, share it with the mesh. Grant location access to get started."
        default:
            return "Location access is currently denied. Enable it in Settings to see your position on the map."
        }
    }

    private func openSystemSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        // Route to the Location Services privacy pane so the "Open Settings"
        // button isn't a dead no-op on the Mac.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: GPS source bar

    private var sourceBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("GPS Source", selection: $gpsSource) {
                ForEach(GPSSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: gpsSource) { _, new in
                if new == .device, let coordinate = locationManager.location?.coordinate {
                    center(on: coordinate)
                }
            }

            sourceStatusRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var sourceStatusRow: some View {
        switch gpsSource {
        case .device:
            statusLine(ok: locationManager.location != nil,
                       text: locationManager.location != nil
                            ? "Using this device's location"
                            : "Waiting for a location fix…")
        case .rnode:
            statusLine(ok: false, text: rnodeStatusText)
        }
    }

    private func statusLine(ok: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Color.rnsSuccess : Color.rnsTextMuted)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// The RNode firmware doesn't report GPS fixes over KISS yet — this
    /// reads connection state honestly so the option is visible and ready
    /// to light up the moment that protocol support lands.
    private var rnodeStatusText: String {
        guard let iface = connectedRNodeInterface else {
            return "No RNode connected — pair one in Settings → RNode (BLE)"
        }
        return "\(iface.name) connected — this firmware doesn't report GPS yet"
    }

    private var connectedRNodeInterface: RNodeInterface? {
        stack.transport?.interfaces.compactMap { $0 as? RNodeInterface }.first
    }
}

// MARK: - Offline maps info sheet

private struct OfflineMapsInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Recently viewed areas stay available offline", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.rnsSuccess)
                    Text("Apple Maps tiles you've already viewed are cached automatically, so areas you've explored remain visible without a connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("How it works today")
                }

                Section {
                    Text("Downloadable offline region packs — so you can pre-fetch an area before heading off-grid — are planned for a future update, alongside RNode-sourced GPS and shared mesh positions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Coming later")
                } footer: {
                    Text("This map tab is an early version — expect more here soon.")
                }
            }
            .rnsScreenBackground()
            .navigationTitle("Offline Maps")
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
