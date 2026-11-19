import CoreSpotlight
import SempereAppCore
import SwiftUI

/// A Spotlight result opened: the system hands the app an `NSUserActivity` of type `CSSearchableItemActionType` whose
/// `CSSearchableItemActivityIdentifier` is `<vaultId>/<noteId>`; it becomes a `NoteLink` (docs/design/1.3-spotlight.md
/// §3.5). Used on the library window and the note windows, next to `.onOpenURL`.
struct SpotlightActivityModifier: ViewModifier {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary

    func body(content: Content) -> some View {
        content.onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let link = NoteLink(spotlightIdentifier: id) else { return }
            Task { await model.openNoteLink(link, library: library) }
        }
    }
}

extension View {
    func spotlightActivity() -> some View { modifier(SpotlightActivityModifier()) }
}
