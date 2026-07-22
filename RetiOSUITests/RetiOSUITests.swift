import XCTest

/// UI tests that launch the real app and drive it through the accessibility API.
///
/// ## Why this target exists
///
/// `@Environment(SomeModel.self)` is non-optional and **traps at runtime** when
/// a scene forgets to inject the model. It does not fail to compile, and unit
/// tests never build a scene — so nothing else in this project can catch it.
/// The only way to know a screen is reachable is to reach it.
///
/// macOS sharpens this: the Preferences window (⌘,) is a *separate* `Settings`
/// scene with its own environment, so a screen reachable from both the main
/// window and Preferences can work in one and crash in the other. That is not a
/// hypothetical here — `RetiOSApp.appEnvironment` carries a comment about the
/// Settings scene having once been under-injected.
///
/// ## Platform support — read before assuming the Mac tests run
///
/// **iOS Simulator: unattended.** The simulator grants the test runner
/// accessibility access, so these run from a bare `xcodebuild test` and in CI.
///
/// **macOS: needs a one-time Accessibility grant.** This is *not* automatic.
/// `xcodebuild test` on a Mac fails with
///
///     Application 'dev.sprell.retios' has not loaded accessibility
///
/// after a 60 s "Wait for accessibility to load", unless the process running
/// the tests holds Accessibility permission. Grant it to the terminal (or CI
/// agent) under System Settings ▸ Privacy & Security ▸ Accessibility, or run
/// from Xcode.app, which prompts the first time. macOS also needs a signable
/// bundle; the entitlements can be dropped for a local run — they only disable
/// Yggdrasil, which these tests never touch:
///
///     xcodebuild test -scheme RetiOS -destination 'platform=macOS,arch=arm64' \
///       -only-testing:RetiOSUITests \
///       CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGN_ENTITLEMENTS=
///
/// The Mac tests here are written and correct; they are gated on that grant,
/// which is also why CI runs the iOS destination only.
///
/// ## What is deliberately not tested
///
/// Nothing here taps **Scan** on the RNode screen when running on macOS. That
/// creates a real `CBCentralManager` and would raise the system Bluetooth
/// permission dialog on the developer's own Mac — an unattended test must not
/// do that. The iOS Simulator has no Bluetooth radio, so the same tap there is
/// inert and reports "Bluetooth unavailable", which is what
/// `testRNodeControllerStateSurvivesNavigation` relies on.
final class RetiOSUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Launch

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // `-key value` launch arguments land in UserDefaults' argument domain,
        // which outranks everything else — so these skip the onboarding sheet
        // and suppress network bring-up without the app needing a test-only
        // UI path.
        //
        // `-stackOffline` matters more than it looks. XCTest relaunches the app
        // for every test method, so without it each method rejoined
        // AutoInterface's multicast group, redialled every saved gateway,
        // respawned i2pd and re-armed the Yggdrasil VPN profile — then had all
        // of it killed abruptly when the test ended. That churn disrupts a real
        // mesh the developer's machine belongs to, and makes the tests slow and
        // dependent on network state. None of the assertions here need a live
        // mesh. See `StackController.isOfflineUITestRun`.
        app.launchArguments += ["-hasCompletedOnboarding", "YES",
                                "-stackOffline", "YES"]
        app.launch()
        return app
    }

    /// The app brings up a real Reticulum stack on launch, so the first frame
    /// can lag. Waits for any of the top-level destinations to exist.
    @discardableResult
    private func waitForMainUI(_ app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
        let anchor = app.staticTexts["Messages"].firstMatch
        return anchor.waitForExistence(timeout: timeout)
    }

    // MARK: - Smoke

    func testAppLaunchesAndShowsMainUI() {
        let app = launchApp()
        XCTAssertTrue(waitForMainUI(app),
                      "main UI never appeared.\n\(app.debugDescription)")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - The trap path

    /// Reaching the RNode screen at all is the assertion: a missing
    /// `@Environment(RNodeScannerController.self)` injection kills the app here
    /// rather than failing gracefully.
    func testRNodeScreenIsReachable() {
        let app = launchApp()
        XCTAssertTrue(waitForMainUI(app), "main UI never appeared")

        XCTAssertTrue(navigateToInterfaces(app),
                      "could not reach Interfaces.\n\(app.debugDescription)")
        XCTAssertTrue(openRNode(app),
                      "could not reach the RNode screen.\n\(app.debugDescription)")

        // If the environment injection were missing the process would already
        // be gone; assert it explicitly so the failure reads correctly.
        XCTAssertEqual(app.state, .runningForeground,
                       "app terminated while presenting the RNode screen")
    }

    #if os(macOS)
    /// macOS-only: the Preferences window is its own scene. This is the path
    /// that could not be covered by driving the app by hand, because macOS
    /// withholds Accessibility permission from ad-hoc automation.
    func testRNodeScreenIsReachableFromPreferencesScene() {
        let app = launchApp()
        XCTAssertTrue(waitForMainUI(app), "main UI never appeared")

        // ⌘, opens the Settings scene — a different environment from the
        // WindowGroup the sidebar lives in.
        app.typeKey(",", modifierFlags: .command)

        let interfaces = app.staticTexts["Interfaces"].firstMatch
        XCTAssertTrue(interfaces.waitForExistence(timeout: 20),
                      "Preferences window never presented Interfaces.\n\(app.debugDescription)")
        interfaces.click()

        XCTAssertTrue(openRNode(app),
                      "RNode unreachable from Preferences.\n\(app.debugDescription)")
        XCTAssertEqual(app.state, .runningForeground,
                       "app terminated presenting RNode from the Preferences scene")
    }
    #endif

    // MARK: - Regression: RNode controller must outlive navigation

    #if os(iOS)
    /// Regression test for the zombie-interface fix (v0.3.3).
    ///
    /// `RNodeScannerController` used to be a view-scoped `@State`, so leaving
    /// the screen destroyed it — taking its `CBCentralManager`, and with it the
    /// disconnect callback that deregisters the `RNodeInterface`, while
    /// `Transport.interfaces` (a strong array) kept the dead interface forever.
    ///
    /// Controller *lifetime* is not directly observable from a UI test, so this
    /// asserts the observable consequence: state set on the screen survives
    /// leaving and returning. A view-scoped controller would be reconstructed
    /// and fall back to "Idle".
    ///
    /// iOS Simulator only — see the note on this class about the Bluetooth
    /// permission dialog. Here the radio is absent, so tapping Scan lands in a
    /// stable `bluetoothUnavailable` state with no prompt and no side effects.
    func testRNodeControllerStateSurvivesNavigation() {
        let app = launchApp()
        XCTAssertTrue(waitForMainUI(app), "main UI never appeared")
        XCTAssertTrue(navigateToInterfaces(app), "could not reach Interfaces")
        XCTAssertTrue(openRNode(app), "could not reach the RNode screen")

        let scan = app.buttons["Scan"].firstMatch
        XCTAssertTrue(scan.waitForExistence(timeout: 10),
                      "no Scan button.\n\(app.debugDescription)")
        scan.tap()

        let unavailable = app.staticTexts["Bluetooth unavailable"].firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15),
                      "expected the simulator's radio-less state.\n\(app.debugDescription)")

        // Leave and come back.
        goBack(app)
        XCTAssertTrue(app.staticTexts["RNode (LoRa / BLE)"].firstMatch
                        .waitForExistence(timeout: 10),
                      "did not return to Interfaces.\n\(app.debugDescription)")
        XCTAssertTrue(openRNode(app), "could not re-open the RNode screen")

        XCTAssertTrue(app.staticTexts["Bluetooth unavailable"].firstMatch
                        .waitForExistence(timeout: 10),
                      "controller state was lost across navigation — the scanner "
                      + "is view-scoped again, which is what stranded a dead "
                      + "RNodeInterface in Transport.\n\(app.debugDescription)")
    }
    #endif

    // MARK: - Navigation helpers
    //
    // The app has no accessibility identifiers, so these match on visible
    // labels. Each helper tries the element kinds the layout can produce
    // (a sidebar row, a Form row, a button) rather than assuming one.

    private func navigateToInterfaces(_ app: XCUIApplication) -> Bool {
        #if os(macOS)
        // Mac drops Settings from the sidebar (it lives in ⌘,), so Interfaces
        // is a top-level sidebar row.
        return tapFirstMatch(app, label: "Interfaces")
        #else
        // Phone reaches Interfaces through the Settings tab; iPad has it in the
        // sidebar directly. Try the direct route, then the Settings route.
        if tapFirstMatch(app, label: "Interfaces", timeout: 5) { return true }
        guard tapFirstMatch(app, label: "Settings") else { return false }
        return tapFirstMatch(app, label: "Interfaces")
        #endif
    }

    private func openRNode(_ app: XCUIApplication) -> Bool {
        tapFirstMatch(app, label: "RNode (LoRa / BLE)")
    }

    private func goBack(_ app: XCUIApplication) {
        #if os(macOS)
        app.typeKey("[", modifierFlags: .command)
        #else
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        #endif
    }

    /// Finds `label` as a button, static text, or table/outline cell and
    /// activates it. Returns false rather than failing so callers can attach
    /// the element tree to a more specific message.
    @discardableResult
    private func tapFirstMatch(_ app: XCUIApplication,
                               label: String,
                               timeout: TimeInterval = 20) -> Bool {
        let candidates: [XCUIElementQuery] = [
            app.buttons, app.staticTexts, app.cells, app.otherElements,
        ]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for query in candidates {
                let element = query[label].firstMatch
                if element.exists && element.isHittable {
                    #if os(macOS)
                    element.click()
                    #else
                    element.tap()
                    #endif
                    return true
                }
            }
            usleep(300_000)
        }
        return false
    }
}
