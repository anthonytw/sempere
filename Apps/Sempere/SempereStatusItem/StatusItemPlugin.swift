import AppKit

/// The Mac menu-bar item (docs/mac.md "Menu-bar item"). Mac Catalyst has no `NSStatusItem`, so this
/// small AppKit bundle is built for macOS, embedded in the app's `PlugIns` folder and loaded by the
/// Catalyst app at launch (`StatusItemHost`). It holds no logic and no strings: the app posts the
/// state and the titles (`StatusItemProtocol.updateName`), and this posts back which entry was chosen.
/// Both run in one process, so the two sides only share notifications on the default center.
@objc(SempereStatusItemPlugin)
final class StatusItemPlugin: NSObject {
    private var item: NSStatusItem?
    private var state = StatusItemProtocol.State()
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: StatusItemProtocol.updateName, object: nil, queue: .main) { [weak self] note in
            self?.apply(StatusItemProtocol.State(userInfo: note.userInfo))
        })
        observers.append(center.addObserver(forName: StatusItemProtocol.activateName, object: nil, queue: .main) { _ in
            NSApp.activate(ignoringOtherApps: true)
        })
        // The app answers with the current state.
        center.post(name: StatusItemProtocol.readyName, object: nil)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let item { NSStatusBar.system.removeStatusItem(item) }
    }

    private func apply(_ new: StatusItemProtocol.State) {
        state = new
        guard new.visible else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = self.item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        let name = new.recording ? "record.circle.fill" : "pencil.tip.crop.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: new.toolTip)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = new.toolTip
        item.button?.contentTintColor = new.recording ? NSColor.systemRed : nil
        item.menu = makeMenu(new)
    }

    private func makeMenu(_ s: StatusItemProtocol.State) -> NSMenu {
        let menu = NSMenu()
        // Off, or AppKit enables every item whose target answers its action and `isEnabled` is ignored.
        menu.autoenablesItems = false
        let voice = NSMenuItem(title: s.voiceTitle, action: #selector(voiceNote(_:)), keyEquivalent: "")
        voice.target = self
        voice.isEnabled = !s.busy
        menu.addItem(voice)
        let note = NSMenuItem(title: s.newNoteTitle, action: #selector(newNote(_:)), keyEquivalent: "")
        note.target = self
        menu.addItem(note)
        menu.addItem(.separator())
        let open = NSMenuItem(title: s.openTitle, action: #selector(openApp(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        return menu
    }

    @objc private func voiceNote(_ sender: Any?) { post(.voiceNote) }

    @objc private func newNote(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        post(.newNote)
    }

    @objc private func openApp(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        post(.openApp)
    }

    private func post(_ action: StatusItemProtocol.Action) {
        NotificationCenter.default.post(name: StatusItemProtocol.actionName, object: nil,
                                        userInfo: StatusItemProtocol.userInfo(for: action))
    }
}
