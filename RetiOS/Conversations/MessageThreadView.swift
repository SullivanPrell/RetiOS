import SwiftUI
import SwiftData

struct MessageThreadView: View {
    let peerHash: String
    @EnvironmentObject var stack: StackController
    @Environment(\.modelContext) private var context
    @Query private var messages: [MessageEntity]
    @Query private var peers: [PeerEntity]
    // errorMessage is the only @State here — only changes on send, not on every keystroke.
    // `draft` has been moved into ComposeBar so that typing only invalidates ComposeBar.body,
    // not the full message list above.
    @State private var errorMessage: String?
    // Bumped on a successful send / failed send to drive haptic feedback.
    @State private var sentTick = 0
    @State private var failTick = 0

    init(peerHash: String) {
        self.peerHash = peerHash
        _messages = Query(
            filter: #Predicate<MessageEntity> { $0.conversationHash == peerHash },
            sort: \MessageEntity.timestamp
        )
        _peers = Query(filter: #Predicate<PeerEntity> { $0.destinationHash == peerHash })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            // Scroll to the last message whenever the list grows.
            // No withAnimation — avoids jank when keyboard and new messages arrive together.
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                markRead()
            }
            // Scroll to bottom on first appearance.
            .onAppear {
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                markRead()
            }
        }
        // safeAreaInset keeps the compose bar anchored at the bottom without
        // resizing the scroll view. SwiftUI's keyboard avoidance then works
        // on the safe area rather than the VStack — much smoother on iOS.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.rnsError)
                        .padding(.horizontal)
                        .padding(.top, 6)
                }
                Divider()
                ComposeBar(onSend: sendMessage)
            }
            .background(Color.rnsSurface)
        }
        .scrollDismissesKeyboard(.interactively)
        .rnsCanvasBackground()
        .navigationTitle(peerDisplayName)
        .rnsInlineNavigationTitle()
        .rnsNavigationBar()
        .rnsFeedback(.success, trigger: sentTick)
        .rnsFeedback(.error, trigger: failTick)
    }

    private var peerDisplayName: String {
        peers.first?.label ?? "<\(String(peerHash.prefix(8)))>"
    }

    /// Clear the unread flag on everything in this thread — called when the
    /// thread is opened and whenever new messages arrive while it's visible.
    private func markRead() {
        var dirty = false
        for msg in messages where !msg.isRead {
            msg.isRead = true
            dirty = true
        }
        if dirty { try? context.save() }
    }

    // `text` is trimmed and non-empty — ComposeBar guarantees this before calling.
    private func sendMessage(_ text: String) {
        guard let peerData = Data(hexString: peerHash) else { return }
        do {
            try stack.send(content: text, to: peerData, context: context)
            errorMessage = nil
            sentTick += 1
        } catch {
            errorMessage = error.localizedDescription
            failTick += 1
        }
    }
}

// MARK: - Compose bar
//
// Owns `draft` as private @State so keystrokes only re-evaluate ComposeBar.body —
// not the ScrollView + message list in the parent. The parent receives text only
// when the user actually taps Send (or submits via keyboard).

private struct ComposeBar: View {
    /// Called with trimmed, non-empty text when the user sends.
    let onSend: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // NOTE: no `.onSubmit` here. This is a multiline (`axis: .vertical`)
            // field, so Return inserts a newline and `.onSubmit` never fires on
            // iOS — attaching it only misleads. Sending is via the button (and,
            // on macOS, the ⌘Return keyboard shortcut on that button).
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($isFocused)

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.rnsAccent : Color.secondary)
            }
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend(text)
        draft = ""
    }
}

// MARK: - Delivery icon

private func deliveryIcon(state: Int16) -> some View {
    Group {
        switch state {
        case 0x08: // delivered
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.rnsSuccess)
                .accessibilityLabel("Delivered")
        case 0x04: // sent
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sent")
        case 0xFF: // failed
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Color.rnsError)
                .accessibilityLabel("Failed to send")
        default:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sending")
        }
    }
    .font(.caption2)
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: MessageEntity

    /// Lazily decode LXMF attachments from the stored packed bytes.
    private var attachments: MessageAttachments? {
        guard message.hasAttachments, let packed = message.packedMessage else { return nil }
        return MessageAttachments.decode(from: packed)
    }

    var body: some View {
        let att = attachments
        let hasText = !message.content.isEmpty
        return HStack {
            if message.isOutbound { Spacer(minLength: 40) }
            VStack(alignment: message.isOutbound ? .trailing : .leading, spacing: 4) {
                if !message.title.isEmpty {
                    Text(message.title)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }

                if let att {
                    AttachmentsView(attachments: att, outbound: message.isOutbound)
                }

                // Show the text bubble when there's text, or as an "(empty)"
                // placeholder only when the message carries neither text nor
                // any attachment we could render.
                if hasText || att == nil {
                    Text(hasText ? message.content : "(empty)")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        // Received bubble uses the secondary grouped surface (white in
                        // Light, dark-gray in Dark) so it always contrasts with the
                        // grouped page — tertiary would match the page exactly in Light.
                        .background(message.isOutbound ? Color.rnsAccent : Color.rnsSurface)
                        .foregroundStyle(message.isOutbound ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if message.isOutbound {
                        deliveryIcon(state: message.deliveryState)
                    }
                }
            }
            if !message.isOutbound { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Attachments

/// Renders the image / file / audio / telemetry attachments carried by an LXMF
/// message. Display-only for now — playback of audio and saving of files are
/// follow-on work; this surfaces what the C1 fix recovered on the wire.
private struct AttachmentsView: View {
    let attachments: MessageAttachments
    let outbound: Bool

    var body: some View {
        VStack(alignment: outbound ? .trailing : .leading, spacing: 6) {
            if let image = attachments.image, let rendered = platformImage(image.data) {
                rendered
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if let image = attachments.image {
                // Bytes present but not decodable as an image on this platform.
                chip(icon: "photo", title: "Image", detail: "\(image.type) · \(byteLabel(image.data.count))")
            }

            ForEach(Array(attachments.files.enumerated()), id: \.offset) { _, file in
                chip(icon: "doc", title: file.name, detail: byteLabel(file.data.count))
            }

            if let audio = attachments.audio {
                chip(icon: "waveform", title: "Audio message",
                     detail: "mode \(audio.mode) · \(byteLabel(audio.data.count))")
            }

            if let telemetry = attachments.telemetryBytes {
                chip(icon: "chart.bar.doc.horizontal", title: "Telemetry",
                     detail: byteLabel(telemetry))
            }
        }
    }

    private func chip(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.rnsAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.rnsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func byteLabel(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Cross-platform image decode

#if canImport(UIKit)
import UIKit
private func platformImage(_ data: Data) -> Image? {
    UIImage(data: data).map { Image(uiImage: $0) }
}
#elseif canImport(AppKit)
import AppKit
private func platformImage(_ data: Data) -> Image? {
    NSImage(data: data).map { Image(nsImage: $0) }
}
#else
private func platformImage(_ data: Data) -> Image? { nil }
#endif

// MARK: - Hex convenience

private extension Data {
    init?(hexString: String) {
        let hex = hexString.filter { $0.isHexDigit }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        self = data
    }
}
