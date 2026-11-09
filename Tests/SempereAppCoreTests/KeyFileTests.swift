import Age
import Foundation
import Sempere
@testable import SempereAppCore
import Testing

/// The key file a new vault's recovery key leaves the app in (`KeyFile`, moved from the app with wave 6 follow-up F1).
struct KeyFileTests {
    @Test func theTextIsTheIdentityFileTheCLIWrites() throws {
        let identity = try NativeIdentity.generate(.postQuantum)
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let file = KeyFile(identity: identity, label: "Recovery key of Notes", created: created)
        #expect(file.secret == identity.string)
        #expect(file.recipient == identity.recipient.string)
        #expect(file.text == IdentityFile.render(identity, created: created))
        #expect(file.text.contains(file.secret) && file.text.contains(file.recipient))
        // It reads back as the same key.
        #expect(try IdentityFile.parse(file.text).recipient.string == file.recipient)
        #expect(file.fileName == IdentityFile.exportFileName(label: "Recovery key of Notes"))
        #expect(file.fileName.hasPrefix("Sempere key - ") && file.fileName.hasSuffix(".txt"))
    }
}
