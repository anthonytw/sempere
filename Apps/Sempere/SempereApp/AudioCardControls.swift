import Sempere
import UIKit

/// The recording loaded in a note's player and whether it plays: the button
/// of its cards shows pause then.
struct AudioPlayState: Hashable {
    var recording: UUID
    var isPlaying: Bool
}

/// The play/pause buttons of a page's audio cards (format.md §8.2.9): one
/// real button per card, a subview of the canvas like the page footer's, so
/// a click, a tap (finger or Pencil), the keyboard and VoiceOver all reach
/// it. It sits over the lower right of the card's microphone icon
/// (`AudioCard.badge`), turned with the item, and shows pause while the
/// card's recording plays. Hidden in selection mode and while a card is
/// edited; no button for a card whose recording is missing.
@MainActor
final class AudioCardControls {
    private weak var canvas: UIScrollView?
    private var buttons: [UUID: AudioCardButton] = [:]
    private var toggle: (@MainActor (UUID) -> Void)?

    func attach(to canvas: UIScrollView) {
        self.canvas = canvas
    }

    /// Places a button on every audio card of `items` (frames as shown) whose
    /// recording is in `recordings`; `toggle` nil hides them all.
    func layout(_ items: [Item], recordings: [Recording], playing: AudioPlayState?, zoom: CGFloat, hidden: UUID?,
                toggle: (@MainActor (UUID) -> Void)?) {
        self.toggle = toggle
        let state = NoteState(meta: NoteMeta(created: Date(timeIntervalSince1970: 0)), pages: [], recordings: recordings)
        var keep: Set<UUID> = []
        if toggle != nil, let canvas {
            // A frame that overflows would put the button at NaN, which Core Animation raises on (format.md §9).
            for item in items where item.kind == .audio && item.id != hidden
                && ItemFrames.isDrawable(item.frame, rotation: item.rotation) {
                guard let recording = state.recording(shownBy: item) else { continue }
                let control = AudioCard(frame: item.frame).badge(rotation: item.rotation)
                guard control.diameter > 0 else { continue }
                keep.insert(item.id)
                let button = buttons[item.id] ?? makeButton(for: item.id, in: canvas)
                button.recording = recording.id
                button.title = AudioCard.title(recording)
                button.isPlaying = playing.map { $0.recording == recording.id && $0.isPlaying } ?? false
                let side = control.diameter * Double(zoom)
                button.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                button.center = CGPoint(x: control.center.x * Double(zoom), y: control.center.y * Double(zoom))
                button.transform = CGAffineTransform(rotationAngle: CGFloat(ItemFrames.radians(item.rotation)))
                // The whole icon is the target: the icon's radius around the button, at least 22 points on screen.
                button.touchSlop = max(22 - side / 2, AudioCard(frame: item.frame).iconSize * 0.7 * Double(zoom) - side / 2, 0)
                canvas.bringSubviewToFront(button)
            }
        }
        for (id, button) in buttons where !keep.contains(id) {
            button.removeFromSuperview()
            buttons[id] = nil
        }
    }

    private func makeButton(for id: UUID, in canvas: UIScrollView) -> AudioCardButton {
        let button = AudioCardButton()
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let recording = button?.recording else { return }
            self.toggle?(recording)
        }, for: .primaryActionTriggered)
        canvas.addSubview(button)
        buttons[id] = button
        return button
    }

    /// The buttons on the page, by item id (tests).
    var shownButtons: [UUID: AudioCardButton] { buttons }
}

/// A card's play/pause button: a white disc with the blue glyph.
final class AudioCardButton: UIButton {
    var recording: UUID?
    /// Extra points around the disc that still hit it.
    var touchSlop: Double = 0
    var title = "" {
        didSet { updateLabel() }
    }
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            updateGlyph()
            updateLabel()
        }
    }

    private static let blue = UIColor(red: 0x1A / 255, green: 0x73 / 255, blue: 0xE8 / 255, alpha: 1)
    private let glyph = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        layer.borderColor = Self.blue.cgColor
        glyph.contentMode = .scaleAspectFit
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
        accessibilityIdentifier = "audioCardButton"
        if Platform.isMac { isPointerInteractionEnabled = true }
        updateGlyph()
        updateLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        layer.borderWidth = max(1, bounds.width / 14)
        let inset = bounds.width * 0.28
        // The play triangle looks centred a little right of the middle.
        glyph.frame = bounds.inset(by: UIEdgeInsets(top: inset, left: inset * (isPlaying ? 1 : 1.1), bottom: inset,
                                                    right: inset * (isPlaying ? 1 : 0.9)))
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -touchSlop, dy: -touchSlop).contains(point)
    }

    private func updateGlyph() {
        let config = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        glyph.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill", withConfiguration: config)?
            .withTintColor(Self.blue, renderingMode: .alwaysOriginal)
        setNeedsLayout()
    }

    private func updateLabel() {
        accessibilityLabel = isPlaying ? String(localized: "Pause \(title)", comment: "Audio card button: pause the recording named") : String(localized: "Play \(title)", comment: "Audio card button: play the recording named")
        toolTip = accessibilityLabel
    }
}
