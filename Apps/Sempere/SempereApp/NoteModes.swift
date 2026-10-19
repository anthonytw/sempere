import Foundation

/// The kind of device the note view runs on. The note view's modes and toolbar differ by device only
/// where the device needs it (`NoteModeInput`, `NoteToolbar`), so the decisions take it as a value and
/// tests pin every device from any destination.
enum NoteDevice: Equatable, Sendable, CaseIterable {
    case phone, pad, mac

    /// This device: `Platform.isMac` (Mac Catalyst), `Platform.isPhone`, else an iPad.
    @MainActor
    static var current: NoteDevice { Platform.isMac ? .mac : Platform.isPhone ? .phone : .pad }
}

/// The note view's three modes, on every device (docs/iphone.md "The note view", docs/mac.md "Reading,
/// Hand and Annotate"), shown by the two top-bar buttons, the pencil ("Annotate") and the Hand. One value,
/// so a combination the buttons cannot show (the Hand lit with ink drawing, both lit) cannot exist
/// (TestFlight build 5 on the iPhone). Everything the canvas does follows from it (`NoteModeInput`).
///
/// | mode       | pencil | Hand | the canvas                                              | palette |
/// |------------|--------|------|---------------------------------------------------------|---------|
/// | reading    | off    | off  | scrolls; nothing draws or selects (an iPad's Pencil: below) | hidden  |
/// | hand       | off    | on   | scrolls; a tap or click selects, a drag moves the selected item | hidden  |
/// | annotating | on     | off  | draws                                                   | shown   |
///
/// A note opens in reading mode on every device. On an iPad a Pencil touch in reading or Hand mode
/// switches to annotating and draws: the stroke that started it is kept (`pencilTouched`).
enum NoteMode: String, Equatable, Sendable, CaseIterable {
    case reading, hand, annotating

    /// The top bar's two buttons.
    enum Button: Equatable, Sendable, CaseIterable {
        case annotate, hand

        var mode: NoteMode { self == .annotate ? .annotating : .hand }
    }

    /// A note opens in reading mode (and the next note does too).
    static let initial = NoteMode.reading

    /// A tap on `button`: the lit one goes back to reading, the other switches straight to its mode.
    func tapping(_ button: Button) -> NoteMode {
        self == button.mode ? .reading : button.mode
    }

    /// Whether `button` reads as on (lit).
    func lights(_ button: Button) -> Bool { self == button.mode }

    /// A Pencil touched the page (an iPad, `NoteModeInput.pencilAnnotates`): annotating, whatever the mode.
    func pencilTouched() -> NoteMode { .annotating }

    /// A tool was picked (a menu's Pen, Marker…, or Text): annotating.
    func toolPicked() -> NoteMode { .annotating }

    /// Selection mode: the Hand.
    var selectingItems: Bool { self == .hand }
    /// The drawing palette: only while annotating.
    var showsPalette: Bool { self == .annotating }

    /// A debug launch's mode for the notes it opens (`SEMPERE_DEBUG_NOTE_MODE`: reading, hand or
    /// annotating; "annotate" too), so UI tests written for drawing open the note ready to draw.
    static func debugInitial(_ value: String?) -> NoteMode? {
        guard let value = value?.lowercased() else { return nil }
        return value == "annotate" ? .annotating : NoteMode(rawValue: value)
    }
}

/// What the canvas does in a mode on a device: the one table the note view, the one-page canvas and the
/// paged stack read (`NoteMode`). Pure, so it is tested for every device on any destination.
///
/// | device | mode       | drawing | ink takes          | selects      | palette |
/// |--------|------------|---------|--------------------|--------------|---------|
/// | iPhone | reading    | off     | nothing            | no           | no      |
/// | iPhone | hand       | off     | nothing            | finger       | no      |
/// | iPhone | annotating | on      | a finger           | no           | yes     |
/// | iPad   | reading    | Pencil  | the Pencil (→ annotating) | no    | no      |
/// | iPad   | hand       | Pencil  | the Pencil (→ annotating) | finger | no      |
/// | iPad   | annotating | on      | as the system says (Pencil; a finger without one) | no | yes |
/// | Mac    | reading    | off     | nothing            | no           | no      |
/// | Mac    | hand       | off     | nothing            | click        | no      |
/// | Mac    | annotating | on      | the mouse          | no           | yes     |
struct NoteModeInput: Equatable, Sendable {
    /// Nothing draws: PencilKit's drawing, the object eraser and the pointer ink are off, and the canvas
    /// does not take the focus by itself (the iPhone and the Mac while reading).
    var drawingSuspended = false
    /// Only a Pencil draws, and its first touch switches the note to annotating (an iPad, reading or Hand):
    /// PencilKit's drawing stays on with the policy `.pencilOnly`, so the stroke that started is kept.
    var pencilAnnotates = false
    /// Selection mode (the Hand): taps, clicks and drags select and move items.
    var selectingItems = false
    /// The palette is up.
    var showsPalette = false
    /// No tap writes: the button below the last page (Add Page) is hidden.
    var reading = false
    /// A finger is ink on an iPhone (its drawing policy `.anyInput`; scrolling then takes two fingers).
    var fingersDraw = false

    static func of(_ mode: NoteMode, on device: NoteDevice) -> NoteModeInput {
        var input = NoteModeInput()
        input.selectingItems = mode.selectingItems
        input.showsPalette = mode.showsPalette
        input.reading = mode == .reading
        switch device {
        case .pad:
            input.pencilAnnotates = mode != .annotating
        case .phone, .mac:
            input.drawingSuspended = mode == .reading
            input.fingersDraw = device == .phone && mode == .annotating
        }
        return input
    }
}
