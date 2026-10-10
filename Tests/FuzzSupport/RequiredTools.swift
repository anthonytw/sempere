import Foundation

/// Which external tools CI insists on. A test that needs `zbarimg`, `zip`,
/// `pdftotext` or the system `BidiTest.txt` skips when it is missing locally;
/// with `SEMPERE_REQUIRE_TOOLS` set (a comma-separated list of `zbar`, `zip`,
/// `pdftotext`, `bidi`, or `all`) a missing tool fails the test instead, so a
/// broken CI install cannot turn into silently skipped coverage.
public enum RequiredTools {
    public static func isRequired(_ tool: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let list = environment["SEMPERE_REQUIRE_TOOLS"] else { return false }
        let names = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return names.contains("all") || names.contains(tool)
    }
}
