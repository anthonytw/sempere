import Age
import Foundation
import Sempere

/// A secret key on its way out of the app (a new vault's recovery key, shown
/// once): the `age-keygen` style text `sempere vault init --recovery-out`
/// writes (`IdentityFile.render`), the name to suggest, and what the recovery
/// kit needs. It lives in a view's state while the sheet is up and nowhere else.
public struct KeyFile: Sendable, Equatable {
    /// The `AGE-SECRET-KEY-PQ-1…` line.
    public var secret: String
    /// The `age1pq1…` recipient.
    public var recipient: String
    /// What the key is, for file names ("Recovery key of Notes").
    public var label: String
    /// The file's text: `# created`, `# public key`, the secret line.
    public var text: String

    public init(identity: NativeIdentity, label: String, created: Date = Date()) {
        secret = identity.string
        recipient = identity.recipient.string
        self.label = label
        text = IdentityFile.render(identity, created: created)
    }

    /// `Sempere key - <label>.txt`.
    public var fileName: String { IdentityFile.exportFileName(label: label) }
}
