import SwiftUI
import ReticulumSwift

struct IdentityView: View {
    @EnvironmentObject var stack: StackController
    @State private var copied = false
    @State private var draftName: String = ""
    // Memoized QR of the identity hash. Generating it via Core Image is costly,
    // and the hash is stable, so build it once on appear / when the identity
    // changes instead of on every `body` eval (each keystroke in the name /
    // nickname fields otherwise regenerated it, causing typing lag).
    @State private var qrImage: Image?
    // RRC chat nickname — read live by RRCManager.getNickname() via the
    // NomadNetAppAdapter, so saving here takes effect on the next message.
    @AppStorage("rrcNickname") private var rrcNickname: String = ""
    @FocusState private var nameFocused: Bool

    private var nameIsDirty: Bool {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines) != stack.nodeDisplayName
    }

    var body: some View {
        Form {
            displayNameSection
            chatNicknameSection
            thisNodeSection
        }
        .rnsScreenBackground()
        .navigationTitle("Identity")
        .rnsInlineNavigationTitle()
        .onAppear {
            draftName = stack.nodeDisplayName
            // Parenthesize so `flatMap` is Optional.flatMap (String? -> Image?),
            // not String's Sequence.flatMap over Characters.
            qrImage = (stack.identity?.hexHash).flatMap { rnsQRImage($0) }
        }
        .onChange(of: stack.identity?.hexHash) { _, hex in
            qrImage = hex.flatMap { rnsQRImage($0) }
        }
        .rnsFeedback(trigger: copied) { _, new in new ? .success : nil }
    }

    // MARK: - Sections

    private var displayNameSection: some View {
        Section {
            TextField("Your name (shown to peers)", text: $draftName)
                .focused($nameFocused)
                .autocorrectionDisabled()
                .onSubmit { commitName() }
                // `.keyboard` placement is iOS-only (it targets the software
                // keyboard's accessory bar); on macOS it would misfile into the
                // Touch Bar. Guard so the Mac build stays clean.
                #if os(iOS)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { commitName() }
                            .bold()
                    }
                }
                #endif

            if nameIsDirty {
                Button(action: commitName) {
                    Label("Save Name", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.rnsAccent)
                .controlSize(.regular)
            }
        } header: {
            Text("Display name")
        } footer: {
            Text("This name is included in your LXMF announces. Peers see it instead of your raw hash. Leave blank to announce anonymously.")
        }
        .rnsRow()
    }

    private var chatNicknameSection: some View {
        Section {
            TextField("Nickname in RRC channels", text: $rrcNickname)
                .autocorrectionDisabled()
                .rnsNoAutocapitalization()
        } header: {
            Text("Chat nickname")
        } footer: {
            Text("Shown next to your messages in NomadNet channels (RRC). Leave blank to appear by hash.")
        }
        .rnsRow()
    }

    private var thisNodeSection: some View {
        Section {
            LabeledContent("Stack") {
                Text(stack.isRunning ? "Running" : "Idle")
            }

            if let hexHash = stack.identity?.hexHash {
                hashRow(hexHash)
                if let qr = qrImage {
                    qrRow(qr)
                }
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        } header: {
            Text("This node")
        } footer: {
            Text("Your identity hash is your network address. Share it with others so they can message you or establish a link.")
        }
        .rnsRow()
    }

    private func hashRow(_ hexHash: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Destination hash")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(hexHash)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button(action: { copyHash(hexHash) }) {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(copied ? Color.rnsSuccess : Color.rnsAccent)
            }
        }
        .padding(.vertical, 4)
    }

    private func qrRow(_ qr: Image) -> some View {
        HStack {
            Spacer()
            qr
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .padding(8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Spacer()
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    private func commitName() {
        stack.setNodeDisplayName(draftName)
        nameFocused = false
    }

    private func copyHash(_ hex: String) {
        rnsCopyToPasteboard(hex)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }
}
