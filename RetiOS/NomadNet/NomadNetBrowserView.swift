import SwiftUI
import Combine
import NomadNet

// NomadNetBrowserContent is the inner content — no NavigationStack —
// so it can be embedded in NomadNetContainerView without nesting stacks.
struct NomadNetBrowserContent: View {
    @EnvironmentObject var nomadNet: NomadNetController
    @State private var urlInput = ""
    @FocusState private var urlBarFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            urlBar
            Divider()
            pageContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rnsCanvasBackground()
    }

    // MARK: - URL bar

    private var urlBar: some View {
        HStack(spacing: 8) {
            Button(action: { nomadNet.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Back")
            .disabled(!nomadNet.canGoBack)
            .keyboardShortcut("[", modifiers: .command)

            Button(action: { nomadNet.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Forward")
            .disabled(!nomadNet.canGoForward)
            .keyboardShortcut("]", modifiers: .command)

            TextField("hash:path  e.g. abc123…:/page/index.mu", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .rnsNoAutocapitalization()
                .font(.caption.monospaced())
                .focused($urlBarFocused)
                .onSubmit { navigate() }

            if nomadNet.isLoading {
                ProgressView()
                    .scaleEffect(0.75)
            } else {
                Button(action: {
                    if urlInput.isEmpty { nomadNet.reload() } else { navigate() }
                }) {
                    Image(systemName: urlInput.isEmpty ? "arrow.clockwise" : "arrow.right.circle.fill")
                }
                .accessibilityLabel(urlInput.isEmpty ? "Reload" : "Navigate")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.rnsSurface)
        .onReceive(nomadNet.$currentURL.compactMap { $0 }) { url in
            // Don't clobber text the user is actively editing in the URL bar;
            // only sync the field to the loaded page when it isn't focused.
            guard !urlBarFocused else { return }
            urlInput = url.toString()
        }
    }

    // MARK: - Page content

    @ViewBuilder
    private var pageContent: some View {
        let hasPage = !nomadNet.currentNodes.isEmpty

        if hasPage || nomadNet.isLoading {
            // Keep the page visible; any error from a link tap appears as a banner.
            ScrollView {
                if let error = nomadNet.errorMessage, hasPage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.rnsWarning)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                MicronView(nodes: nomadNet.currentNodes) { link, formValues in
                    handleLink(link, formValues: formValues)
                }
                .id(nomadNet.currentURL?.toString() ?? "")
                .padding()
            }
        } else if let error = nomadNet.errorMessage {
            // Full-screen error only on initial load failure (no page to show).
            ContentUnavailableView {
                Label("Page Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { nomadNet.reload() }
                    .buttonStyle(.bordered)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        RNSEmptyState(
            title: "No Page Loaded",
            systemImage: "network",
            description: "Enter a NomadNet node hash to browse Micron pages over the mesh."
        )
    }

    // MARK: - Navigation

    private func navigate() {
        urlBarFocused = false
        let trimmed = urlInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        nomadNet.navigate(to: trimmed)
    }

    private func handleLink(_ link: MicronLink, formValues: [String: String] = [:]) {
        let target = link.url
        guard !target.isEmpty else { return }

        // Skip in-page anchors and RRC links — not page navigation.
        if target.hasPrefix("#") || target.hasPrefix("rrc://") { return }

        let fieldPairs: [String] = link.fields.compactMap { name in
            guard let value = formValues[name], !value.isEmpty else { return nil }
            return "\(name)=\(value)"
        }
        let suffix = fieldPairs.isEmpty ? "" : "`" + fieldPairs.joined(separator: "|")

        if target.hasPrefix("/") {
            // Root-relative path: prepend current node hash.
            if let current = nomadNet.currentURL {
                let combined = current.destinationHash.hexString + ":" + target + suffix
                nomadNet.navigate(to: combined)
            }
        } else if target.hasPrefix(":") {
            // Colon-prefixed path (":page/about.mu" or ":/page/about.mu") —
            // relative to current node; strip the leading colon.
            if let current = nomadNet.currentURL {
                let path = String(target.dropFirst())
                let combined = current.destinationHash.hexString + ":" + path + suffix
                nomadNet.navigate(to: combined)
            }
        } else {
            // Determine whether this is an absolute NomadNet URL:
            // must start with exactly 32 hex chars, optionally followed by ":".
            let hexLen = NomadNetURL.hashHexLength
            let looksAbsolute = target.count >= hexLen
                && String(target.prefix(hexLen)).allSatisfy(\.isHexDigit)
                && (target.count == hexLen
                    || String(target.dropFirst(hexLen)).hasPrefix(":"))

            if looksAbsolute {
                nomadNet.navigate(to: target + suffix)
            } else if let current = nomadNet.currentURL {
                // Relative path — resolve against the directory of the current page.
                // e.g. current path "/page/index.mu" + target "contact" → "/page/contact"
                let currentDir = (current.path as NSString).deletingLastPathComponent
                let base = currentDir.isEmpty ? "" : currentDir
                let resolvedPath = base.hasSuffix("/")
                    ? base + target
                    : base + "/" + target
                let combined = current.destinationHash.hexString + ":" + resolvedPath + suffix
                nomadNet.navigate(to: combined)
            } else {
                // No current page context; pass through and let the parser report the error.
                nomadNet.navigate(to: target + suffix)
            }
        }
    }
}

// Standalone view (used by iPad sidebar detail pane).
struct NomadNetBrowserView: View {
    var body: some View {
        NavigationStack {
            NomadNetBrowserContent()
                .navigationTitle("NomadNet")
                .rnsInlineNavigationTitle()
                .rnsNavigationBar()
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
