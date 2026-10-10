import SwiftUI
import UIKit

/// The Mac menu bar's File and Edit menus (TestFlight build 6).
///
/// UIKit builds a default menu bar before SwiftUI adds the app's commands:
/// File > New Window (⌘N), Open… (⌘O), Open Recent, the document commands
/// (Duplicate, Move, Rename…, Export As…) and Edit > Find (⌘F, ⌘G…). UIKit
/// refuses a SwiftUI group whose shortcut is taken ("Replacement elements
/// conflict"), and with it the whole group, so ⌘O and ⌘F cost the app every
/// File and Edit command and ⌘N opened UIKit's New Window: a second library
/// window. So Open Vault… and Find Notes are not SwiftUI commands
/// (`MenuCommand.nativeOnMac`): UIKit's ⌘O and ⌘F items become them here,
/// acting on the focused window's `CommandRouter` (`MenuRouting`), and UIKit's
/// commands that act on documents or text find are dropped.
enum MacMenus {
    /// The UIKit menus whose own commands are dropped (the app's SwiftUI
    /// commands in them stay).
    static let pruned: [UIMenu.Identifier] = [.newScene, .document]
    /// Edit > Find Notes when UIKit built no Find menu to turn into it.
    static let findMenu = UIMenu.Identifier("io.github.anthonytw.sempere.find")
    /// The app menu's Settings… when UIKit built no preferences menu to turn into it.
    static let settingsMenu = UIMenu.Identifier("io.github.anthonytw.sempere.settings")

    /// Whether `element` is one of the app's own commands (SwiftUI's
    /// `Commands`, which UIKit sees as commands with SwiftUI's private
    /// main-menu actions, or as its own submenus and actions), not UIKit's.
    static func isAppElement(_ element: UIMenuElement) -> Bool {
        if let command = element as? UICommand {
            return NSStringFromSelector(command.action).contains("performMainMenu")
        }
        return true   // UIAction and submenus: built by SwiftUI here (UIKit's own items are UICommands)
    }

    /// The key command standing for `command` (⌘O or ⌘F), sent to the focused
    /// window through the responder chain (`UIWindow.sempereMenuCommand`).
    @MainActor
    static func nativeItem(_ command: MenuCommand) -> UIKeyCommand {
        let shortcut = command.shortcut ?? MenuCommand.Shortcut(" ")
        var flags: UIKeyModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.alternate) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        return UIKeyCommand(title: command.title, action: #selector(UIWindow.sempereMenuCommand(_:)),
                            input: String(shortcut.key), modifierFlags: flags, propertyList: command.rawValue)
    }

    /// A menu item with no key equivalent for `command` (About Sempere, the Help
    /// menu), sent to the focused window like `nativeItem`.
    @MainActor
    static func nativeCommand(_ command: MenuCommand) -> UICommand {
        UICommand(title: command.title, action: #selector(UIWindow.sempereMenuCommand(_:)), propertyList: command.rawValue)
    }

    /// Rebuilds the File and Edit menus being built: UIKit's Open… and Find
    /// become Open Vault… and Find Notes, its document commands and New
    /// Window go.
    @MainActor
    static func prune(_ builder: UIMenuBuilder) {
        if builder.menu(for: .open) != nil {
            // Open… and UIKit's Open Recent (recent documents; the app lists recent vaults itself).
            builder.replaceChildren(ofMenu: .open) { _ in [nativeItem(.openVault)] }
            built.append("open → Open Vault…")
        }
        if builder.menu(for: .find) != nil {
            // Find…, Find & Replace, Find Next/Previous (⌘G is the search bar's), Use Selection.
            builder.replaceChildren(ofMenu: .find) { _ in [nativeItem(.find)] }
            built.append("find → Find Notes")
        } else if builder.menu(for: .edit) != nil, builder.menu(for: findMenu) == nil {
            // UIKit leaves Find out of some builds: the app's goes at the end of Edit.
            let menu = UIMenu(title: "", identifier: findMenu, options: .displayInline, children: [nativeItem(.find)])
            builder.insertChild(menu, atEndOfMenu: .edit)
            built.append("Find Notes added")
        }
        if builder.menu(for: .preferences) != nil {
            // UIKit's Settings… (⌘,) opens Catalyst's generated pane (touch alternatives): the app's instead.
            builder.replaceChildren(ofMenu: .preferences) { _ in [nativeItem(.showSettings)] }
            built.append("preferences → Settings…")
        } else if builder.menu(for: .application) != nil, builder.menu(for: settingsMenu) == nil {
            let menu = UIMenu(title: "", identifier: settingsMenu, options: .displayInline, children: [nativeItem(.showSettings)])
            if builder.menu(for: .about) != nil {
                builder.insertSibling(menu, afterMenu: .about)
            } else {
                builder.insertChild(menu, atStartOfMenu: .application)
            }
            built.append("Settings… added")
        }
        if builder.menu(for: .about) != nil {
            // UIKit's About opens the standard panel: the app's About shows the licence, links and acknowledgements.
            builder.replaceChildren(ofMenu: .about) { _ in [nativeCommand(.showAbout)] }
            built.append("about → About Sempere")
        }
        if builder.menu(for: .help) != nil {
            // UIKit's "Sempere Help" opens no help book: the tour and the key notice instead.
            builder.replaceChildren(ofMenu: .help) { _ in MenuLayout.help.flatMap { $0 }.map { nativeCommand($0) as UIMenuElement } }
            built.append("help → Quick Tour, About Your Key")
        }
        for identifier in pruned {
            guard let menu = builder.menu(for: identifier) else { continue }
            let kept = menu.children.filter(isAppElement)
            if kept.count == menu.children.count { continue }
            // The menu itself stays (even empty): SwiftUI places the app's groups by these identifiers.
            builder.replaceChildren(ofMenu: identifier) { _ in kept }
            built.append("pruned \(identifier.rawValue): \(menu.children.count - kept.count)")
        }
    }

    /// The whole menu bar as lines "depth|kind|title|action|input" (debug log, tests).
    @MainActor
    static func tree(_ builder: UIMenuBuilder) -> [String] {
        func walk(_ element: UIMenuElement, _ depth: Int) -> [String] {
            if let menu = element as? UIMenu {
                return ["\(depth)|menu \(menu.identifier.rawValue)|\(menu.title)"] + menu.children.flatMap { walk($0, depth + 1) }
            }
            if let key = element as? UIKeyCommand {
                return ["\(depth)|key|\(key.title)|\(key.action.map(NSStringFromSelector) ?? "")|\(key.input ?? "")"]
            }
            if let command = element as? UICommand {
                return ["\(depth)|command|\(command.title)|\(NSStringFromSelector(command.action))"]
            }
            if let action = element as? UIAction { return ["\(depth)|action|\(action.title)"] }
            return ["\(depth)|\(type(of: element))"]
        }
        return builder.menu(for: .root).map { walk($0, 0) } ?? []
    }

    /// What `prune` did since launch (tests and the debug log).
    @MainActor static var built: [String] = []

    /// Every key command left in the menu bar, as "input flags" strings (tests:
    /// no two may be equal).
    @MainActor
    static func shortcuts(in builder: UIMenuBuilder) -> [String] {
        func walk(_ element: UIMenuElement) -> [String] {
            if let menu = element as? UIMenu { return menu.children.flatMap(walk) }
            guard let key = element as? UIKeyCommand, let input = key.input, !input.isEmpty else { return [] }
            return ["\(input.lowercased()) \(key.modifierFlags.rawValue)"]
        }
        return builder.menu(for: .root).map(walk) ?? []
    }
}

/// The routers of the open windows, by window scene: what a UIKit menu item
/// (`MacMenus.nativeItem`) acts on. Each window publishes its router with
/// `menuRouter(_:)`, as it does with `focusedSceneValue` for SwiftUI's commands.
@MainActor
final class MenuRouting {
    static let shared = MenuRouting()
    /// `WindowGroup` id of the app's settings window (`SempereApp`).
    static let settingsSceneID = SceneRestoration.settingsSceneID

    private var routers: [ObjectIdentifier: CommandRouter] = [:]
    private var scenes: [ObjectIdentifier: WeakScene] = [:]

    private struct WeakScene {
        weak var scene: UIWindowScene?
    }

    func set(_ router: CommandRouter?, for scene: UIWindowScene) {
        let id = ObjectIdentifier(scene)
        routers[id] = router
        scenes[id] = router == nil ? nil : WeakScene(scene: scene)
    }

    /// A scene showing a library window (the menu-bar item brings it forward).
    func libraryScene() -> UIWindowScene? {
        routers.first { $0.value.context.window == .library && scenes[$0.key]?.scene != nil }
            .flatMap { scenes[$0.key]?.scene }
    }

    func router(for scene: UIWindowScene?) -> CommandRouter? {
        scene.flatMap { routers[ObjectIdentifier($0)] }
    }

    /// Opens a scene by its `WindowGroup` id, kept from the last window that
    /// appeared (`OpenScenePublisher`): Settings… works with no window focused.
    var openScene: ((String) -> Void)?

    /// Runs `command` in `scene`'s window if it is enabled there; false when it is not.
    /// Settings… needs no window: it opens the app's settings window (device
    /// settings need no vault either).
    @discardableResult
    func perform(_ command: MenuCommand, in scene: UIWindowScene?) -> Bool {
        if command == .showSettings, let openScene {
            openScene(Self.settingsSceneID)
            return true
        }
        guard let router = router(for: scene), command.isEnabled(in: router.context) else { return false }
        router.perform(command)
        return true
    }
}

extension UIWindow {
    /// A UIKit menu item of the app (`MacMenus.nativeItem`) chosen while this
    /// window is focused: the command named by its property list, run by the
    /// window's router. Every window is in the responder chain of what it shows.
    @objc func sempereMenuCommand(_ sender: UICommand) {
        guard let name = sender.propertyList as? String, let command = MenuCommand(rawValue: name) else { return }
        MenuRouting.shared.perform(command, in: windowScene)
    }
}

/// Publishes a window's `CommandRouter` to `MenuRouting` under the window's scene.
private struct MenuRouterPublisher: UIViewRepresentable {
    let router: CommandRouter

    final class Probe: UIView {
        var router: CommandRouter?
        private weak var scene: UIWindowScene?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publish()
        }

        func publish() {
            if let scene, scene !== window?.windowScene { MenuRouting.shared.set(nil, for: scene) }
            scene = window?.windowScene
            if let scene { MenuRouting.shared.set(router, for: scene) }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.isHidden = true
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.router = router
        probe.publish()
    }
}

/// Keeps the window's `openWindow` in `MenuRouting.openScene`.
private struct OpenScenePublisher: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let open = openWindow
            MenuRouting.shared.openScene = { id in open(id: id) }
        }
    }
}

extension View {
    /// Publishes `router` for the UIKit menu items of this window (Mac).
    func menuRouter(_ router: CommandRouter) -> some View {
        background(MenuRouterPublisher(router: router)).modifier(OpenScenePublisher())
    }
}

/// The app delegate (through `UIApplicationDelegateAdaptor`): only the Mac
/// menu bar needs it.
final class SempereAppDelegate: UIResponder, UIApplicationDelegate {
    /// Key commands of the menu bar as last built (tests).
    @MainActor static var lastShortcuts: [String] = []
    /// The menu bar as last built (tests).
    @MainActor static var lastTree: [String] = []
    /// The menu tree is logged once per launch (DEBUG).
    @MainActor private static var dumped = false

    /// A UIKit menu item of the app chosen with no window focused (the
    /// responder chain ends here): only Settings… runs without one.
    @objc func sempereMenuCommand(_ sender: UICommand) {
        guard let name = sender.propertyList as? String, let command = MenuCommand(rawValue: name) else { return }
        MenuRouting.shared.perform(command, in: nil)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main, Platform.isMac else { return }
        MacMenus.prune(builder)
        Self.lastShortcuts = MacMenus.shortcuts(in: builder)
        Self.lastTree = MacMenus.tree(builder)
        #if DEBUG
        if !Self.dumped {
            Self.dumped = true
            for line in Self.lastTree { print("SempereMenuTree \(line)") }
            print("SempereMenus \(MacMenus.built) shortcuts=\(Self.lastShortcuts.count)")
        }
        #endif
    }
}
