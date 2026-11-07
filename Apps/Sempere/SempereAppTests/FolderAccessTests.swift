import Foundation
import Testing
@testable import SempereApp
import SempereAppCore

/// Saved folder access in the app's words. What counts as "the system refused" and the check that runs before a
/// vault opens (`FolderAccess`, SempereAppCore): `VaultLibraryTests` on Linux.
struct FolderAccessTests {
    @Test func theMessageNamesTheFolderAndTheWayOut() {
        let text = FolderAccess.Problem.noAccess(name: "Notes", scoped: false).description
        #expect(text.contains("“Notes”"))
        #expect(text.contains("choose"))
        #expect(!FolderAccess.Problem.noAccess(name: "Notes", scoped: true).description.contains("did not come back"))
    }
}
