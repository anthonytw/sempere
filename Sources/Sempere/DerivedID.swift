import Crypto
import Foundation

extension UUID {
    /// A name-based UUID: the first 16 bytes of SHA-256(`name`) with the
    /// RFC 9562 version set to 8 (custom, here "name-based with SHA-256") and
    /// the variant to `10`. The same name always gives the same id, so an
    /// importer that derives ids from a source document's own identifiers
    /// re-imports idempotently.
    public static func derived(from name: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x80
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
