import Sempere
import UIKit

/// Two buttons next to the selected item on the iPad: the item's menu (the
/// same entries as a held finger's, `ItemMenu`) and Delete (TestFlight 1.0.0:
/// "no obvious way to delete an item"). Real buttons in the canvas, like the
/// audio cards' (`AudioCardControls`), so a finger, the Pencil, the keyboard
/// and VoiceOver reach them; the menu is a button menu, which the system
/// dismisses on a tap elsewhere. Placed above the item (below it when there
/// is no room above), clear of its handles; hidden on a Mac, where the
/// secondary click, the Note menu and the Delete key do the same.
@MainActor
final class ItemSelectionBar: UIView {
    let menuButton = UIButton(type: .system)
    let deleteButton = UIButton(type: .system)
    private let stack = UIStackView()
    /// Builds the menu when it opens (the item may have changed since it was selected).
    var menuElements: () -> [UIMenuElement] = { [] }
    var onDelete: () -> Void = {}

    /// Height of the bar, and the gap between it and the item's outline, screen points.
    static let height: CGFloat = 40
    static let gap = CGFloat(ItemSelectionModel.handleRadius) + 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = Self.height / 2
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
        overrideUserInterfaceStyle = .light   // it sits on light paper
        accessibilityIdentifier = "itemSelectionBar"
        isHidden = true

        menuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        menuButton.accessibilityIdentifier = "itemMenuButton"
        menuButton.accessibilityLabel = String(localized: "Item Actions", comment: "Button next to a selected item on the page: opens its menu (copy, duplicate, rotate, delete…)")
        menuButton.toolTip = menuButton.accessibilityLabel
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuElements() ?? [])
        }])

        deleteButton.setImage(UIImage(systemName: "trash"), for: .normal)
        deleteButton.tintColor = .systemRed
        deleteButton.accessibilityIdentifier = "itemDeleteButton"
        deleteButton.accessibilityLabel = String(localized: "Delete Item")
        deleteButton.toolTip = deleteButton.accessibilityLabel
        deleteButton.addAction(UIAction { [weak self] _ in self?.onDelete() }, for: .primaryActionTriggered)

        stack.axis = .horizontal
        stack.spacing = 4
        stack.addArrangedSubview(menuButton)
        stack.addArrangedSubview(deleteButton)
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The bar's width for the buttons it shows.
    var width: CGFloat { deleteButton.isHidden ? Self.height : Self.height * 2 + 4 }

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.frame = bounds.insetBy(dx: 4, dy: 0)
    }

    /// Shows the bar for `rect` (the selected item's bounds, canvas content
    /// coordinates) inside `content` (the canvas's content size); nil hides it.
    /// `canDelete` false (a read-only note) shows the menu button alone.
    func show(around rect: CGRect?, in content: CGSize, canDelete: Bool) {
        guard let rect, rect.width.isFinite, rect.height.isFinite else { isHidden = true; return }
        deleteButton.isHidden = !canDelete
        let frame = Self.frame(around: rect, width: width, in: content)
        if !PageStackHost.sameFrame(self.frame, frame) { self.frame = frame }
        isHidden = false
    }

    /// Where the bar goes for an item at `rect` (pure, tested): centered above
    /// it, clear of its handles; below it when there is no room above; inside
    /// its top edge when there is room neither above nor below (an item as
    /// tall as the page); always within the content's width.
    static func frame(around rect: CGRect, width: CGFloat, in content: CGSize) -> CGRect {
        let h = height
        var y = rect.minY - gap - h
        if y < 0 {
            y = rect.maxY + gap
            if y + h > content.height { y = max(rect.minY + gap, 0) }
        }
        let x = min(max(rect.midX - width / 2, 0), max(content.width - width, 0))
        return CGRect(x: x, y: y, width: width, height: h)
    }
}
