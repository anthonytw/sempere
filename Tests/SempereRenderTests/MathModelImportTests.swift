import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// Installing a model the user picked in Files: a folder, or a stored zip of
/// one (MathModelImport). Uses the tiny random fixture model.
final class MathModelImportTests: XCTestCase {
    func tinyFolder() throws -> URL { try T.fixtureURL("math-tiny") }

    func tempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A zip of `folder`'s files (and `extra` entries), every entry stored; `method` 8 marks them deflated (unsupported).
    func zip(of folder: URL, prefix: String = "", extra: [(String, Data)] = [], method: UInt16 = 0) throws -> URL {
        var items: [(String, Data)] = extra
        // Relative names are built while walking down from `folder`, never cut off an absolute path:
        // however the folder is reached (a copied package, /var and /private/var, a link in the path),
        // an entry's name is its path below the folder.
        func walk(_ relative: String) throws {
            let dir = relative.isEmpty ? folder : folder.appendingPathComponent(relative)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
                let rel = relative.isEmpty ? name : relative + "/" + name
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(rel).path, isDirectory: &isDir) else { continue }
                if isDir.boolValue { try walk(rel) } else {
                    items.append((prefix + rel, try Data(contentsOf: folder.appendingPathComponent(rel))))
                }
            }
        }
        try walk("")
        var body = Data(), directory = Data()
        func put16(_ d: inout Data, _ v: Int) { d.append(UInt8(v & 255)); d.append(UInt8(v >> 8 & 255)) }
        func put32(_ d: inout Data, _ v: Int) { put16(&d, v & 0xFFFF); put16(&d, v >> 16) }
        for (name, data) in items {
            let offset = body.count
            let n = Data(name.utf8)
            put32(&body, 0x0403_4b50); put16(&body, 20); put16(&body, 0); put16(&body, Int(method)); put16(&body, 0)
            put16(&body, 0); put32(&body, 0); put32(&body, data.count); put32(&body, data.count)
            put16(&body, n.count); put16(&body, 0); body += n; body += data
            put32(&directory, 0x0201_4b50); put16(&directory, 20); put16(&directory, 20); put16(&directory, 0)
            put16(&directory, Int(method)); put16(&directory, 0); put16(&directory, 0); put32(&directory, 0)
            put32(&directory, data.count); put32(&directory, data.count); put16(&directory, n.count)
            put16(&directory, 0); put16(&directory, 0); put16(&directory, 0); put16(&directory, 0)
            put32(&directory, 0); put32(&directory, offset); directory += n
        }
        var end = Data()
        put32(&end, 0x0605_4b50); put16(&end, 0); put16(&end, 0); put16(&end, items.count); put16(&end, items.count)
        put32(&end, directory.count); put32(&end, body.count); put16(&end, 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString).zip")
        try (body + directory + end).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAFolderInstallsAndIsListed() throws {
        let root = tempRoot()
        XCTAssertTrue(MathModelStore.installedModels(root: root).isEmpty)
        let model = try MathModelImport.install(from: tinyFolder(), root: root)
        let listed = MathModelStore.installedModels(root: root)
        XCTAssertEqual(listed, [model])
        XCTAssertEqual(model.manifestSHA256, FileDigest.sha256(try Data(contentsOf: tinyFolder().appendingPathComponent("manifest.json"))))
        XCTAssertGreaterThan(model.totalBytes, 0)
        // Again: replaces, still one.
        _ = try MathModelImport.install(from: tinyFolder(), root: root)
        XCTAssertEqual(MathModelStore.installedModels(root: root).count, 1)
        // A damaged copy is not listed.
        try Data("x".utf8).write(to: model.folder.appendingPathComponent("tokenizer.json"))
        XCTAssertTrue(MathModelStore.installedModels(root: root).isEmpty)
    }

    func testAZipInstallsWithOrWithoutAFolderAroundIt() throws {
        for prefix in ["", "math-tiny/"] {
            let root = tempRoot()
            let model = try MathModelImport.install(from: zip(of: tinyFolder(), prefix: prefix,
                                                             extra: [("__MACOSX/._manifest.json", Data("junk".utf8)), (prefix + "notes.txt", Data("x".utf8))]),
                                                    root: root)
            XCTAssertEqual(MathModelStore.installedModels(root: root), [model], "prefix \(prefix)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: model.folder.appendingPathComponent("notes.txt").path),
                           "only the manifest's files are installed")
        }
    }

    /// The test helper `zip(of:)` names entries relative to the folder also when the folder's path
    /// goes through a symbolic link (macOS's /var and /tmp; the enumerator returns resolved paths).
    func testZipHelperNamesEntriesThroughASymlinkedPath() throws {
        let base = tempRoot()
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: tinyFolder(), to: real.appendingPathComponent("math-tiny"))
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let root = tempRoot()
        let model = try MathModelImport.install(from: zip(of: link.appendingPathComponent("math-tiny"), prefix: "math-tiny/"),
                                                root: root)
        XCTAssertEqual(MathModelStore.installedModels(root: root), [model])
    }

    /// A zip pick that is a FIFO (or a device) is refused at once, as every reader of picked bytes does
    /// (`BoundedRead.openRegularFile`); opening it for reading would block until a writer appeared.
    func testANonRegularFileInPlaceOfAZipIsRefusedWithoutBlocking() throws {
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("fifo-\(UUID().uuidString).zip")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        addTeardownBlock { try? FileManager.default.removeItem(at: fifo) }
        let done = expectation(description: "install returned")
        let root = tempRoot()
        nonisolated(unsafe) var threw = false
        DispatchQueue.global().async {
            threw = (try? MathModelImport.install(from: fifo, root: root)) == nil
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(threw)
    }

    func testBadModelsAreRefusedAndLeaveNothingBehind() throws {
        let root = tempRoot()
        // Compressed entries are not supported.
        XCTAssertThrowsError(try MathModelImport.install(from: zip(of: tinyFolder(), method: 8), root: root))
        // Not a zip, an empty folder, a missing file, a changed file.
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).zip")
        try Data("not a zip".utf8).write(to: junk)
        addTeardownBlock { try? FileManager.default.removeItem(at: junk) }
        XCTAssertThrowsError(try MathModelImport.install(from: junk, root: root))
        XCTAssertThrowsError(try MathModelImport.install(from: FileManager.default.temporaryDirectory, root: root)) { error in
            XCTAssertEqual(error as? MathModelImport.Failure, .noManifest)
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: tinyFolder(), to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        let tokenizer = copy.appendingPathComponent("tokenizer.json")
        var data = try Data(contentsOf: tokenizer)
        data[data.startIndex] ^= 1
        try data.write(to: tokenizer)
        XCTAssertThrowsError(try MathModelImport.install(from: copy, root: root)) { error in
            XCTAssertEqual(error as? MathModelManifest.Failure, .mismatch("tokenizer.json"))
        }
        XCTAssertThrowsError(try MathModelImport.install(from: zip(of: copy), root: root))
        try FileManager.default.removeItem(at: tokenizer)
        XCTAssertThrowsError(try MathModelImport.install(from: copy, root: root)) { error in
            XCTAssertEqual(error as? MathModelImport.Failure, .missingEntry("tokenizer.json"))
        }
        XCTAssertThrowsError(try MathModelImport.install(from: zip(of: copy), root: root))
        XCTAssertTrue(MathModelStore.installedModels(root: root).isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(left.allSatisfy { !$0.hasPrefix(".staging") }, "staging is cleaned up: \(left)")
    }

    /// A picked folder whose files are symlinks (a Hugging Face cache snapshot
    /// links each file to a blob) installs copies of the files, never the links:
    /// a link would point outside the store, at a file that can change or, in
    /// a picked folder, stop being readable once the import's access ends.
    func testSymlinkedFilesAreCopiedNotLinked() throws {
        let fm = FileManager.default
        let copy = fm.temporaryDirectory.appendingPathComponent("linked-\(UUID().uuidString)")
        let blobs = fm.temporaryDirectory.appendingPathComponent("blobs-\(UUID().uuidString)")
        try fm.copyItem(at: tinyFolder(), to: copy)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy); try? FileManager.default.removeItem(at: blobs) }
        let tokenizer = copy.appendingPathComponent("tokenizer.json"), blob = blobs.appendingPathComponent("tokenizer")
        try fm.moveItem(at: tokenizer, to: blob)
        try fm.createSymbolicLink(at: tokenizer, withDestinationURL: blob)

        let root = tempRoot()
        let model = try MathModelImport.install(from: copy, root: root)
        let installed = model.folder.appendingPathComponent("tokenizer.json")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: installed.path), "a copy, not a link")
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: blob))
        XCTAssertEqual(MathModelStore.installedModels(root: root), [model])
    }

    /// Zip entry names never choose where anything is written: only the
    /// manifest's paths do, and a manifest path that leaves the model folder
    /// is refused before any file is extracted.
    func testZipEntriesCannotWriteOutsideTheStore() throws {
        let fm = FileManager.default
        let root = tempRoot()
        let outside = root.deletingLastPathComponent()
        let marker = "escape-\(UUID().uuidString).txt"
        let model = try MathModelImport.install(from: zip(of: tinyFolder(), extra: [
            ("../\(marker)", Data("x".utf8)), ("/tmp/\(marker)", Data("x".utf8)), ("a/../../\(marker)", Data("x".utf8)),
        ]), root: root)
        XCTAssertEqual(MathModelStore.installedModels(root: root), [model])
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent(marker).path))
        XCTAssertFalse(fm.fileExists(atPath: "/tmp/\(marker)"))

        // A manifest that lists a path outside its folder (or names its id so) is refused.
        let manifestURL = try tinyFolder().appendingPathComponent("manifest.json")
        let original = try String(contentsOf: manifestURL, encoding: .utf8)
        for (from, to) in [("\"tokenizer.json\"", "\"../\(marker)\""), ("\"tokenizer.json\"", "\"/tmp/\(marker)\""),
                           ("\"id\": \"", "\"id\": \"../")] {
            let hostile = original.replacingOccurrences(of: from, with: to)
            XCTAssertNotEqual(hostile, original, "the fixture manifest has \(from)")
            let copy = fm.temporaryDirectory.appendingPathComponent("hostile-\(UUID().uuidString)")
            try fm.copyItem(at: tinyFolder(), to: copy)
            addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
            try Data(hostile.utf8).write(to: copy.appendingPathComponent("manifest.json"))
            for source in [copy, try zip(of: copy)] {
                XCTAssertThrowsError(try MathModelImport.install(from: source, root: root)) { error in
                    guard case .malformed? = error as? MathModelManifest.Failure else { return XCTFail("\(error)") }
                }
            }
            XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent(marker).path))
        }
    }

    /// A zip entry whose size is not the manifest's is refused before it is
    /// extracted (a longer one could otherwise fill the disk), and nothing is installed.
    func testAZipEntryOfAnotherSizeIsRefused() throws {
        let fm = FileManager.default
        for delta in [-1, 1] {
            let copy = fm.temporaryDirectory.appendingPathComponent("size-\(UUID().uuidString)")
            try fm.copyItem(at: tinyFolder(), to: copy)
            addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
            let tokenizer = copy.appendingPathComponent("tokenizer.json")
            var data = try Data(contentsOf: tokenizer)
            if delta < 0 { data.removeLast() } else { data.append(0x20) }
            try data.write(to: tokenizer)
            let root = tempRoot()
            XCTAssertThrowsError(try MathModelImport.install(from: zip(of: copy), root: root)) { error in
                XCTAssertEqual(error as? MathModelManifest.Failure, .mismatch("tokenizer.json"), "delta \(delta)")
            }
            // From a folder the copy is verified: a shorter file is a mismatch, a longer one is too large.
            XCTAssertThrowsError(try MathModelImport.install(from: copy, root: root), "folder, delta \(delta)")
            XCTAssertTrue(MathModelStore.installedModels(root: root).isEmpty)
        }
    }

    #if os(macOS)
    /// The zip the maintainer is told to make: `zip -0 -r` (what Finder's Compress would deflate, so stored).
    func testAZipMadeByTheZipToolInstalls() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tool-\(UUID().uuidString).zip")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-0", "-r", "-q", out.path, "."]
        p.currentDirectoryURL = try tinyFolder()
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let root = tempRoot()
        let model = try MathModelImport.install(from: out, root: root)
        XCTAssertEqual(MathModelStore.installedModels(root: root), [model])
    }
    #endif
}
