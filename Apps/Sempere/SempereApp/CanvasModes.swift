import Foundation

/// What a touch on the canvas does, besides the palette's own tool: draw (the
/// palette's tool), select items (the toolbar's Select), or place a text box
/// (the toolbar's Text, Insert > Text Box). Pure, tested (`CanvasModesTests`).
///
/// The text tool is one-shot (TestFlight 1.0.0: it stayed armed after a box
/// was placed, so the next tap, even on a video, made another box): once it
/// has placed one box the canvas goes back to the mode it was in before, the
/// palette's tool or selection mode. Editing an existing box does not end it.
struct CanvasModes: Equatable {
    enum Mode: Equatable {
        case drawing, selecting, addingText
    }

    private(set) var mode = Mode.drawing
    /// Where a one-shot tool goes back to once it has placed its item.
    private(set) var returnTo = Mode.drawing

    /// Selection mode is on (the Select toggle).
    var selectingItems: Bool {
        get { mode == .selecting }
        set { set(.selecting, on: newValue) }
    }

    /// The text tool is armed (the Text toggle).
    var addingText: Bool {
        get { mode == .addingText }
        set { set(.addingText, on: newValue) }
    }

    /// Turns `m` on (the other modes off) or off (back to drawing). Arming the
    /// text tool remembers the mode it came from.
    mutating func set(_ m: Mode, on: Bool) {
        if on {
            guard mode != m else { return }
            if m == .addingText { returnTo = mode == .selecting ? .selecting : .drawing }
            mode = m
        } else if mode == m {
            mode = .drawing
            returnTo = .drawing
        }
    }

    /// The text tool placed a new box: back to the mode before it.
    mutating func placedItem() {
        guard mode == .addingText else { return }
        mode = returnTo
        returnTo = .drawing
    }

    /// How the text tool ended from the canvas.
    enum TextToolEnd: Equatable {
        /// A tool was picked in the palette: drawing.
        case toolPicked
        /// It placed a box (one-shot): back to the mode before it.
        case placed
    }

    mutating func textToolEnded(_ end: TextToolEnd) {
        switch end {
        case .toolPicked: if mode == .addingText { reset() }
        case .placed: placedItem()
        }
    }

    /// A tool was picked in the palette, or the note changed: drawing.
    mutating func reset() {
        mode = .drawing
        returnTo = .drawing
    }
}
