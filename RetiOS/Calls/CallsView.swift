import SwiftUI

struct CallsView: View {
    @EnvironmentObject var calls: CallsController
    @EnvironmentObject var notifs: NotificationManager
    @State private var showNewCall = false
    @State private var idleSection: CallsIdleSection = .recents

    var body: some View {
        NavigationStack {
            Group {
                switch calls.callState {
                case .idle:
                    idleContainerView
                case .incoming(let callerHash):
                    incomingCallView(callerHash: callerHash)
                case .calling(let hash):
                    callingView(hash: hash)
                case .active(let hash, let since):
                    activeCallView(hash: hash, since: since)
                case .failed(let reason):
                    failedView(reason: reason)
                }
            }
            .rnsCanvasBackground()
            .navigationTitle("Calls")
            .rnsNavigationBar()
            .toolbar {
                ToolbarItem(placement: .rnsTrailing) {
                    Button(action: { showNewCall = true }) {
                        Image(systemName: "phone.badge.plus")
                    }
                    .accessibilityLabel("New Call")
                    .disabled(calls.callState != .idle)
                }
            }
            .sheet(isPresented: $showNewCall) {
                NewCallSheet()
            }
            .rnsFeedback(trigger: calls.callState) { _, new in
                switch new {
                case .active:   return .success
                case .failed:   return .error
                case .incoming: return .impact(weight: .medium)
                default:        return nil
                }
            }
            // Menu-bar "File ▸ New Call" (⌘⇧C). Only when idle — matches the
            // toolbar button's disabled state.
            .onChange(of: notifs.requestNewCall) { _, _ in
                if calls.callState == .idle { showNewCall = true }
            }
        }
    }

    // MARK: - Idle container (tabs)

    private var idleContainerView: some View {
        VStack(spacing: 0) {
            RNSSectionPicker([
                ("Recents", CallsIdleSection.recents),
                ("Peers",   CallsIdleSection.peers)
            ], selection: $idleSection)

            Group {
                switch idleSection {
                case .recents:
                    CallsRecentsContent()
                case .peers:
                    CallsPeersContent { hash in
                        if let data = Data(hexString: hash) {
                            calls.startCall(to: data)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Call states

    private func incomingCallView(callerHash: Data) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "phone.arrow.down.left.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.rnsAccent)
                .symbolEffect(.pulse)
                .accessibilityHidden(true)
            Text("Incoming Call")
                .font(.title2.bold())
            if callerHash.isEmpty {
                Text("Unknown caller")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(callerHash.hexString.truncatedHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 40) {
                VStack(spacing: 8) {
                    Button(action: { calls.rejectIncomingCall() }) {
                        Image(systemName: "phone.down.fill")
                            .font(.title)
                            .frame(width: 64, height: 64)
                            .background(Color.rnsError, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Decline call")
                    Text("Decline")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 8) {
                    Button(action: { calls.acceptIncomingCall() }) {
                        Image(systemName: "phone.fill")
                            .font(.title)
                            .frame(width: 64, height: 64)
                            .background(Color.rnsSuccess, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Accept call")
                    Text("Accept")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }

    private func callingView(hash: Data) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Calling…")
                .font(.title2)
            Text(hash.hexString.truncatedHash)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button(role: .destructive, action: { calls.endCall() }) {
                Label("Cancel", systemImage: "phone.down.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.rnsError)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }

    private func activeCallView(hash: Data, since: Date) -> some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(Color.rnsSuccess)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Connected")
                    .font(.title2.bold())
                Text(hash.hexString.truncatedHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(since, style: .timer)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 40) {
                VStack(spacing: 8) {
                    Button(action: { calls.toggleMute() }) {
                        Image(systemName: calls.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.title)
                            .frame(width: 64, height: 64)
                            // `.quaternary` is the native, cross-platform fill for an
                            // inactive control — a translucent neutral that stays visible
                            // on ANY background in both Light and Dark. (Grouped-tertiary
                            // matched the grouped call screen exactly in Light, making the
                            // circle invisible; plain `Color(.systemGray5)` is UIKit-only.)
                            .background(calls.isMuted ? AnyShapeStyle(Color.rnsWarning)
                                                      : AnyShapeStyle(.quaternary),
                                        in: Circle())
                            .foregroundStyle(calls.isMuted ? .white : .primary)
                    }
                    .accessibilityLabel(calls.isMuted ? "Unmute microphone" : "Mute microphone")
                    Text(calls.isMuted ? "Unmute" : "Mute")
                        .font(.caption)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 8) {
                    Button(action: { calls.endCall() }) {
                        Image(systemName: "phone.down.fill")
                            .font(.title)
                            .frame(width: 64, height: 64)
                            .background(Color.rnsError, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("End call")
                    Text("End")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }

    private func failedView(reason: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color.rnsError)
                .accessibilityHidden(true)
            Text("Call Failed")
                .font(.title2.bold())
            Text(reason)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Dismiss") { calls.endCall() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Idle section enum

private enum CallsIdleSection: Hashable { case recents, peers }

// MARK: - Recents content

private struct CallsRecentsContent: View {
    @EnvironmentObject var calls: CallsController

    var body: some View {
        if calls.callHistory.isEmpty {
            RNSEmptyState(
                title: "No Recent Calls",
                systemImage: "phone.arrow.up.right",
                description: "Your call history will appear here once you make or receive a call."
            )
        } else {
            List(calls.callHistory) { record in
                // Tap a recent to call back (matches the Phone app). Recents are
                // only shown while idle, so starting a call here is always safe.
                Button {
                    if !record.peerHash.isEmpty, let data = Data(hexString: record.peerHash) {
                        calls.startCall(to: data)
                    }
                } label: {
                    CallRecordRow(record: record)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Call back")
                .rnsRow()
            }
            .listStyle(.plain)
            .rnsScreenBackground()
        }
    }
}

private struct CallRecordRow: View {
    let record: CallRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: directionIcon)
                .foregroundStyle(outcomeColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.peerHash.isEmpty ? "Unknown" : record.peerHash)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(outcomeLabel)
                        .font(.caption)
                        .foregroundStyle(outcomeColor)
                    if let dur = record.duration {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(durationString(dur))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text(record.startTime, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var directionIcon: String {
        switch record.direction {
        case .outbound: return "phone.arrow.up.right"
        case .inbound:  return "phone.arrow.down.left"
        }
    }

    private var outcomeLabel: String {
        switch record.outcome {
        case .calling:      return "Calling…"
        case .answered:     return record.direction == .inbound ? "Received" : "Outgoing"
        case .missed:       return "Missed"
        case .rejected:     return "Declined"
        case .failed:       return "Failed"
        }
    }

    private var outcomeColor: Color {
        switch record.outcome {
        case .answered:              return .rnsSuccess
        case .missed:                return .rnsError
        case .rejected:              return .rnsWarning
        case .failed, .calling:      return .secondary
        }
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}

// MARK: - LXST Peers content

private struct CallsPeersContent: View {
    @EnvironmentObject var calls: CallsController
    let onCall: (String) -> Void

    var body: some View {
        if calls.lxstPeers.isEmpty {
            RNSEmptyState(
                title: "No LXST Peers",
                systemImage: "phone.badge.waveform",
                description: "Peers that have announced their LXST call address will appear here. Enable LXST announcing in Settings so others can call you too."
            )
        } else {
            List(calls.lxstPeers) { peer in
                LXSTPeerRow(peer: peer, onCall: onCall)
                    .rnsRow()
            }
            .listStyle(.plain)
            .rnsScreenBackground()
        }
    }
}

private struct LXSTPeerRow: View {
    let peer: LXSTPeer
    let onCall: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            PeerIdentityView(name: nil, hash: peer.destinationHash, lastSeen: peer.lastSeen)
            Spacer()
            Button {
                onCall(peer.destinationHash)
            } label: {
                Image(systemName: "phone.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.rnsSuccess)
            .accessibilityLabel("Call peer")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - New call sheet

struct NewCallSheet: View {
    @EnvironmentObject var calls: CallsController
    @Environment(\.dismiss) private var dismiss
    @State private var hashInput = ""
    @State private var inputError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination Hash") {
                    TextField("32-character hex hash", text: $hashInput)
                        .rnsHashFieldStyle()
                        .onChange(of: hashInput) { _, new in
                            hashInput = String(new.filter { $0.isHexDigit }.prefix(32))
                        }
                    if let err = inputError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Color.rnsError)
                    }
                }
                .rnsRow()
                Section {
                    Text("Enter the 32-hex-character destination hash (16 bytes) of the remote LXST node.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .rnsRow()
            }
            .rnsScreenBackground()
            .navigationTitle("New Call")
            .rnsInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Call") { initiateCall() }
                        .disabled(hashInput.filter { $0.isHexDigit }.count != 32)
                }
            }
        }
    }

    private func initiateCall() {
        let hex = String(hashInput.filter { $0.isHexDigit }.prefix(32))
        guard hex.count == 32, let hash = Data(hexString: hex) else {
            inputError = "Must be exactly 32 hex characters (16 bytes)"
            return
        }
        calls.startCall(to: hash)
        dismiss()
    }
}

// MARK: - Helpers

private extension Data {
    init?(hexString: String) {
        let hex = hexString.filter { $0.isHexDigit }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
