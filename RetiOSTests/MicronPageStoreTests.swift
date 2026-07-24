import XCTest
@testable import RetiOS

/// Every test runs against a fresh temporary directory and a throwaway
/// UserDefaults suite. Nothing here may touch the real Documents container —
/// that is where the Reticulum identity private key lives.
@MainActor
final class MicronPageStoreTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTempRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "MicronPageStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeDefaults() -> UserDefaults {
        let name = "MicronPageStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeStore() throws -> (MicronPageStore, URL) {
        let root = try makeTempRoot()
        return (MicronPageStore(rootOverride: root, defaults: makeDefaults()), root)
    }

    @discardableResult
    private func writeRaw(_ contents: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Root setup

    func testInitCreatesDefaultRootAndStartsEmpty() throws {
        let root = try makeTempRoot()
        let nested = root.appending(path: "nomadnet/pages", directoryHint: .isDirectory)
        let store = MicronPageStore(rootOverride: nested, defaults: makeDefaults())

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path),
                      "init must create the pages/ directory, including intermediates")
        XCTAssertEqual(store.rootURL, nested)
        XCTAssertFalse(store.isUsingCustomRoot)
        XCTAssertTrue(store.pages.isEmpty)
        XCTAssertNil(store.lastError)
    }

    // MARK: - Create / read / write

    func testCreateThenReadRoundTrip() throws {
        let (store, _) = try makeStore()
        let page = try store.create(named: "about.mu", contents: "hello\nworld\n")

        XCTAssertEqual(page.relativePath, "about.mu")
        XCTAssertEqual(try store.read(page), "hello\nworld\n")
        XCTAssertEqual(store.pages.map(\.relativePath), ["about.mu"])
        XCTAssertEqual(page.byteCount, 12)
    }

    func testCreateWithoutExtensionGetsMuExtension() throws {
        let (store, _) = try makeStore()
        let page = try store.create(named: "notes", contents: "x")
        XCTAssertEqual(page.relativePath, "notes.mu")
    }

    func testCreateKeepsANonMuExtension() throws {
        // .mu is convention, not enforcement — Python serves whatever it finds.
        let (store, _) = try makeStore()
        let page = try store.create(named: "readme.txt", contents: "x")
        XCTAssertEqual(page.relativePath, "readme.txt")
        XCTAssertEqual(store.pages.count, 1)
    }

    func testCreateCollisionThrowsAlreadyExists() throws {
        let (store, _) = try makeStore()
        try store.create(named: "index.mu", contents: "a")
        XCTAssertThrowsError(try store.create(named: "index.mu", contents: "b")) { error in
            guard case MicronPageError.alreadyExists(let name) = error else {
                return XCTFail("expected .alreadyExists, got \(error)")
            }
            XCTAssertEqual(name, "index.mu")
        }
        XCTAssertEqual(try store.read(store.pages[0]), "a", "the original must not be clobbered")
    }

    func testWriteReplacesContentsAndRefreshesMetadata() throws {
        let (store, _) = try makeStore()
        let page = try store.create(named: "a.mu", contents: "short")
        let updated = try store.write("a considerably longer body\n", to: page)

        XCTAssertEqual(try store.read(updated), "a considerably longer body\n")
        XCTAssertEqual(updated.byteCount, 27)
        XCTAssertEqual(store.pages.count, 1)
    }

    func testReadOfDeletedFileThrowsNotFound() throws {
        let (store, _) = try makeStore()
        let page = try store.create(named: "gone.mu", contents: "x")
        try FileManager.default.removeItem(at: page.url)

        XCTAssertThrowsError(try store.read(page)) { error in
            guard case MicronPageError.notFound = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
        }
        XCTAssertNotNil(store.lastError, "a thrown error must also land in lastError")
    }

    func testReadOfNonUTF8ThrowsNotUTF8() throws {
        let (store, root) = try makeStore()
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: root.appending(path: "bad.mu"))
        store.reload()

        XCTAssertThrowsError(try store.read(store.pages[0])) { error in
            guard case MicronPageError.notUTF8 = error else {
                return XCTFail("expected .notUTF8, got \(error)")
            }
        }
    }

    // MARK: - CRLF normalisation

    func testReadNormalisesCRLFToLF() throws {
        let (store, root) = try makeStore()
        try writeRaw(">Heading\r\n-\r\nbody\r\n", to: root.appending(path: "crlf.mu"))
        store.reload()

        XCTAssertEqual(try store.read(store.pages[0]), ">Heading\n-\nbody\n")
    }

    func testReadNormalisesLoneCRToLF() throws {
        let (store, root) = try makeStore()
        try writeRaw(">Heading\r-\rbody", to: root.appending(path: "cr.mu"))
        store.reload()

        XCTAssertEqual(try store.read(store.pages[0]), ">Heading\n-\nbody")
    }

    func testWriteNormalisesCRLFOnDisk() throws {
        let (store, _) = try makeStore()
        let page = try store.create(named: "w.mu", contents: "one\r\ntwo\r\n")
        let onDisk = try Data(contentsOf: page.url)

        XCTAssertFalse(onDisk.contains(0x0D), "no CR may survive a write")
        XCTAssertEqual(String(data: onDisk, encoding: .utf8), "one\ntwo\n")
    }

    func testNormalisationHandlesMixedAndAdjacentLineEndings() {
        // Regression guard for the CR-LF grapheme-cluster trap: a Swift Character
        // "\r\n" is one element, so any Character-level scan misses it.
        XCTAssertEqual(MicronPageStore.normalizedLineEndings("a\r\nb\rc\nd"), "a\nb\nc\nd")
        XCTAssertEqual(MicronPageStore.normalizedLineEndings("\r\n\r\n"), "\n\n")
        XCTAssertEqual(MicronPageStore.normalizedLineEndings("\n\r"), "\n\n")
        XCTAssertEqual(MicronPageStore.normalizedLineEndings("\r\r\n"), "\n\n")
        XCTAssertEqual(MicronPageStore.normalizedLineEndings("plain"), "plain")
    }

    // MARK: - Listing rules

    func testIndexPageSortsFirst() throws {
        let (store, _) = try makeStore()
        try store.create(named: "zeta.mu", contents: "z")
        try store.create(named: "alpha.mu", contents: "a")
        try store.create(named: "index.mu", contents: "i")

        XCTAssertEqual(store.pages.map(\.relativePath), ["index.mu", "alpha.mu", "zeta.mu"])
    }

    func testSortingIsCaseInsensitiveAfterIndex() throws {
        let (store, _) = try makeStore()
        try store.create(named: "Beta.mu", contents: "b")
        try store.create(named: "alpha.mu", contents: "a")

        XCTAssertEqual(store.pages.map(\.relativePath), ["alpha.mu", "Beta.mu"])
    }

    func testAllowedFilesAreNeverListedAsPages() throws {
        let (store, root) = try makeStore()
        try writeRaw("page", to: root.appending(path: "secret.mu"))
        try writeRaw("aabbccdd\n", to: root.appending(path: "secret.mu.allowed"))
        try writeRaw("aabbccdd\n", to: root.appending(path: "index.mu.allowed"))
        store.reload()

        XCTAssertEqual(store.pages.map(\.relativePath), ["secret.mu"])
    }

    func testHiddenFilesAndDirectoriesAreSkipped() throws {
        let (store, root) = try makeStore()
        try writeRaw("visible", to: root.appending(path: "visible.mu"))
        try writeRaw("hidden", to: root.appending(path: ".hidden.mu"))
        try writeRaw("hidden", to: root.appending(path: ".git/config"))
        store.reload()

        XCTAssertEqual(store.pages.map(\.relativePath), ["visible.mu"])
    }

    func testNestedSubdirectoryPagesAreDiscoveredWithRelativePaths() throws {
        let (store, root) = try makeStore()
        try writeRaw("home", to: root.appending(path: "index.mu"))
        try writeRaw("about", to: root.appending(path: "sub/about.mu"))
        try writeRaw("deep", to: root.appending(path: "sub/deeper/thing.mu"))
        try writeRaw("acl", to: root.appending(path: "sub/about.mu.allowed"))
        store.reload()

        XCTAssertEqual(store.pages.map(\.relativePath),
                       ["index.mu", "sub/about.mu", "sub/deeper/thing.mu"])
        XCTAssertEqual(try store.read(store.pages[2]), "deep")
    }

    // MARK: - Rename

    func testRenameMovesWithinTheSameDirectory() throws {
        let (store, root) = try makeStore()
        try writeRaw("body", to: root.appending(path: "sub/old.mu"))
        store.reload()

        let renamed = try store.rename(store.pages[0], to: "new.mu")
        XCTAssertEqual(renamed.relativePath, "sub/new.mu")
        XCTAssertEqual(store.pages.map(\.relativePath), ["sub/new.mu"])
        XCTAssertEqual(try store.read(renamed), "body")
    }

    func testRenameToExistingNameThrows() throws {
        let (store, _) = try makeStore()
        let a = try store.create(named: "a.mu", contents: "a")
        try store.create(named: "b.mu", contents: "b")

        XCTAssertThrowsError(try store.rename(a, to: "b.mu")) { error in
            guard case MicronPageError.alreadyExists = error else {
                return XCTFail("expected .alreadyExists, got \(error)")
            }
        }
        XCTAssertEqual(store.pages.count, 2)
    }

    func testRenameCaseOnlySucceedsOnCaseInsensitiveVolumes() throws {
        // "Index.mu" -> "index.mu" is the same file on APFS-insensitive and on
        // every iOS device; a naive fileExists check rejects it.
        let (store, _) = try makeStore()
        let page = try store.create(named: "Index.mu", contents: "home")

        let renamed = try store.rename(page, to: "index.mu")
        XCTAssertEqual(renamed.relativePath, "index.mu")
        XCTAssertEqual(store.pages.map(\.relativePath), ["index.mu"])
        XCTAssertEqual(try store.read(renamed), "home")
    }

    func testRenameRejectsPathTraversal() throws {
        let (store, _) = try makeStore()
        let page = try store.create(named: "a.mu", contents: "a")

        for bad in ["../escape.mu", "sub/b.mu", ".hidden.mu", "", "b.mu.allowed"] {
            XCTAssertThrowsError(try store.rename(page, to: bad), "\(bad) must be rejected")
        }
        XCTAssertEqual(store.pages.map(\.relativePath), ["a.mu"])
    }

    // MARK: - Duplicate

    func testDuplicateAppendsCopySuffixAndPreservesContents() throws {
        let (store, _) = try makeStore()
        let page = try store.create(named: "index.mu", contents: ">Home\n")

        let copy = try store.duplicate(page)
        XCTAssertEqual(copy.relativePath, "index-copy.mu")
        XCTAssertEqual(try store.read(copy), ">Home\n")
        XCTAssertEqual(store.pages.map(\.relativePath), ["index.mu", "index-copy.mu"])
    }

    func testDuplicateTwiceUniquifiesWithACounter() throws {
        let (store, _) = try makeStore()
        let page = try store.create(named: "a.mu", contents: "x")

        XCTAssertEqual(try store.duplicate(page).relativePath, "a-copy.mu")
        XCTAssertEqual(try store.duplicate(page).relativePath, "a-copy-2.mu")
        XCTAssertEqual(try store.duplicate(page).relativePath, "a-copy-3.mu")
    }

    func testDuplicateOfNestedPageStaysNested() throws {
        let (store, root) = try makeStore()
        try writeRaw("deep", to: root.appending(path: "sub/page.mu"))
        store.reload()

        let copy = try store.duplicate(store.pages[0])
        XCTAssertEqual(copy.relativePath, "sub/page-copy.mu")
    }

    // MARK: - Delete

    func testDeleteRemovesThePage() throws {
        let (store, _) = try makeStore()
        let page = try store.create(named: "a.mu", contents: "a")
        try store.create(named: "b.mu", contents: "b")

        try store.delete(page)
        XCTAssertEqual(store.pages.map(\.relativePath), ["b.mu"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: page.url.path))
    }

    func testDeleteLeavesTheSiblingAllowedFileAlone() throws {
        let (store, root) = try makeStore()
        let acl = root.appending(path: "a.mu.allowed")
        let page = try store.create(named: "a.mu", contents: "a")
        try writeRaw("aabbccdd\n", to: acl)

        try store.delete(page)
        XCTAssertTrue(FileManager.default.fileExists(atPath: acl.path),
                      "an access list is operator config, not a derivative of the page")
    }

    // MARK: - Import

    func testImportCopiesAnExternalFileIn() throws {
        let (store, _) = try makeStore()
        let external = try makeTempRoot().appending(path: "imported.mu")
        try writeRaw("one\r\ntwo\r\n", to: external)

        let page = try store.importPage(from: external)
        XCTAssertEqual(page.relativePath, "imported.mu")
        XCTAssertEqual(try store.read(page), "one\ntwo\n", "import must normalise CRLF too")
    }

    func testImportNeverOverwritesAnExistingPage() throws {
        let (store, _) = try makeStore()
        try store.create(named: "index.mu", contents: "mine")
        let external = try makeTempRoot().appending(path: "index.mu")
        try writeRaw("theirs", to: external)

        let page = try store.importPage(from: external)
        XCTAssertEqual(page.relativePath, "index-2.mu")
        XCTAssertEqual(try store.read(store.pages[0]), "mine")
    }

    func testImportRejectsAHiddenFilename() throws {
        let (store, _) = try makeStore()
        let external = try makeTempRoot().appending(path: ".ssh_config")
        try writeRaw("x", to: external)

        XCTAssertThrowsError(try store.importPage(from: external)) { error in
            guard case MicronPageError.invalidName = error else {
                return XCTFail("expected .invalidName, got \(error)")
            }
        }
        XCTAssertTrue(store.pages.isEmpty)
    }

    // MARK: - Path traversal

    func testCreateRejectsEveryTraversalShape() throws {
        let (store, root) = try makeStore()
        let bad = ["../x", "../../etc/passwd", "a/b", "a\\b", ".hidden", "", "   ",
                   "..", "list.allowed", "nul\u{0}name"]

        for name in bad {
            XCTAssertThrowsError(try store.create(named: name, contents: "x"),
                                 "\"\(name)\" must be rejected") { error in
                guard case MicronPageError.invalidName = error else {
                    return XCTFail("expected .invalidName for \"\(name)\", got \(error)")
                }
            }
        }
        XCTAssertTrue(store.pages.isEmpty)
        // Nothing may have been written next to the root either.
        let sibling = root.deletingLastPathComponent().appending(path: "x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testHandCraftedEscapingPageIsRejectedByReadWriteAndDelete() throws {
        // A MicronPage is a plain struct, so a caller can forge one. Every
        // operation re-derives the URL from relativePath and re-checks it.
        let (store, root) = try makeStore()
        // The victim lives in its own managed temp directory, NOT in `root`'s
        // parent: that parent is the shared $TMPDIR, so the file survived every
        // run and could collide with a parallel test process. `relativePath`
        // still says "../outside.mu" — what is under test is that the store
        // re-derives the URL from that string rather than trusting `url`.
        let outsideDir = try makeTempRoot()
        let victim = outsideDir.appending(path: "outside.mu")
        try writeRaw("do not touch", to: victim)
        _ = root

        let forged = MicronPage(relativePath: "../outside.mu",
                                url: victim,
                                modified: Date(),
                                byteCount: 12)

        XCTAssertThrowsError(try store.read(forged))
        XCTAssertThrowsError(try store.write("clobbered", to: forged))
        XCTAssertThrowsError(try store.delete(forged))
        XCTAssertThrowsError(try store.duplicate(forged))
        XCTAssertThrowsError(try store.rename(forged, to: "ok.mu"))

        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "do not touch")
    }

    func testValidatedNameTrimsWhitespace() throws {
        XCTAssertEqual(try MicronPageStore.validatedName("  page.mu \n"), "page.mu")
    }

    // MARK: - Relocatable root

    func testCorruptBookmarkFallsBackToDefaultRootAndReportsIt() throws {
        let root = try makeTempRoot()
        let defaults = makeDefaults()
        defaults.set(Data([0x00, 0x01, 0x02, 0x03]),
                     forKey: MicronPageStore.bookmarkDefaultsKey)

        let store = MicronPageStore(rootOverride: root, defaults: defaults)
        XCTAssertEqual(store.rootURL, root, "must fall back, never guess")
        XCTAssertFalse(store.isUsingCustomRoot)
        XCTAssertNotNil(store.lastError)
    }

    func testSetRootEitherRelocatesAndPersistsOrLeavesTheRootUntouched() throws {
        let original = try makeTempRoot()
        let defaults = makeDefaults()
        let store = MicronPageStore(rootOverride: original, defaults: defaults)
        let elsewhere = try makeTempRoot()
        try writeRaw("served", to: elsewhere.appending(path: "index.mu"))

        // Creating a .withSecurityScope bookmark requires the app sandbox, which
        // a bare test process may not have. Either outcome is acceptable; what
        // must never happen is a half-applied root.
        do {
            try store.setRoot(elsewhere)
            XCTAssertEqual(store.rootURL, elsewhere)
            XCTAssertTrue(store.isUsingCustomRoot)
            XCTAssertEqual(store.pages.map(\.relativePath), ["index.mu"])
            XCTAssertNotNil(defaults.data(forKey: MicronPageStore.bookmarkDefaultsKey))

            store.resetRootToDefault()
            XCTAssertEqual(store.rootURL, original)
            XCTAssertFalse(store.isUsingCustomRoot)
            XCTAssertNil(defaults.data(forKey: MicronPageStore.bookmarkDefaultsKey))
        } catch {
            guard case MicronPageError.bookmarkFailed = error else { throw error }
            XCTAssertEqual(store.rootURL, original, "a failed setRoot must not move the root")
            XCTAssertFalse(store.isUsingCustomRoot)
        }
    }

    func testSetRootRejectsAFile() throws {
        let (store, original) = try makeStore()
        let file = try makeTempRoot().appending(path: "not-a-folder.mu")
        try writeRaw("x", to: file)

        XCTAssertThrowsError(try store.setRoot(file)) { error in
            guard case MicronPageError.rootUnavailable = error else {
                return XCTFail("expected .rootUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(store.rootURL, original)
    }

    // MARK: - Starter template

    func testStarterTemplateIsWellFormedMicron() throws {
        let template = MicronPageStore.starterTemplate
        let lines = template.components(separatedBy: "\n")

        XCTAssertTrue(lines.contains { $0.hasPrefix(">") }, "needs a heading")
        XCTAssertTrue(lines.contains("-"), "needs a divider on its own line")
        // `FT, not `F: six hex digits are the "T" form. The template used to say
        // "`F00b8ff", which the parser reads as the THREE-nibble tag "00b" plus
        // the literal text "8ff" — it rendered as "This page is 8ffMicron".
        // MicronAuthoringTests asserts the whole template lints clean; this pins
        // the specific tag.
        XCTAssertTrue(template.contains("`FT00b8ff"), "needs a 6-digit foreground colour tag")
        XCTAssertTrue(template.contains("`f"), "a colour tag must be reset")
        XCTAssertTrue(template.contains("`["), "needs a link")
        XCTAssertTrue(template.contains("`:/page/index.mu]"), "link must carry a URL and close")
        // Scalars, not characters: "\r\n" is one grapheme cluster, so
        // `contains("\r")` would miss a CRLF entirely.
        XCTAssertFalse(template.unicodeScalars.contains("\r"),
                       "the template itself must be LF-only")
    }

    func testCreatingFromTheStarterTemplateRoundTripsByteForByte() throws {
        let (store, _) = try makeStore()
        let page = try store.create(named: "index.mu",
                                    contents: MicronPageStore.starterTemplate)
        XCTAssertEqual(try store.read(page), MicronPageStore.starterTemplate)
    }
}
