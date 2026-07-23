import SwiftUI
import SwiftData

struct MessageThreadView: View {
    let peerHash: String
    @Environment(StackController.self) private var stack
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
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(messages) { msg in
                    MessageBubble(message: msg)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            // iPad / Mac: this renders in a NavigationSplitView detail column
            // ~1000 pt wide, and an unconstrained thread turns every message
            // into one 130-character line. The compose bar below takes the same
            // cap so the bar never spans wider than the content it separates.
            // The outer .infinity frame re-centres the capped column instead of
            // leaving it flush leading.
            .frame(maxWidth: RNSLayout.threadWidth)
            .frame(maxWidth: .infinity)
        }
        // Replaces the entire ScrollViewReader + proxy.scrollTo, which had a
        // trigger for exactly one of the four cases that need one — see
        // `rnsBottomScrollAnchor`. In particular the `onAppear` scrollTo raced
        // the LazyVStack (trailing rows are not materialised on the first
        // layout pass, so the proxy had no target and the thread opened
        // part-way up), and neither the keyboard raising nor the compose field
        // growing to five lines fired anything at all.
        .rnsBottomScrollAnchor()
        // Messages-style: drag the list down and the keyboard follows the
        // finger. With the anchor in place this now stays glued to the newest
        // message throughout the interactive dismissal instead of jumping at
        // the end of it.
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: messages.count) { _, _ in markRead() }
        .onAppear { markRead() }
        // `rnsBottomBar` (safeAreaBar on 26) rather than safeAreaInset: it also
        // extends the scroll view's bottom edge effect into the inset, which is
        // the fade that was missing under the bar — bubbles used to scroll
        // under it, and behind the floating tab bar, with no transition at all.
        .rnsBottomBar { composeBar }
        .rnsCanvasBackground()
        .navigationTitle(peerDisplayName)
        .rnsInlineNavigationTitle()
        .rnsNavigationBar()
        .rnsFeedback(.success, trigger: sentTick)
        .rnsFeedback(.error, trigger: failTick)
    }

    /// The bottom bar: an optional error line, then the compose row.
    ///
    /// Glass stays on the *container*, which is what HIG ▸ Virtual keyboards
    /// asks for: "If other views in your app use Liquid Glass, or if your view
    /// looks out of place above the keyboard, apply Liquid Glass to the view
    /// that contains your controls to maintain consistency." Putting it on the
    /// field and the send button individually instead would also run against
    /// Materials' "use Liquid Glass effects sparingly — overusing this material
    /// in multiple custom controls can provide a subpar user experience."
    ///
    /// `.screenBottom` is the actual reported fix: the bar's bottom corners now
    /// follow the display's radius instead of cutting a 90° rectangle across it
    /// beside the floating capsule tab bar.
    ///
    /// No `Divider()` on iOS/macOS 26 — `rnsBottomBar` extends the scroll edge
    /// effect into the inset and that *is* the separation.
    /// `rnsLegacyBarChrome` puts the hairline back below 26, where there is no
    /// such effect.
    private var composeBar: some View {
        VStack(spacing: 0) {
            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.rnsError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Matches ComposeBar's own horizontal padding below, so the
                    // error lines up with the field it refers to.
                    .padding(.horizontal)
                    .padding(.top, 6)
            }
            ComposeBar(onSend: sendMessage, onDraftChanged: { errorMessage = nil })
        }
        // Same cap as the thread above, so the bar and the content it separates
        // share one edge on iPad and Mac.
        .frame(maxWidth: RNSLayout.threadWidth)
        .frame(maxWidth: .infinity)
        .rnsLegacyBarChrome()
        .rnsBarMaterial(.screenBottom)
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
    /// Called when the user edits the draft. The parent uses it to clear a stale
    /// send error, which otherwise pinned a red caption above the bar for the
    /// life of the view — and, now that the error line sits inside the bottom
    /// bar, permanently inflated the bottom safe area with it.
    let onDraftChanged: () -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool
    /// Set while `submit()` clears the field, so the programmatic reset is not
    /// reported as a user edit.
    ///
    /// Without it, a *failed* send is silent: `sendMessage` assigns
    /// `errorMessage` and returns, then `submit()` assigns `draft = ""` in the
    /// same main-actor turn, whose `.onChange` calls back and clears the error
    /// before it is ever drawn. The red caption this bar was restructured to
    /// host would exist for at most one frame, leaving the `.error` haptic as
    /// the only signal that the send failed at all.
    @State private var isResettingDraft = false

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
                .onChange(of: draft) { _, _ in
                    if isResettingDraft { isResettingDraft = false }
                    else { onDraftChanged() }
                }

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.rnsAccent : Color.secondary)
            }
            // The glyph is only ~22pt; give the button the 44x44pt minimum hit
            // region (contentShape so the whole frame is tappable, not the glyph).
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
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
        isResettingDraft = true
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
            // `Spacer(minLength:)` alone only guarantees a 40 pt gutter — it does
            // not stop the bubble taking the other 950 pt of an iPad detail
            // column. Capping the bubble is what keeps a long message a
            // paragraph instead of one 130-character line, on the platform where
            // this view is widest.
            .frame(maxWidth: RNSLayout.bubbleWidth,
                   alignment: message.isOutbound ? .trailing : .leading)
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
