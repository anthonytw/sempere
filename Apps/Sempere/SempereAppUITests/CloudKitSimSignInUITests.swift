import XCTest

/// Tooling, not a check of the app: signs the `sempere-cloudkit` simulator in to the CloudKit test Apple ID again, by driving the
/// Settings app. The simulator's sign-in expires about daily (cloudd: AuthTokenError 2011) and the live CloudKit suite
/// (`scripts/app.sh test-cloudkit`) needs it. Run by `tools/cloudkit-live/signin/sim-signin.sh`, which passes the Apple ID and
/// its password from the login keychain through a 0600 file of the run's own TMPDIR whose path is `TEST_RUNNER_CKL_SIGNIN_FILE` (never
/// a command line, the environment's contents, a file or an attachment; it is typed once, and a refusal stops the run). Without them the test skips, so no gate or sweep ever signs in.
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
    private var passwordTyped = false   // at most once in the whole run

    override func setUpWithError() throws {
        // The credentials are in a 0600 file of the run's own TMPDIR on the host (a simulator process reads host paths): the
        // environment carries only its path. Line 1 is the Apple ID, the rest is the password. Deleted as soon as it is read.
        guard let path = ProcessInfo.processInfo.environment["CKL_SIGNIN_FILE"], !path.isEmpty else {
            throw XCTSkip("tooling: run through tools/cloudkit-live/signin/sim-signin.sh (needs CKL_SIGNIN_FILE)")
        }
        let raw = try? String(contentsOfFile: path, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: path)
        guard let raw, let nl = raw.firstIndex(of: "\n") else { throw XCTSkip("CKL_SIGNIN_FILE is missing or unreadable") }
        var pw = String(raw[raw.index(after: nl)...])
        if pw.hasSuffix("\n") { pw.removeLast() }
        email = String(raw[..<nl]); password = pw
        guard !email.isEmpty, !password.isEmpty else { throw XCTSkip("CKL_SIGNIN_FILE holds no credentials") }
        continueAfterFailure = false
    }

    private struct Stop: Error {}

    /// A marker line the script reads, written straight to stderr (unbuffered: a crash right after must not lose it).
    private func mark(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
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

    /// The text of what is on screen, from one snapshot (the element queries race with a screen that is changing): only
    /// `label: '…'` parts, never a field's value.
    private func labels(_ app: XCUIApplication) -> String {
        let d = app.debugDescription
        guard let re = try? NSRegularExpression(pattern: "label: '([^']*)'") else { return "" }
        let found = re.matches(in: d, range: NSRange(d.startIndex..., in: d)).compactMap { m -> String? in
            Range(m.range(at: 1), in: d).map { String(d[$0]) }
        }
        var seen = Set<String>()
        return found.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(40).joined(separator: " | ")
    }

    private static let twoFactorPattern = "(verification code|two-factor authentication|enter the code|6-digit code|six-digit code|c.digo de verificaci.n|ingresa el c.digo)"
    private static let refusedPattern = "((incorrect|wrong|isn.t correct|not correct|incorrecta|incorrecto).*(password|contrase.a)|(password|contrase.a).*(incorrect|wrong|isn.t correct|not correct|incorrecta|incorrecto))"

    private func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Everything readable on `app` (screen labels) and in its alert, as one string.
    private func text(_ app: XCUIApplication) -> String { labels(app) }

    private func alertText(_ a: XCUIElement) -> String {
        ([a.label] + a.staticTexts.allElementsBoundByIndex.map { $0.label }).joined(separator: " / ")
    }

    /// Stops the run: leaves a clean state (a sheet closed, Settings ended), reports, and returns the error to throw.
    private func stop(_ message: String) -> Error {
        if !passwordTyped { mark("SIGNIN-NOTHING-TYPED") }   // the only positive evidence that no attempt was made
        for _ in 0..<3 { _ = tap(settings, "(cancel|not now|close|dismiss)", "cleanup") }
        settings.terminate()
        XCTFail(message + " Steps: " + steps.joined(separator: " > "))
        return Stop()
    }

    private func refused(_ shown: String) -> Error {
        print("SIGNIN-REFUSED")
        return stop("Apple refused the password (changed or wrong?): not retried; re-save the keychain item. Screen: \(shown)")
    }

    private func twoFactor(_ shown: String) -> Error {
        print("SIGNIN-2FA \(shown)")
        return stop("needs a code sent to the account's trusted device (two-factor): Apple asked for a verification code; this tool never answers it.")
    }

    /// Types `text` into an empty secure field, once; returns false when the field already holds something (never types twice).
    private func typeOnce(_ field: XCUIElement, _ text: String) -> Bool {
        let v = field.value as? String ?? ""
        if v.contains("\u{2022}") || v.contains("\u{25CF}") { return false }   // bullets: already filled
        passwordTyped = true
        mark("SIGNIN-PASSWORD-TYPING")   // before the keys go in: the script counts an attempt from here on
        field.tap()
        field.typeText(text)
        return true
    }

    /// After the password is in: wait for the secure field to go, a refusal text or a verification-code screen, whichever comes first.
    private func awaitAnswer(_ host: XCUIApplication, field: XCUIElement) throws {
        let end = Date().addingTimeInterval(45)
        while Date() < end {
            let shown = text(host) + " " + (springboard.alerts.firstMatch.exists ? alertText(springboard.alerts.firstMatch) : "")
                + " " + (host.alerts.firstMatch.exists ? alertText(host.alerts.firstMatch) : "")
            if matches(shown, Self.twoFactorPattern) { throw twoFactor(shown) }
            if matches(shown, Self.refusedPattern) { throw refused(shown) }
            if !field.exists { Thread.sleep(forTimeInterval: 2); return }
            Thread.sleep(forTimeInterval: 1)
        }
        throw stop("the password field did not go away 45 s after the password was typed. Screen: \(labels(host))")
    }

    @MainActor
    func testSignInAgain() throws {
        XCUIDevice.shared.orientation = .portrait
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        defer { settings.terminate() }
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 30))

        var emailTyped = false
        var accountOpened = false
        Thread.sleep(forTimeInterval: 6)   // the expired token's alert comes a moment after Settings opens
        let deadline = Date().addingTimeInterval(240)
        var idle = 0
        while Date() < deadline {
            // Alerts, in Settings and in SpringBoard: a verification code stops the run before anything is tapped; the sign-in
            // ones (expired token, "Sign in to iCloud") are answered; any other alert stops the run untouched.
            for host in [settings, springboard] where host.alerts.firstMatch.exists {
                let a = host.alerts.firstMatch
                let shown = alertText(a)
                print("SIGNIN-STEP alert: \(shown)")
                if matches(shown, Self.twoFactorPattern) { throw twoFactor(shown) }
                if passwordTyped && matches(shown, Self.refusedPattern) { throw refused(shown) }
                guard matches(shown, "(account verification|verificaci.n de cuenta|sign in to icloud|inicia sesi.n en icloud|apple account|cuenta de apple|apple id)") else {
                    throw stop("unrecognized alert (not tapped): \(shown)")
                }
                steps.append("alert")
                let secure = a.secureTextFields.firstMatch
                if secure.exists {
                    if passwordTyped { throw refused(shown) }
                    guard typeOnce(secure, password) else { throw stop("the alert's password field is already filled") }
                    passwordTyped = true; steps.append("password")
                    let ok = a.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", "(sign in|ok|done|iniciar sesi.n|aceptar|continue|continuar)")).firstMatch
                    guard ok.exists else { throw stop("the password alert has no sign-in button: \(shown)") }
                    ok.tap()
                    try awaitAnswer(host, field: secure)
                    continue
                }
                let go = a.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", "(settings|sign in|continue|update|configuraci.n|iniciar sesi.n|continuar)")).firstMatch
                guard go.exists else { throw stop("the sign-in alert has no known button: \(shown)") }
                go.tap()
                Thread.sleep(forTimeInterval: 3)
            }
            let screen = labels(settings)
            print("SIGNIN-STEP screen: \(screen)")
            if matches(screen, Self.twoFactorPattern) { throw twoFactor(screen) }
            if passwordTyped && matches(screen, Self.refusedPattern) { throw refused(screen) }
            // The password sheet (secure field; typed from the environment, once, never read back).
            let secure = settings.secureTextFields.firstMatch
            if secure.exists {
                if passwordTyped { throw refused(screen) }   // asked again after one typing: refused or looping; never a second try
                guard typeOnce(secure, password) else { throw stop("the password field is already filled. Screen: \(screen)") }
                passwordTyped = true; steps.append("password")
                settings.typeText("\n")
                try awaitAnswer(settings, field: secure)
                continue
            }
            // Email page (the signed-out case).
            let field = settings.textFields.firstMatch
            if field.exists, has(settings, ".*(apple account|apple id|email).*") {
                let v = field.value as? String ?? ""
                if v.isEmpty || v.lowercased().contains("email") || v.lowercased().contains("example") {
                    if emailTyped { throw stop("Apple refused the email address. Screen: \(screen)") }
                    field.tap(); field.typeText(email); emailTyped = true; steps.append("email")
                    settings.typeText("\n")
                    Thread.sleep(forTimeInterval: 4)
                    continue
                }
            }
            // Terms, merge and the other confirmation prompts.
            if tap(settings, "(agree|acepto|estoy de acuerdo)", "agree") || tap(settings, "(don.t merge)", "dont-merge") { Thread.sleep(forTimeInterval: 2); idle = 0; continue }
            if tap(settings, "(merge)", "merge") { Thread.sleep(forTimeInterval: 2); idle = 0; continue }
            if tap(settings, "(use passcode|continue|next|done|continuar|siguiente)", "continue") { Thread.sleep(forTimeInterval: 2); idle = 0; continue }
            // Done: after a password was typed and accepted, no sign-in prompt is left on screen.
            let signedOutBanner = has(settings, "(sign in to your .*|sign in|inicia sesi.n.*)")
            let expired = has(settings, ".*(sign in again|apple account (update|suggestions)|account update|verify).*")
            if !signedOutBanner && !expired && has(settings, ".*(icloud|apple account).*") && passwordTyped {
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
            if idle > 4 { throw stop("no sign-in prompt found (the account may be fine already). Screen: \(screen)") }
            Thread.sleep(forTimeInterval: 2)
        }
        throw stop("timed out signing in. Screen: \(labels(settings))")
    }
}
