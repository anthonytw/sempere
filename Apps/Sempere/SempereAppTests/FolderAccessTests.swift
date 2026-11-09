import Foundation
import Testing
@testable import SempereApp
import SempereAppCore

/// Saved folder access in the app's words. What counts as "the system refused" and the check that runs before a
/// vault opens (`FolderAccess`, SempereAppCore): `VaultLibraryTests` on Linux.
struct FolderAccessTests {
    @Test func theMessageNamesTheFolderAndTheWayOut() {
        let text = AppModel.describe(FolderAccess.Problem.noAccess(name: "Notes", scoped: false))
        #expect(text.contains("“Notes”"))
        #expect(text.contains("choose"))
        #expect(!AppModel.describe(FolderAccess.Problem.noAccess(name: "Notes", scoped: true)).contains("did not come back"))
    }
}
