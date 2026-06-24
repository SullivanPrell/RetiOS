import SwiftUI
import ReticulumSwift
#if canImport(CoreImage)
import CoreImage.CIFilterBuiltins
#endif

// Cross-platform image type alias + SwiftUI Image initializer.
#if os(macOS)
private typealias PlatformImage = NSImage
private extension NSImage {
    convenience init(cgImage: CGImage) { self.init(cgImage: cgImage, size: .zero) }
}
private extension Image {
    init(platformImage img: PlatformImage) { self.init(nsImage: img) }
}
#else
private typealias PlatformImage = UIImage
private extension Image {
    init(platformImage img: PlatformImage) { self.init(uiImage: img) }
}
#endif

struct IdentityView: View {
    @EnvironmentObject var stack: StackController
    @State private var copied = false
    @State private var draftName: String = ""
    // RRC chat nickname — read live by RRCManager.getNickname() via the
    // NomadNetAppAdapter, so saving here takes effect on the next message.
    @AppStorage("rrcNickname") private var rrcNickname: String = ""
    @FocusState private var nameFocused: Bool

    private var nameIsDirty: Bool {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines) != stack.nodeDisplayName
    }

    var body: some View {
        Form {
            Section("Display name") {
                TextField("Your name (shown to peers)", text: $draftName)
                    .focused($nameFocused)
                    .autocorrectionDisabled()
                    .onSubmit { commitName() }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { commitName() }
                                .bold()
                        }
                    }

                if nameIsDirty {
                    Button(action: commitName) {
                        Label("Save Name", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.rnsAccent)
                    .controlSize(.regular)
                }

                Text("This name is included in your LXMF announces. Peers see it instead of your raw hash. Leave blank to announce anonymously.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .rnsRow()

            Section("Chat nickname") {
                TextField("Nickname in RRC channels", text: $rrcNickname)
                    .autocorrectionDisabled()
                    .rnsNoAutocapitalization()

                Text("Shown next to your messages in NomadNet channels (RRC). Leave blank to appear by hash.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .rnsRow()

            Section("This node") {
                    LabeledContent("Stack") {
                        Text(stack.isRunning ? "Running" : "Idle")
                    }

                    if let hexHash = stack.identity?.hexHash {
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
                                .tint(copied ? .green : .rnsAccent)
                            }
                        }
                        .padding(.vertical, 4)

                        if let qr = makeQR(hexHash) {
                            HStack {
                                Spacer()
                                Image(platformImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 180, height: 180)
                                    .padding(8)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                        }
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                .rnsRow()

                Section {
                    Text("Your identity hash is your network address. Share it with others so they can message you or establish a link.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .rnsRow()
            }
            .rnsScreenBackground()
            .navigationTitle("Identity")
            .rnsInlineNavigationTitle()
            .onAppear { draftName = stack.nodeDisplayName }
            .rnsFeedback(trigger: copied) { _, new in new ? .success : nil }
    }

    private func commitName() {
        stack.setNodeDisplayName(draftName)
        nameFocused = false
    }

    private func copyHash(_ hex: String) {
        #if os(iOS)
        UIPasteboard.general.string = hex
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        #endif
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }

    private func makeQR(_ string: String) -> PlatformImage? {
        #if canImport(CoreImage)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return PlatformImage(cgImage: cgImage)
        #else
        return nil
        #endif
    }
}
