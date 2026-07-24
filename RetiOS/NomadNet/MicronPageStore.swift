import Foundation
import Observation

// MARK: - MicronPage

/// One Micron page on disk, identified by its path relative to the store root.
///
/// `relativePath` — not the absolute URL — is the identity, because the root can
/// be relocated underneath us (see `MicronPageStore.setRoot`). A page keyed by
/// absolute URL would silently become a different page after a root change.
struct MicronPage: Identifiable, Hashable, Sendable {
    var id: String { relativePath }
    let relativePath: String   // "index.mu" or "sub/about.mu"
    let url: URL
    let modified: Date
    let byteCount: Int

    /// The node's home page — what a peer gets when they browse without naming
    /// a page. Only the one at the root counts: `sub/index.mu` is an ordinary
    /// page, matching `Node.register_pages`.
    var isIndex: Bool { relativePath == MicronPageStore.indexPageName }
}

// MARK: - Errors

enum MicronPageError: LocalizedError {
    case invalidName(String)
    case pathEscapesRoot(String)
    case alreadyExists(String)
    case notFound(String)
    case notUTF8(String)
    case rootUnavailable(String)
    case bookmarkFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "\"\(name)\" is not a usable page name. Page names cannot be empty, "
                 + "contain \"/\" or \"..\", start with a dot, or end in \".allowed\"."
        case .pathEscapesRoot(let path):
            return "\"\(path)\" resolves to a location outside the page directory and was rejected."
        case .alreadyExists(let name):
            return "A page named \"\(name)\" already exists."
        case .notFound(let name):
            return "The page \"\(name)\" no longer exists on disk."
        case .notUTF8(let name):
            return "\"\(name)\" is not valid UTF-8 text. Micron pages must be UTF-8."
        case .rootUnavailable(let reason):
            return "The page directory is unavailable: \(reason)"
        case .bookmarkFailed(let reason):
            return "Could not remember that folder across launches: \(reason)"
        }
    }
}

// MARK: - MicronPageStore

/// Owns a directory of Micron pages as real files on disk.
///
/// The on-disk layout deliberately mirrors Python NomadNet's `storage/pages`
/// (see `nomadnet/NomadNetworkApp.py` `pagespath` and `nomadnet/Node.py`
/// `scan_pages`) so that serving these pages is a plain directory scan and
/// nothing else:
///
///   - `index.mu` at the root is the home page.
///   - `.mu` is a convention, not a requirement — Python serves every regular
///     file it finds, whatever the extension, so we list them all too.
///   - Files and directories whose name begins with "." are skipped.
///   - A sibling `<page>.allowed` file is an *access list* for that page, not a
///     page. Python excludes it from `servedpages`; listing it here would let a
///     user "edit" an ACL as if it were markup, so it is excluded everywhere.
///
/// Concurrency: `@MainActor` because it publishes `pages` straight into SwiftUI.
/// File I/O here is small (a Micron page is kilobytes) and synchronous on
/// purpose — an async store would need every call site to deal with interleaved
/// edits landing out of order.
@MainActor
@Observable
final class MicronPageStore {

    // MARK: Published state

    /// Every page under `rootURL`, `index.mu` first then case-insensitive
    /// alphabetical. Refreshed by `reload()` and by every mutating call.
    private(set) var pages: [MicronPage] = []

    /// Directory currently being edited. Either `defaultRoot` or a folder the
    /// user picked, restored from a security-scoped bookmark.
    private(set) var rootURL: URL

    /// True when `rootURL` came from a user-chosen bookmark rather than the
    /// app's own storage. Views use this to warn that edits may be live.
    private(set) var isUsingCustomRoot: Bool = false

    /// Last non-fatal problem, for display. Set by the paths that cannot throw
    /// (init, `reload`) and also recorded by the throwing calls so a view that
    /// swallows an error still has something to show.
    private(set) var lastError: String?

    /// Dismiss the current error. Needed because `lastError` is `private(set)`
    /// and a SwiftUI alert has to be able to clear what it presented.
    func clearError() { lastError = nil }

    /// The root, abbreviated for a one-line footer. Shows `~/…` for a path
    /// inside the home directory; the full path is left to `.help()`.
    ///
    /// `NSHomeDirectory()` rather than `FileManager.homeDirectoryForCurrentUser`,
    /// which is macOS-only. On iOS this abbreviates the app container's UUID
    /// path, which is exactly the noise worth hiding.
    var rootDisplayPath: String {
        let path = rootURL.path(percentEncoded: false)
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Constants

    static let bookmarkDefaultsKey = "micronPagesRootBookmark"

    /// Python NomadNet's home page filename (`Node.register_pages`).
    static let indexPageName = "index.mu"

    /// Suffix of a per-page access list. Never a page.
    static let allowedSuffix = ".allowed"

    /// Extension applied to a new page created without one.
    static let pageExtension = "mu"

    /// Depth cap for the recursive scan. Python recurses without a limit and is
    /// safe only because nobody symlinks a node's pages directory into itself;
    /// a user-relocated root is arbitrary, so bound it.
    private static let maxScanDepth = 8

    /// A well-formed page to start from: heading, divider, colour tag with an
    /// explicit reset, and a link. Kept deliberately small — it is a starting
    /// point, not a tutorial.
    ///
    /// Every construct here is asserted lint-clean by
    /// `MicronPageStoreTests.testStarterTemplateIsWellFormedMicron`. The first
    /// draft was not: it used `` `F00b8ff ``, which is the THREE-nibble form
    /// (six digits need `` `FT ``), so it consumed "00b" as the colour and
    /// rendered the leftover "8ff" as text — "This page is 8ffMicron markup".
    /// It also wrote `` `> `` and `` `- `` in the prose to name those
    /// characters, and a backtick before an unrecognised character is deleted
    /// silently, so the sentences came out as "Lines starting with are
    /// headings, a lone draws a divider". The markup characters are therefore
    /// spelled out in words rather than shown.
    static let starterTemplate: String = """
    >New Page
    -

    Welcome. This page is `FT00b8ffMicron`f markup, served straight off disk.

    Everything here is plain text. A line beginning with a greater-than sign is a
    heading, a lone hyphen draws a divider, and a colour tag stays in effect until
    you reset it.

    `[Back to the home page`:/page/index.mu]

    """

    // MARK: Private

    @ObservationIgnored private let defaults: UserDefaults

    /// Where `resetRootToDefault()` goes back to. Normally the app's own
    /// storage; tests inject a temporary directory here.
    @ObservationIgnored private let defaultRoot: URL

    /// Non-nil while we hold a security scope *we* opened. Tracked separately so
    /// we never call `stopAccessingSecurityScopedResource()` on a scope opened
    /// by someone else — the counts are per-process and unbalancing them leaks
    /// or prematurely revokes access.
    @ObservationIgnored private var scopedRoot: URL?

    // MARK: - Init

    convenience init() {
        self.init(rootOverride: nil)
    }

    /// - Parameters:
    ///   - rootOverride: replaces the built-in default root
    ///     (`Documents/nomadnet/pages`). Tests pass a temporary directory so
    ///     they never touch the real Documents container. A persisted bookmark
    ///     still wins over this, which is why tests should also inject
    ///     `defaults`.
    ///   - defaults: where the security-scoped bookmark lives.
    init(rootOverride: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // NomadNetController.setup already creates Documents/nomadnet; we only
        // own the pages/ child, but ask for intermediates anyway so the store is
        // usable before the controller has run.
        self.defaultRoot = rootOverride ?? URL.documentsDirectory
            .appending(path: "nomadnet", directoryHint: .isDirectory)
            .appending(path: "pages", directoryHint: .isDirectory)
        self.rootURL = self.defaultRoot

        restoreBookmarkedRoot()
        reload()
    }

    deinit {
        // Balance the security scope. Reading a stored property of an isolated
        // class from its own deinit is permitted; no isolated method is called.
        scopedRoot?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Root management

    /// Point the store at `url` and remember it across launches.
    ///
    /// Call this with the URL handed over by `.fileImporter`. We open our own
    /// security scope on it before minting the bookmark: on macOS a
    /// `.withSecurityScope` bookmark can only be created while the URL is being
    /// accessed, and callers reliably forget.
    func setRoot(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw record(MicronPageError.rootUnavailable("\(url.path) is not a directory"))
        }

        // Open our scope first, then release the old one — if the two happen to
        // be the same URL, releasing first would revoke access we still need.
        let opened = url.startAccessingSecurityScopedResource()
        let previous = scopedRoot
        scopedRoot = opened ? url : nil

        do {
            let data = try url.bookmarkData(options: Self.bookmarkCreationOptions,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            defaults.set(data, forKey: Self.bookmarkDefaultsKey)
        } catch {
            if opened { url.stopAccessingSecurityScopedResource() }
            scopedRoot = previous
            throw record(MicronPageError.bookmarkFailed(error.localizedDescription))
        }

        // Release the previous scope whenever one was held — including when it
        // is the SAME url. Re-picking the same folder called
        // startAccessingSecurityScopedResource() again, and the old
        // `previous != url` guard then skipped the balancing stop, leaking one
        // access per re-pick for the process lifetime. The newly opened scope
        // keeps access alive either way.
        if let previous, opened || previous != url {
            previous.stopAccessingSecurityScopedResource()
        }

        // Resolve symlinks for the WORKING path while keeping the URL the
        // bookmark granted as the scoped one. `fileExists` follows a symlink so
        // a symlinked folder is accepted here, but
        // `FileManager.contentsOfDirectory(at:)` then fails with ENOTDIR on the
        // link itself — the scan came back empty and every containment check
        // rejected its own children, because `assertInsideRoot` compares
        // symlink-resolved paths on both sides while `rootURL` was unresolved.
        // A node operator symlinking storage from another volume is exactly the
        // case the relocatable root exists for.
        rootURL = url.resolvingSymlinksInPath()
        isUsingCustomRoot = true
        lastError = nil
        reload()
    }

    /// Forget any user-chosen folder and go back to the app's own storage.
    func resetRootToDefault() {
        defaults.removeObject(forKey: Self.bookmarkDefaultsKey)
        scopedRoot?.stopAccessingSecurityScopedResource()
        scopedRoot = nil
        rootURL = defaultRoot
        isUsingCustomRoot = false
        lastError = nil
        reload()
    }

    /// Bookmark options differ per platform and the wrong constant is a compile
    /// error rather than a runtime one, which is the good outcome:
    /// `.withSecurityScope` simply does not exist on iOS. There, a bookmark to a
    /// URL outside our container is security-scoped automatically, and
    /// `.minimalBookmark` keeps the blob small (a full bookmark embeds resource
    /// values we never read).
    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return [.minimalBookmark]
        #endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope, .withoutUI]
        #else
        return [.withoutUI]
        #endif
    }

    /// Re-resolve the persisted bookmark, if any. Any failure here falls back to
    /// the default root and reports why: silently editing the wrong directory —
    /// or worse, editing a stale path that now points somewhere else — is far
    /// more damaging than losing the user's folder choice.
    private func restoreBookmarkedRoot() {
        guard let data = defaults.data(forKey: Self.bookmarkDefaultsKey) else { return }

        var isStale = false
        let resolved: URL
        do {
            resolved = try URL(resolvingBookmarkData: data,
                               options: Self.bookmarkResolutionOptions,
                               relativeTo: nil,
                               bookmarkDataIsStale: &isStale)
        } catch {
            lastError = "Could not reopen the saved page folder (\(error.localizedDescription)). "
                      + "Using the app's own page storage instead."
            return
        }

        guard resolved.startAccessingSecurityScopedResource() else {
            lastError = "Access to the saved page folder was revoked. "
                      + "Using the app's own page storage instead."
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            resolved.stopAccessingSecurityScopedResource()
            lastError = "The saved page folder no longer exists. "
                      + "Using the app's own page storage instead."
            return
        }

        scopedRoot = resolved
        rootURL = resolved.resolvingSymlinksInPath()   // see setRoot
        isUsingCustomRoot = true

        // A stale bookmark still resolved — the folder moved or was renamed.
        // Re-mint it now, while we hold the scope, or it will decay further.
        if isStale, let refreshed = try? resolved.bookmarkData(options: Self.bookmarkCreationOptions,
                                                              includingResourceValuesForKeys: nil,
                                                              relativeTo: nil) {
            defaults.set(refreshed, forKey: Self.bookmarkDefaultsKey)
        }
    }

    // MARK: - Scanning

    /// Rescan `rootURL`. Never throws: a browser that cannot list is still
    /// usable, and the reason lands in `lastError`.
    func reload() {
        ensureRootExists()
        var found: [MicronPage] = []
        scan(directory: rootURL, prefix: "", depth: 0, into: &found)
        pages = found.sorted(by: Self.isOrderedBefore)
    }

    private func ensureRootExists() {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                lastError = MicronPageError.rootUnavailable("\(rootURL.path) is a file, not a folder")
                    .errorDescription
            }
            return
        }
        // Only ever conjure our *own* storage. A user-chosen folder that has
        // vanished (unplugged volume, deleted node directory) must surface as an
        // error, not be silently recreated as an empty directory.
        guard !isUsingCustomRoot else {
            lastError = MicronPageError.rootUnavailable("\(rootURL.path) is missing").errorDescription
            return
        }
        do {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            lastError = MicronPageError.rootUnavailable(error.localizedDescription).errorDescription
        }
    }

    private func scan(directory: URL, prefix: String, depth: Int, into out: inout [MicronPage]) {
        guard depth <= Self.maxScanDepth else { return }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey,
                                      .contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            // `.skipsHiddenFiles` honours the macOS hidden *flag* as well as the
            // dot prefix. Python only looks at the dot, so check it explicitly
            // too and the two implementations agree on every platform.
            if name.hasPrefix(".") { continue }

            let values = try? entry.resourceValues(forKeys: Set(keys))
            let relative = prefix.isEmpty ? name : prefix + "/" + name

            if values?.isDirectory == true {
                scan(directory: entry, prefix: relative, depth: depth + 1, into: &out)
            } else if values?.isRegularFile == true {
                if name.hasSuffix(Self.allowedSuffix) { continue }
                out.append(MicronPage(relativePath: relative,
                                      url: entry,
                                      modified: values?.contentModificationDate ?? .distantPast,
                                      byteCount: values?.fileSize ?? 0))
            }
        }
    }

    /// `index.mu` at the root sorts first — it is the page a visiting node gets
    /// when it asks for nothing in particular. A nested `sub/index.mu` is just
    /// another page and sorts normally.
    private static func isOrderedBefore(_ a: MicronPage, _ b: MicronPage) -> Bool {
        if a.relativePath == indexPageName { return b.relativePath != indexPageName }
        if b.relativePath == indexPageName { return false }
        switch a.relativePath.compare(b.relativePath, options: [.caseInsensitive]) {
        case .orderedAscending:  return true
        case .orderedDescending: return false
        case .orderedSame:       return a.relativePath < b.relativePath
        }
    }

    // MARK: - Reading and writing

    func read(_ page: MicronPage) throws -> String {
        let url = try resolvedURL(for: page)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw record(MicronPageError.notFound(page.relativePath))
        }
        // Python NomadNet decodes pages as UTF-8 and nothing else. Falling back
        // to Latin-1 here would "succeed" on genuinely corrupt input and then
        // write mojibake back out, so refuse instead.
        guard let text = String(data: data, encoding: .utf8) else {
            throw record(MicronPageError.notUTF8(page.relativePath))
        }
        return Self.normalizedLineEndings(text)
    }

    @discardableResult
    func write(_ text: String, to page: MicronPage) throws -> MicronPage {
        let url = try resolvedURL(for: page)
        try writeText(text, to: url)
        reload()
        return try self.page(forRelativePath: page.relativePath, fallback: url)
    }

    // MARK: - Mutations

    @discardableResult
    func create(named name: String, contents: String) throws -> MicronPage {
        let safe = try Self.validatedName(name)
        let url = try childURL(named: safe, in: rootURL)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw record(MicronPageError.alreadyExists(safe))
        }
        try writeText(contents, to: url)
        reload()
        return try page(forRelativePath: url.lastPathComponent, fallback: url)
    }

    /// Rename within the page's own directory — a nested page stays nested.
    /// `newName` is a single path component, never a path.
    @discardableResult
    func rename(_ page: MicronPage, to newName: String) throws -> MicronPage {
        let source = try resolvedURL(for: page)
        let safe = try Self.validatedName(newName)
        let parent = source.deletingLastPathComponent()
        let destination = try childURL(named: safe, in: parent)

        let fm = FileManager.default
        // Case-only rename on a case-insensitive volume (APFS default, and every
        // iOS device): `fileExists` says yes for the destination because it *is*
        // the source. Detect that by canonical path and hop through a temporary
        // name, otherwise a perfectly legal "Index.mu" -> "index.mu" is rejected.
        let sameFile = Self.canonicalPath(source) == Self.canonicalPath(destination)
        if !sameFile, fm.fileExists(atPath: destination.path) {
            throw record(MicronPageError.alreadyExists(safe))
        }
        do {
            if sameFile {
                let staging = parent.appending(path: ".retios-rename-\(UUID().uuidString)",
                                               directoryHint: .notDirectory)
                try fm.moveItem(at: source, to: staging)
                try fm.moveItem(at: staging, to: destination)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
        } catch {
            throw record(MicronPageError.rootUnavailable(error.localizedDescription))
        }

        reload()
        return try self.page(forRelativePath: Self.relativePath(of: destination, under: rootURL) ?? safe,
                             fallback: destination)
    }

    @discardableResult
    func duplicate(_ page: MicronPage) throws -> MicronPage {
        let source = try resolvedURL(for: page)
        let parent = source.deletingLastPathComponent()
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        let destination = try uniqueURL(in: parent, stem: stem + "-copy", extension: ext)

        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw record(MicronPageError.rootUnavailable(error.localizedDescription))
        }
        reload()
        return try self.page(forRelativePath: Self.relativePath(of: destination, under: rootURL)
                                              ?? destination.lastPathComponent,
                             fallback: destination)
    }

    func delete(_ page: MicronPage) throws {
        let url = try resolvedURL(for: page)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw record(MicronPageError.rootUnavailable(error.localizedDescription))
        }
        // A sibling "<page>.allowed" is intentionally left behind. It is the
        // operator's access list, not a derivative of the page, and silently
        // deleting an ACL because a page was removed is a security surprise.
        reload()
    }

    /// Copy a file from outside the root in. `externalURL` is expected to come
    /// from `.fileImporter`, so it may carry its own security scope.
    ///
    /// Import never overwrites: the incoming filename is uniquified. An import
    /// that clobbered a page the user was editing would be unrecoverable.
    @discardableResult
    func importPage(from externalURL: URL) throws -> MicronPage {
        let opened = externalURL.startAccessingSecurityScopedResource()
        defer { if opened { externalURL.stopAccessingSecurityScopedResource() } }

        // lastPathComponent already discards any directory part, but the result
        // still goes through the same validation as a typed name — an imported
        // filename is untrusted input exactly like a text field.
        let safe = try Self.validatedName(externalURL.lastPathComponent)

        guard let data = FileManager.default.contents(atPath: externalURL.path) else {
            throw record(MicronPageError.notFound(externalURL.lastPathComponent))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw record(MicronPageError.notUTF8(safe))
        }

        let candidate = try childURL(named: safe, in: rootURL)
        let destination = try uniqueURL(in: rootURL,
                                    stem: candidate.deletingPathExtension().lastPathComponent,
                                    extension: candidate.pathExtension)
        try writeText(text, to: destination)
        reload()
        return try page(forRelativePath: destination.lastPathComponent, fallback: destination)
    }

    // MARK: - Path safety

    /// Validate a single path component supplied by a human or an imported file.
    ///
    /// Python NomadNet does no sanitisation at all; it is safe only because it
    /// registers a request handler per exact discovered path and never composes
    /// a path from input. We do compose paths, so anything that could climb out
    /// of the root — or masquerade as an access list — is refused here, before
    /// it ever reaches the filesystem.
    static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MicronPageError.invalidName(raw) }
        guard !name.contains("/"), !name.contains("\\") else {
            throw MicronPageError.invalidName(raw)
        }
        guard !name.contains("..") else { throw MicronPageError.invalidName(raw) }
        guard !name.hasPrefix(".") else { throw MicronPageError.invalidName(raw) }
        guard !name.hasSuffix(allowedSuffix) else { throw MicronPageError.invalidName(raw) }
        // A NUL truncates the path at the POSIX layer; other control characters
        // make filenames that cannot be typed back in.
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw MicronPageError.invalidName(raw)
        }
        return name
    }

    /// Compose `directory/name`, defaulting a bare name to `.mu`, and prove the
    /// result is still inside the root before handing it back.
    private func childURL(named name: String, in directory: URL) throws -> URL {
        var url = directory.appending(path: name, directoryHint: .notDirectory)
        if url.pathExtension.isEmpty {
            url = url.appendingPathExtension(Self.pageExtension)
        }
        try assertInsideRoot(url)
        return url
    }

    /// Recompute a page's URL from its `relativePath` against the *current*
    /// root, rather than trusting the URL captured when it was scanned. Cheap
    /// insurance against a stale `MicronPage` held by a view across a root
    /// change, and the only place a multi-component relative path is accepted.
    private func resolvedURL(for page: MicronPage) throws -> URL {
        let components = page.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { throw record(MicronPageError.invalidName(page.relativePath)) }
        for component in components {
            guard !component.isEmpty, component != "..", !component.hasPrefix(".") else {
                throw record(MicronPageError.pathEscapesRoot(page.relativePath))
            }
        }
        var url = rootURL
        for component in components {
            url = url.appending(path: String(component), directoryHint: .notDirectory)
        }
        do {
            try assertInsideRoot(url)
        } catch {
            throw record(error)
        }
        return url
    }

    private func assertInsideRoot(_ url: URL) throws {
        let root = Self.canonicalPath(rootURL)
        let target = Self.canonicalPath(url)
        // Trailing separator matters: "/pages" must not appear to contain
        // "/pages-backup/secret.mu".
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(prefix) else {
            throw MicronPageError.pathEscapesRoot(url.path)
        }
    }

    /// Resolve symlinks and collapse "." / ".." so containment is decided on the
    /// real path. Applied to both sides, so /var vs /private/var (and any other
    /// symlinked prefix) cannot produce a false mismatch.
    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = canonicalPath(root)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let target = canonicalPath(url)
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    // MARK: - Helpers

    /// Micron is line-oriented: every directive is matched at column 0 and a
    /// trailing CR from a desktop-authored page becomes part of the last token
    /// on the line, so `"-\r"` stops being a divider and `` `= `` with a trailing
    /// CR stops closing a literal block. Normalise on the way in *and* out so a
    /// round-trip through the editor cannot reintroduce it.
    ///
    /// This walks unicode scalars rather than using `String.contains` /
    /// `replacingOccurrences`, because CR-LF is a *single Swift grapheme
    /// cluster*: `"one\r\ntwo".contains("\r")` is `false`, and grapheme-based
    /// replacement of `"\r"` skips right over it. The obvious two-line
    /// implementation silently does nothing on exactly the input it exists for.
    static func normalizedLineEndings(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }

        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r":
                out.append("\n")
                previousWasCR = true
            case "\n":
                // The LF half of a CR-LF pair was already emitted as the "\n".
                if !previousWasCR { out.append("\n") }
                previousWasCR = false
            default:
                out.append(scalar)
                previousWasCR = false
            }
        }
        return String(out)
    }

    private func writeText(_ text: String, to url: URL) throws {
        let data = Data(Self.normalizedLineEndings(text).utf8)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw record(MicronPageError.rootUnavailable(error.localizedDescription))
        }
    }

    /// First free name in `directory`, trying `stem.ext`, then `stem-2.ext`, …
    ///
    /// Throws rather than returning a colliding URL when the search is
    /// exhausted. It used to `break` with the last candidate it had tested —
    /// one that exists — and the caller then wrote to it with `.atomic`, which
    /// silently replaces. A uniquifier whose failure mode is overwriting the
    /// file it was asked to avoid is worse than no uniquifier.
    private func uniqueURL(in directory: URL, stem: String, extension ext: String) throws -> URL {
        let fm = FileManager.default
        func candidate(_ suffix: String) -> URL {
            let name = stem + suffix
            let base = directory.appending(path: name, directoryHint: .notDirectory)
            return ext.isEmpty ? base : base.appendingPathExtension(ext)
        }
        var url = candidate("")
        var counter = 2
        while fm.fileExists(atPath: url.path) {
            guard counter <= Self.uniquifierLimit else {
                throw record(MicronPageError.alreadyExists(stem))
            }
            url = candidate("-\(counter)")
            counter += 1
        }
        return url
    }

    static let uniquifierLimit = 1000

    private func page(forRelativePath relativePath: String, fallback url: URL) throws -> MicronPage {
        if let found = pages.first(where: { $0.relativePath == relativePath }) { return found }
        return try stat(url, relativePath: relativePath)
    }

    private func stat(_ url: URL, relativePath: String) throws -> MicronPage {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw record(MicronPageError.notFound(relativePath))
        }
        return MicronPage(relativePath: relativePath,
                          url: url,
                          modified: values?.contentModificationDate ?? Date(),
                          byteCount: values?.fileSize ?? 0)
    }

    /// Record a thrown error in `lastError` and hand it straight back, so
    /// `throw record(…)` reads as one statement at the call site.
    @discardableResult
    private func record(_ error: Error) -> Error {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return error
    }
}
