import SwiftUI
import LXMF

/// Settings screen for configuring the LXMF outbound propagation node.
///
/// A propagation node stores-and-forwards messages for offline recipients,
/// acting as a mesh post-box. Enter the 32-character destination hash of
/// any publicly reachable LXMF propagation node.
struct PropagationNodeView: View {
    @EnvironmentObject var stack: StackController
    @State private var hashInput = ""
    @State private var saved = false
    @State private var validationError: String?
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            inputSection
            if stack.propagationNodeHash != nil {
                syncSection
            }
            if let current = stack.propagationNodeHash {
                currentSection(hash: current)
            }
        }
        .rnsScreenBackground()
        .navigationTitle("Propagation Node")
        .rnsInlineNavigationTitle()
        .confirmationDialog(
            "Clear Propagation Node",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                stack.setPropagationNode(nil)
                hashInput = ""
                saved = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Messages will no longer be stored and forwarded for you while you're offline.")
        }
        .onAppear {
            hashInput = stack.propagationNodeHash ?? ""
        }
    }

    // MARK: - Sections

    private var inputSection: some View {
        Section {
            TextField("32-character hex hash", text: $hashInput)
                .rnsHashFieldStyle()
                .onChange(of: hashInput) { _, new in
                    hashInput = String(new.filter { $0.isHexDigit }.prefix(32))
                    saved = false
                    validationError = nil
                }

            if let err = validationError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.rnsError)
            }

            HStack(spacing: 16) {
                Button(action: save) {
                    Label(saved ? "Saved" : "Save",
                          systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                .disabled(hashInput.count != 32 || !stack.isRunning)
                .tint(saved ? Color.rnsSuccess : .rnsAccent)

                if stack.propagationNodeHash != nil {
                    Spacer()
                    Button("Clear", role: .destructive) {
                        showClearConfirm = true
                    }
                }
            }
        } header: {
            Text("Destination Hash")
        } footer: {
            Text("An LXMF propagation node stores and forwards messages on behalf of offline recipients. Enter the 32-character destination hash of any publicly reachable propagation server to enable store-and-forward delivery.")
        }
        .rnsRow()
    }

    // MARK: - Sync

    private var syncIsRunning: Bool {
        switch stack.propagationSyncState {
        case .idle, .done, .failed: return false
        default:                    return true
        }
    }

    private var syncStatusText: String {
        switch stack.propagationSyncState {
        case .idle:             return "Not synced this session"
        case .pathRequested:    return "Requesting path to node…"
        case .linkEstablishing: return "Connecting to node…"
        case .linkEstablished:  return "Connected — requesting messages…"
        case .requestSent:      return "Waiting for message list…"
        case .receiving:        return "Downloading messages…"
        case .done:             return "Sync complete"
        case .failed:           return "Sync failed — check that the node is reachable"
        }
    }

    private var syncSection: some View {
        Section {
            HStack {
                Button {
                    stack.syncFromPropagationNode()
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!stack.isRunning || syncIsRunning)
                .tint(.rnsAccent)

                if syncIsRunning {
                    Spacer()
                    Button("Cancel", role: .destructive) {
                        stack.cancelPropagationSync()
                    }
                }
            }

            HStack(spacing: 8) {
                if syncIsRunning { ProgressView().controlSize(.small) }
                Text(syncStatusText)
                    .font(.caption)
                    .foregroundStyle(stack.propagationSyncState == .failed
                                     ? Color.rnsError : Color.secondary)
            }
            if case .receiving = stack.propagationSyncState {
                ProgressView(value: stack.propagationSyncProgress)
            }
        } header: {
            Text("Messages")
        } footer: {
            Text("Retrieves messages other nodes left for you while you were offline.")
        }
        .rnsRow()
    }

    private func currentSection(hash: String) -> some View {
        Section("Active") {
            LabeledContent("Node hash") {
                Text(hash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .rnsRow()
    }

    // MARK: - Actions

    private func save() {
        let clean = hashInput.filter { $0.isHexDigit }
        guard clean.count == 32 else {
            validationError = "Must be exactly 32 hex characters (16 bytes)."
            return
        }
        stack.setPropagationNode(clean)
        withAnimation { saved = true }
    }
}
