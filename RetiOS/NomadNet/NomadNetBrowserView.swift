import SwiftUI
import Combine
import NomadNet

// NomadNetBrowserContent is the inner content — no NavigationStack —
// so it can be embedded in NomadNetContainerView without nesting stacks.
struct NomadNetBrowserContent: View {
    @Environment(NomadNetController.self) private var nomadNet
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
            // Body-sized chevrons are only ~17pt — pad the hit region to 44x44pt.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Back")
            .disabled(!nomadNet.canGoBack)
            .keyboardShortcut("[", modifiers: .command)

            Button(action: { nomadNet.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
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
                #if os(iOS)
                // Match the address content and label Return as the load action.
                // (Not folded into rnsHashFieldStyle — that helper forces a body
                // font that would enlarge this deliberately compact caption bar.)
                .keyboardType(.asciiCapable)
                .submitLabel(.go)
                #endif

            // Identify ("log in") toggle — reveals our identity to the current
            // node so it can serve logged-in / gated content, exactly like
            // Python NomadNet's per-node "Identify when connecting". Persisted
            // per-node; toggling reloads the page so it takes effect at once.
            // Only meaningful once a page is loaded (there's a node to log in to).
            if nomadNet.currentURL != nil {
                Button(action: { nomadNet.setIdentify(!nomadNet.identifyToNode) }) {
                    Image(systemName: nomadNet.identifyToNode ? "person.fill.checkmark" : "person")
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .tint(nomadNet.identifyToNode ? Color.rnsAccent : Color.rnsTextSecondary)
                .accessibilityLabel(nomadNet.identifyToNode
                    ? "Identified to this node. Tap to browse anonymously."
                    : "Browsing anonymously. Tap to identify (log in) to this node.")
                .help(nomadNet.identifyToNode
                    ? "Identified — tap to browse anonymously"
                    : "Identify to this node (log in)")
            }

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
        // This is a bar the app draws itself, sitting directly under the system
        // toolbar. A flat fill left it as the one obviously non-glass surface
        // abutting chrome that the OS had already restyled.
        .rnsBarMaterial()
        // `onChange`, not `onReceive(controller.$currentURL)`: @Observable
        // publishes no Combine projection. It also fires only on a real change
        // rather than on every assignment, which is what we want here.
        .onChange(of: nomadNet.currentURL) { _, _ in syncURLBar() }
        // `onChange` alone left the address blank on a page that was plainly
        // loaded. Each branch of the section switcher is its own view identity,
        // so re-entering Browse rebuilds this view with `urlInput` back at "" —
        // and the Peers list's Browse button sets `currentURL` and flips the
        // section in the same update, so the change lands before this view
        // exists and `onChange` never fires for it. Seed from the loaded page.
        .onAppear { syncURLBar() }
    }

    /// Mirror the loaded page's address into the field. Never clobbers text the
    /// user is actively editing — only syncs while the field isn't focused.
    private func syncURLBar() {
        guard !urlBarFocused, let url = nomadNet.currentURL else { return }
        urlInput = url.toString()
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
            // Uses RNSEmptyState (not a bare ContentUnavailableView) so it fills
            // the pane on macOS — otherwise the fixed-size card lets this whole
            // VStack center vertically and drags the URL bar into the middle.
            RNSEmptyState(
                title: "Page Unavailable",
                systemImage: "exclamationmark.triangle",
                description: error,
                actionTitle: "Retry"
            ) { nomadNet.reload() }
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

        // Split the link's data items into form-field references and inline
        // variable assignments. A bare name (`who`) is a form-field reference:
        // send the field's current value as `field_<name>`. A `name=value` item
        // is a URL variable: send as `var_<name>`. Mirrors Python's NomadNet
        // Browser — a submitted form field MUST reach the node as `field_<name>`,
        // not as a URL variable, or the node's request handler never sees it.
        // (Previously every item was flattened into the URL as `name=value`, so
        // form fields were mis-sent as `var_*` and inline variables were dropped.)
        var fieldValues: [String: String] = [:]   // → field_<name>
        var urlVariables: [String: String] = [:]  // → var_<name>
        for item in link.fields {
            if let eq = item.firstIndex(of: "=") {
                let name = String(item[..<eq])
                if !name.isEmpty { urlVariables[name] = String(item[item.index(after: eq)...]) }
            } else if let value = formValues[item], !value.isEmpty {
                fieldValues[item] = value
            }
        }
        let suffix = urlVariables.isEmpty
            ? ""
            : "`" + urlVariables.map { "\($0.key)=\($0.value)" }.joined(separator: "|")

        if target.hasPrefix("/") {
            // Root-relative path: prepend current node hash.
            if let current = nomadNet.currentURL {
                let combined = current.destinationHash.hexString + ":" + target + suffix
                nomadNet.navigate(to: combined, fields: fieldValues)
            }
        } else if target.hasPrefix(":") {
            // Colon-prefixed path (":page/about.mu" or ":/page/about.mu") —
            // relative to current node; strip the leading colon.
            if let current = nomadNet.currentURL {
                let path = String(target.dropFirst())
                let combined = current.destinationHash.hexString + ":" + path + suffix
                nomadNet.navigate(to: combined, fields: fieldValues)
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
                nomadNet.navigate(to: target + suffix, fields: fieldValues)
            } else if let current = nomadNet.currentURL {
                // Relative path — resolve against the directory of the current page.
                // e.g. current path "/page/index.mu" + target "contact" → "/page/contact"
                let currentDir = (current.path as NSString).deletingLastPathComponent
                let base = currentDir.isEmpty ? "" : currentDir
                let resolvedPath = base.hasSuffix("/")
                    ? base + target
                    : base + "/" + target
                let combined = current.destinationHash.hexString + ":" + resolvedPath + suffix
                nomadNet.navigate(to: combined, fields: fieldValues)
            } else {
                // No current page context; pass through and let the parser report the error.
                nomadNet.navigate(to: target + suffix, fields: fieldValues)
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
