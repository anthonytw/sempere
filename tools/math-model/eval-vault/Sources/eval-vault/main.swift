import Age
import Foundation
import Sempere

// usage: eval-vault SAMPLES.jsonl VAULT_DIR KEY_FILE
// SAMPLES.jsonl: one {"id": "...", "strokes": [[[x, y, t_ms], ...], ...]} per line. One note per sample, titled by id.
let args = CommandLine.arguments
guard args.count == 4 else { FileHandle.standardError.write(Data("usage: eval-vault SAMPLES.jsonl VAULT KEYFILE\n".utf8)); exit(2) }
let identity = try NativeIdentity.generate(.postQuantum)
try IdentityFile.render(identity, created: Date()).write(toFile: args[3], atomically: true, encoding: .utf8)
let vault = try Vault.create(at: URL(fileURLWithPath: args[2]), recipients: [identity.recipient], labels: ["eval"], identities: [identity])
let device = DeviceID("abcdef01")!
var seq = 0
for line in try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n") {
    guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let id = obj["id"] as? String, let strokes = obj["strokes"] as? [[[Double]]] else { continue }
    let note = UUID(), page = UUID()
    var ops: [Op] = [.addPage(Page(id: page, order: "a0")), .setMeta(.title(id))]
    for s in strokes {
        let t0 = s.first?[2] ?? 0
        let pts = s.map { StrokePoint(x: $0[0], y: $0[1], t: ($0[2] - t0) / 1000, w: 2.5, h: 2.5) }
        if !pts.isEmpty { ops.append(.addStroke(page: page, stroke: Stroke(ink: Ink(tool: .pen, color: .black, width: 2.5), points: pts))) }
    }
    seq += 1
    try vault.write(Revision(noteId: note, device: device, seq: 1, hlc: HLC(millis: 1_760_000_000_000 + Int64(seq), counter: 0)!,
                             wall: Date(timeIntervalSince1970: 1_760_000_000 + Double(seq)), app: "eval-vault/1", body: .delta(ops: ops)))
}
print("wrote \(seq) notes")
