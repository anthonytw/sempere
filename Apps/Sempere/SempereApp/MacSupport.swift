import Foundation
import UIKit

/// Where the app is running. The Mac behaviour (menus, windows, pointer input)
/// is gated on this at run time, or on `#if targetEnvironment(macCatalyst)`
/// where the code only builds there, so the iPad is unchanged.
enum Platform {
    /// True for the Mac Catalyst build.
    static var isMac: Bool { ProcessInfo.processInfo.isMacCatalystApp }
    /// True on an iPhone: the reader layouts (`PhoneLayout.swift`) apply. Never true on an iPad or a Mac.
    @MainActor static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
}

/// Zoom steps of the canvas, relative to the fitted page width (1 = the page
/// fills the window; the canvas allows `1 ... maxFactor`).
enum ZoomSteps {
    static let maxFactor = 4.0
    /// The factors Zoom In and Zoom Out move between.
    static let factors: [Double] = [1, 1.25, 1.5, 2, 2.5, 3, 4]

    /// The scale after one step from `current`, in canvas zoom scale units.
    /// Zoom in goes to the next factor above `current`, zoom out to the next
    /// one below; the result stays within `fit ... fit * maxFactor`.
    /// Non-finite or non-positive input gives `fit`.
    static func step(from current: Double, fit: Double, zoomingIn: Bool) -> Double {
        guard fit.isFinite, fit > 0 else { return 1 }
        guard current.isFinite, current > 0 else { return fit }
        let factor = current / fit
        let epsilon = 1e-6
        let next: Double
        if zoomingIn {
            next = factors.first { $0 > factor + epsilon } ?? factors[factors.count - 1]
        } else {
            next = factors.last { $0 < factor - epsilon } ?? factors[0]
        }
        return clamped(next * fit, fit: fit)
    }

    /// 100%: one page point per screen point, within the allowed range.
    static func actualSize(fit: Double) -> Double {
        guard fit.isFinite, fit > 0 else { return 1 }
        return clamped(1, fit: fit)
    }

    static func clamped(_ scale: Double, fit: Double) -> Double {
        guard scale.isFinite else { return fit }
        return min(max(scale, fit), fit * maxFactor)
    }
}

/// The pointer shown over the canvas with a mouse or trackpad.
enum PointerCursor {
    /// Smallest and largest diameter, screen points.
    static let range: ClosedRange<Double> = 6...64

    /// Diameter of the circle that shows where an ink tool of `toolWidth`
    /// (page points) draws at `zoom`; never smaller than a visible dot or
    /// larger than a reasonable cursor.
    static func diameter(toolWidth: Double, zoom: Double) -> Double {
        guard toolWidth.isFinite, zoom.isFinite, toolWidth > 0, zoom > 0 else { return range.lowerBound }
        return min(max(toolWidth * zoom, range.lowerBound), range.upperBound)
    }
}

/// What a window of one note is opened with. It is `Codable`, so SwiftUI saves
/// the windows that were open and opens them again at the next launch (state
/// restoration); the vault is named by its id (`vault.json`), not by a path, so
/// no location is stored.
struct NoteWindowValue: Codable, Hashable, Sendable {
    /// `WindowGroup` id of the note windows.
    static let sceneID = "note"
    var vaultID: UUID
    var noteID: UUID
}

/// The library window's selection, saved with the scene (`@SceneStorage`) and
/// applied once the vault is unlocked again.
struct RestorableSelection: Codable, Equatable, Sendable {
    /// `all`, `deleted`, `favorites`, `recognized`, `notebook:<path>` or `tag:<name>`.
    var sidebar: String
    var note: UUID?
    /// The vault the selection belongs to.
    var vault: UUID?

    static let key = "Sempere.selection"

    var sidebarItem: SidebarItem {
        if sidebar == "deleted" { return .deleted }
        if sidebar == "recognized" { return .recentlyRecognized }
        if sidebar == "favorites" { return .favorites }
        if sidebar.hasPrefix("notebook:") { return .notebook(String(sidebar.dropFirst("notebook:".count))) }
        if sidebar.hasPrefix("tag:") { return .tag(String(sidebar.dropFirst("tag:".count))) }
        return .allNotes
    }

    static func name(of item: SidebarItem?) -> String {
        switch item ?? .allNotes {
        case .allNotes: return "all"
        case .recentlyRecognized: return "recognized"
        case .favorites: return "favorites"
        case .deleted: return "deleted"
        case .notebook(let path): return "notebook:" + path
        case .tag(let tag): return "tag:" + tag
        }
    }

    init(sidebar: SidebarItem?, note: UUID?, vault: UUID?) {
        self.sidebar = Self.name(of: sidebar)
        self.note = note
        self.vault = vault
    }

    /// Decodes a stored string; anything unreadable is "no selection".
    init?(stored: String) {
        guard let data = stored.data(using: .utf8),
              let value = try? JSONDecoder().decode(RestorableSelection.self, from: data) else { return nil }
        self = value
    }

    var stored: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// File names for exported notes (drag to Finder).
enum ExportFileName {
    /// The longest base name in bytes (file systems allow 255 for the whole name).
    static let maxBytes = 120

    /// `title` as a safe `.pdf` file name: no path separators, colons or
    /// control characters, no leading dot, bounded length, "Untitled" when
    /// nothing is left.
    static func pdf(title: String) -> String {
        var cleaned = ""
        for scalar in title.unicodeScalars {
            switch scalar {
            case "/", ":", "\\", "\0": cleaned.unicodeScalars.append(" ")
            default:
                if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                    cleaned.unicodeScalars.append(" ")
                } else {
                    cleaned.unicodeScalars.append(scalar)
                }
            }
        }
        var words = cleaned.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        while let first = words.first, first == "." || first == " " { words.removeFirst() }
        var base = ""
        for character in words {
            if base.utf8.count + String(character).utf8.count > maxBytes { break }
            base.append(character)
        }
        base = base.trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "Untitled" : base) + ".pdf"
    }
}
