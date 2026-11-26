import XCTest

/// Tooling, not a check of the app: signs the `sempere-cloudkit` simulator in to the CloudKit test Apple ID again, by driving the
/// Settings app. The simulator's sign-in expires about daily (cloudd: AuthTokenError 2011) and the live CloudKit suite
/// (`scripts/app.sh test-cloudkit`) needs it. Run by `tools/cloudkit-live/signin/sim-signin.sh`, which passes the Apple ID and
/// its password from the login keychain through `TEST_RUNNER_CKL_SIGNIN_EMAIL` / `TEST_RUNNER_CKL_SIGNIN_PASSWORD` (environment
/// only: never a command line, a file or an attachment). Without them the test skips, so no gate or sweep ever signs in.
///
/// Both cases are handled: a signed-out account ("Sign in to your iPhone") and an expired token ("Sign in again" / "Apple
/// Account update" banner or alert). A verification code (two-factor) is never answered: the test fails with a clear message and
/// leaves Settings on its top page. iPhone simulator only.
@MainActor
final class CloudKitSimSignInUITests: XCTestCase {
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var email = ""
    private var password = ""
    private var steps: [String] = []

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let e = env["CKL_SIGNIN_EMAIL"], !e.isEmpty, let p = env["CKL_SIGNIN_PASSWORD"], !p.isEmpty else {
            throw XCTSkip("tooling: run through tools/cloudkit-live/signin/sim-signin.sh (needs CKL_SIGNIN_EMAIL and CKL_SIGNIN_PASSWORD)")
        }
        email = e; password = p
        continueAfterFailure = false
    }

    /// Texts on screen (labels of static texts, buttons and cells) matching `pattern`, case-insensitively.
    private func has(_ app: XCUIApplication, _ pattern: String) -> Bool {
        let p = NSPredicate(format: "label MATCHES[c] %@", pattern)
        return app.staticTexts.matching(p).firstMatch.exists || app.buttons.matching(p).firstMatch.exists
            || app.cells.matching(p).firstMatch.exists
    }

    private func tap(_ app: XCUIApplication, _ pattern: String, _ note: String) -> Bool {
        let p = NSPredicate(format: "label MATCHES[c] %@", pattern)
        for q in [app.buttons.matching(p), app.cells.matching(p), app.staticTexts.matching(p)] {
            let e = q.firstMatch
            if e.exists && e.isHittable { e.tap(); steps.append(note); return true }
        }
        return false
    }

    /// The text of what is on screen without any field value (a secure field's value is never read).
    private func labels(_ app: XCUIApplication) -> String {
        // From one snapshot (the element queries race with a screen that is changing); only `label: '…'` parts, never a value.
        let d = app.debugDescription
        guard let re = try? NSRegularExpression(pattern: "label: '([^']*)'") else { return "" }
        let found = re.matches(in: d, range: NSRange(d.startIndex..., in: d)).compactMap { m -> String? in
            Range(m.range(at: 1), in: d).map { String(d[$0]) }
        }
        var seen = Set<String>()
        return found.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(40).joined(separator: " | ")
    }

    private func isTwoFactor(_ app: XCUIApplication) -> Bool {
        has(app, ".*(verification code|two-factor|enter the code|6-digit|six-digit|c.digo de verificaci.n).*")
    }

    private func bail(_ message: String) -> Never {
        // Leave a clean state: dismiss whatever sheet is open and return Settings to its top page.
        for _ in 0..<3 { _ = tap(settings, "(cancel|not now|close|dismiss|back)", "cleanup") }
        settings.terminate()
        XCTFail(message + " Steps: " + steps.joined(separator: " > "))
        fatalError(message)
    }

    private func type(_ field: XCUIElement, _ text: String) {
        field.tap()
        field.typeText(text)
    }

    @MainActor
    func testSignInAgain() throws {
        XCUIDevice.shared.orientation = .portrait
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        defer { settings.terminate() }
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 30))

        var passwordsTyped = 0
        var alertsSeen = 0
        var accountOpened = false
        Thread.sleep(forTimeInterval: 6)   // the expired token's alert comes a moment after Settings opens
        var emailsTyped = 0
        let deadline = Date().addingTimeInterval(240)
        var idle = 0
        while Date() < deadline {
            // The expired token's alert ("Apple Account Verification: enter the password of … in Settings", buttons Not Now / Settings;
            // in the Settings process or SpringBoard) opens the account page; any other alert is answered with its default button.
            for host in [settings, springboard] where host.alerts.firstMatch.exists {
                let a = host.alerts.firstMatch
                print("SIGNIN-STEP alert: \(a.label) \(a.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " / "))")
                steps.append("alert")
                alertsSeen += 1
                if a.secureTextFields.firstMatch.exists {
                    // A sign-in alert with the password field in it ("Sign in to iCloud", Apple Account password).
                    if passwordsTyped >= 2 { bail("Apple refused the password twice (changed or wrong?): re-save it in the keychain item sempere-test-apple-id.") }
                    type(a.secureTextFields.firstMatch, password); passwordsTyped += 1; steps.append("password")
                    let ok = a.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", "(sign in|ok|done|iniciar sesi.n|aceptar|continue|continuar)")).firstMatch
                    if ok.exists { ok.tap() } else { a.buttons.allElementsBoundByIndex.last?.tap() }
                    Thread.sleep(forTimeInterval: 8)
                    continue
                }
                let go = a.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", "(settings|sign in|continue|update|ok|configuraci.n|iniciar sesi.n|continuar|aceptar)")).firstMatch
                if go.exists { go.tap() } else { a.buttons.firstMatch.tap() }
                Thread.sleep(forTimeInterval: 3)
            }
            print("SIGNIN-STEP screen: \(labels(settings))")
            if isTwoFactor(settings) {
                print("SIGNIN-2FA screen: \(labels(settings))")
                bail("needs a code sent to the account's trusted device (two-factor): Apple asked for a verification code; this tool never answers it.")
            }
            // Password (the field is secure; typed from the environment, never read back).
            let secure = settings.secureTextFields.firstMatch
            if secure.exists {
                if passwordsTyped >= 2 { bail("Apple refused the password twice (changed or wrong?): re-save it in the keychain item sempere-test-apple-id.") }
                type(secure, password); passwordsTyped += 1; steps.append("password")
                settings.typeText("\n")
                Thread.sleep(forTimeInterval: 6)
                continue
            }
            // Email page.
            let field = settings.textFields.firstMatch
            if field.exists, has(settings, ".*(apple account|apple id|email).*") {
                let v = field.value as? String ?? ""
                if v.isEmpty || v.lowercased().contains("email") || v.lowercased().contains("example") {
                    if emailsTyped >= 2 { bail("Apple refused the email address.") }
                    type(field, email); emailsTyped += 1; steps.append("email")
                    settings.typeText("\n")
                    Thread.sleep(forTimeInterval: 4)
                    continue
                }
            }
            // Terms, merge and the other confirmation prompts.
            if tap(settings, "(agree|acepto|estoy de acuerdo)", "(agree|acepto|estoy de acuerdo)") || tap(settings, "(don.t merge)", "dont-merge") { Thread.sleep(forTimeInterval: 2); idle = 0; continue }
            if tap(settings, "(merge)", "merge") { Thread.sleep(forTimeInterval: 2); idle = 0; continue }
            if tap(settings, "(use passcode|continue|next|done|continuar|siguiente|ok)", "continue") { Thread.sleep(forTimeInterval: 2); idle = 0; continue }
            // Done: Settings' top page shows the account banner with the iCloud row, and no sign-in call to action.
            let signedOutBanner = has(settings, "(sign in to your .*|sign in|inicia sesi.n.*)")
            let expired = has(settings, ".*(sign in again|apple account (update|suggestions)|account update|verify).*")
            if !signedOutBanner && !expired && has(settings, ".*(icloud|apple account).*") && passwordsTyped > 0 {
                steps.append("signed-in")
                print("SIGNIN-OK \(steps.joined(separator: " > "))")
                return
            }
            // A sign-in entry: the signed-out banner, or the "sign in again" row/banner of an expired token.
            if tap(settings, ".*(sign in again|enter password|apple account (update|suggestions)|account update|sign in to your .*|sign in|verify.*|inicia sesi.n.*|ingresa.*contrase.*|verifica.*)", "sign-in") {
                Thread.sleep(forTimeInterval: 3); idle = 0; continue
            }
            // Nothing asks for a sign-in on the top page: open the account page once (an expired token shows its prompt there).
            if !accountOpened, tap(settings, ".*(apple account, icloud|cuenta de apple, icloud).*", "open-account") {
                accountOpened = true
                Thread.sleep(forTimeInterval: 4)
                print("SIGNIN-STEP account page: \(labels(settings))")
                continue
            }
            idle += 1
            if idle > 4 { bail("did not recognise the screen: \(labels(settings))") }
            Thread.sleep(forTimeInterval: 2)
        }
        bail("timed out signing in. Screen: \(labels(settings))")
    }
}
