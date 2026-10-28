import Sempere
import SempereRender
import SwiftUI
import UIKit
#if !targetEnvironment(macCatalyst)
import VisionKit
#endif

/// A QR code drawn from `SempereRender.QRCode` (no network, no system generator): crisp at any size.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let code = try? QRCode.encode(text: text, correction: .medium) {
            Canvas { context, size in
                let quiet = 4
                let n = code.size + 2 * quiet
                let cell = min(size.width, size.height) / CGFloat(n)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                for y in 0..<code.size {
                    for x in 0..<code.size where code[x, y] {
                        context.fill(Path(CGRect(x: CGFloat(x + quiet) * cell, y: CGFloat(y + quiet) * cell,
                                                 width: cell, height: cell)), with: .color(.black))
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 220)
            .accessibilityLabel(Text("QR code"))
        }
    }
}

/// Six words, large and numbered, for the other device to type.
struct SixWordsView: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                HStack(spacing: 6) {
                    Text(verbatim: "\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                    Text(verbatim: word).font(.title3.monospaced().bold())
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sixWords")
    }
}

/// Scans one QR code with the camera (VisionKit), on an iPhone or iPad; nothing on a Mac (VisionKit's scanner is
/// not in Mac Catalyst) or where the camera cannot scan: the six words are typed there.
struct QRScanButton: View {
    let found: (String) -> Void
    @State private var scanning = false

    static var available: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        #endif
    }

    var body: some View {
        #if !targetEnvironment(macCatalyst)
        if Self.available {
            Button("Scan QR Code…", systemImage: "qrcode.viewfinder") { scanning = true }
                .help("Scan the other device's code with the camera")
                .sheet(isPresented: $scanning) {
                    QRScanner { text in
                        scanning = false
                        found(text)
                    }
                    .ignoresSafeArea()
                }
        }
        #endif
    }
}

#if !targetEnvironment(macCatalyst)
/// The camera scanner, stopped at the first QR code it reads.
private struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in items {
                guard let text = code.payloadStringValue else { continue }
                done = true
                scanner.stopScanning()
                found(text)
                return
            }
        }
    }
}
#endif

/// Six words typed into one field: lowercased, split on spaces, commas and newlines.
enum TypedWords {
    static func split(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." })
            .map { $0.trimmingCharacters(in: CharacterSet.decimalDigits.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }
    }
}

/// Join This Device (design §6.2), on the new device: makes its keys and asks to join, shows its six words and
/// QR code for the device that manages devices, waits for the approval (each sync looks for it), then asks for
/// that device's six reply words (or its QR code), which confirm that this is the vault it approved.
struct JoinDeviceView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var keys: RememberedKeys
    let onCancel: () -> Void
    @State private var reply = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        Form {
            switch keys.joinStage {
            case nil:
                Section {
                    Text("This device makes its own key and asks to join “\(model.vaultName ?? "")”. On the device that manages devices, open Settings ▸ Sync & Devices ▸ Devices ▸ Add Device and type the six words shown next.",
                         comment: "Join screen; the value is the vault name")
                    Button("Ask to Join", systemImage: "person.badge.plus") { start() }
                        .accessibilityIdentifier("join.start")
                }
            case .waiting(let words, let qr)?:
                Section {
                    SixWordsView(words: words)
                    QRCodeView(text: qr).frame(maxWidth: .infinity)
                } header: {
                    Text("Type these on the device that manages devices")
                } footer: {
                    Text("Or scan the code there. Keep this screen open: the approval arrives with the next sync.")
                }
                Section {
                    HStack {
                        ProgressView()
                        Text("Waiting for the approval…")
                    }
                    // Where the request is on its way out (build 11: an iPad's request that iCloud Drive had not
                    // uploaded looked the same as one waiting on the other device).
                    Text(model.joinDelivery.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("join.delivery")
                    // A declined request looks like one approved and on its way (review of #124, note 2).
                    Text("If the other device declined this request, choose Cancel, then Ask to Join again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Check Now", systemImage: "arrow.clockwise") { Task { await checkNow() } }
                }
            case .confirming?:
                Section {
                    TextField("Six words", text: $reply, axis: .vertical)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("join.reply")
                    QRScanButton { text in confirm(qr: text) }
                    Button("Confirm", systemImage: "checkmark.seal") { confirm(qr: nil) }
                        .disabled(TypedWords.split(reply).count != 6)
                        .accessibilityIdentifier("join.confirm")
                } header: {
                    Text("Approved: type the six words the other device shows")
                } footer: {
                    Text("They prove this is the vault that device approved, not a copy someone else made.")
                }
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .navigationTitle("Join This Device")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { cancel() }
                    .help("Stop joining; this device's new key is deleted")
            }
        }
        .disabled(working)
        .task(id: keys.joinStage == nil ? 0 : 1) {
            // While waiting: the approval may arrive with any run, and runs are asked for more often than the
            // targets' idle pace (each `joinLookInterval`), so neither the request nor the approval waits for it.
            var lastDemand = ContinuousClock.now
            while !Task.isCancelled, case .waiting? = keys.joinStage {
                try? await Task.sleep(for: .seconds(3))
                if ContinuousClock.now - lastDemand >= model.joinLookInterval {
                    model.syncSessions.forEach { $0.demand() }
                    lastDemand = .now
                }
                await recheck()
            }
        }
    }

    private func start() {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                keys.joinStage = try await model.startJoin(store: keys.store)
                await keys.refresh(model)
            } catch { failure = DeviceChangeText.message(error) }
        }
    }

    private func checkNow() async {
        model.syncSessions.forEach { $0.demand() }
        await recheck()
    }

    private func recheck() async {
        await model.refreshLockedManifest()
        if case .keyProblem(let why) = await keys.unlockWithDeviceKey(model), why == RememberedKeys.expiredText {
            // Home deleted the request (second re-check of #88): this join is over; Ask to Join starts a new one.
            await model.cancelJoin(store: keys.store)
            try? await keys.forgetKeys(model)
            failure = Self.expiredText
        }
    }

    static let expiredText = String(localized: "The request to join expired: the device that manages devices deletes requests after 7 days. Ask to join again.")

    private func confirm(qr: String?) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                guard let id = model.vault?.vaultId else { return }
                let device = try await keys.store.keys(for: id, reason: String(localized: "Join “\(model.vaultName ?? "")”"))
                var words = TypedWords.split(reply)
                if let qr {
                    guard let w = model.replyWords(fromQR: qr, keys: device) else {
                        failure = String(localized: "That code is not this vault's approval.")
                        return
                    }
                    words = w
                }
                try await model.confirmJoin(words: words, keys: device)
                keys.joinStage = nil
            } catch VaultError.replyMismatch {
                failure = String(localized: "These are not the words of this vault's approval. Check them on the other device.")
            } catch { failure = DeviceChangeText.message(error) }
        }
    }

    private func cancel() {
        Task {
            if keys.joinStage != nil { await model.cancelJoin(store: keys.store) }
            keys.joinStage = nil
            await keys.refresh(model)
            onCancel()
        }
    }
}

/// Add Device (on home, design §6.2 steps 2 and 3): the six words typed from the new device (typing, not
/// comparing, so a near match is not waved through), or its code scanned; then the reply for it.
struct AddDeviceSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let done: (String) -> Void
    @State private var words = ""
    /// The look, the waiting words and the one approval (`AddDeviceApproval`, review of #117 B1).
    @State private var approval = AddDeviceApproval()
    /// The request whose Decline is being confirmed (review of #124, note 7: a mistap costs the other device a wait).
    @State private var declining: JoinRequest?
    @State private var addingTarget = false

    private var reply: JoinReply? { approval.reply }
    private var lookout: JoinRequestLookout? { approval.lookout }
    private var working: Bool { approval.working }
    private var failure: String? { approval.failure }

    var body: some View {
        NavigationStack {
            Form {
                if reply == nil, model.openVaultIsStored, model.openVaultTargets.isEmpty {
                    // No sync target: a new device has nothing to open and join through yet.
                    Section {
                        Text(AddDeviceText.noTarget)
                        Button("Add a Sync Target…", systemImage: "arrow.triangle.2.circlepath") { addingTarget = true }
                            .accessibilityIdentifier("addDevice.addTarget")
                    }
                }
                if let reply {
                    Section {
                        SixWordsView(words: reply.words)
                        QRCodeView(text: reply.qr).frame(maxWidth: .infinity)
                    } header: {
                        Text("Type these on “\(reply.deviceName)”", comment: "Add Device: the value is the new device's name")
                    } footer: {
                        Text("Or scan this code there. They prove to the new device that this is the vault it asked to join.")
                    }
                } else {
                    Section {
                        if let steps = AddDeviceText.instructions(targets: model.openVaultTargets) {
                            Text(steps)
                                .accessibilityIdentifier("addDevice.where")
                        }
                        Text("The new device then shows six words: type them here.")
                        if let lookout, !lookout.requests.isEmpty {
                            Text("Asked to join:", comment: "Add Device: above the list of waiting requests")
                                .foregroundStyle(.secondary)
                            // Each with Decline (build 12: "no way to decline a request"): one nobody will confirm
                            // goes, and never keeps another from being approved.
                            ForEach(lookout.requests, id: \.fileName) { request in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: DeviceName.display(request.name))
                                        Text(AddDeviceText.requestDetail(request))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Decline", role: .destructive) { declining = request }
                                        .buttonStyle(.borderless)
                                        .help("Delete this request: that device is not added")
                                        .accessibilityIdentifier("addDevice.decline")
                                }
                            }
                        } else if !model.openVaultTargets.isEmpty || !model.openVaultIsStored {
                            // Requests come through a sync target, and a provider (iCloud Drive) may take minutes: the
                            // sheet keeps looking, and says so, rather than "no device" once (build 11).
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(AddDeviceText.looking(lookout))
                                    if let checked = lookout?.checked {
                                        Text("Last checked \(checked.formatted(date: .omitted, time: .standard))",
                                             comment: "Add Device; the value is a time")
                                            .font(.footnote)
                                    }
                                }
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("addDevice.looking")
                        }
                    }
                    Section {
                        TextField("Six words", text: $words, axis: .vertical)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("addDevice.words")
                        QRScanButton { text in approve(qr: text) }
                        Button("Approve", systemImage: "checkmark.shield") { approve(qr: nil) }
                            .disabled(TypedWords.split(words).count != 6)
                            .accessibilityIdentifier("addDevice.approve")
                    } footer: {
                        Text("Approving gives the new device the vault's key. Approve only a device you hold.")
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add Device")
            .sheet(isPresented: $addingTarget) { SyncTargetsSheet() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(reply == nil ? String(localized: "Cancel") : String(localized: "Done")) {
                        approval.close()
                        if let reply { done(String(localized: "“\(reply.deviceName)” was added.", comment: "After an approval")) }
                        dismiss()
                    }
                    .help(reply == nil ? "Close without approving" : "Close")
                }
            }
            .disabled(working)
            .onChange(of: words) { approval.wordsChanged() }
            .task {
                // Keeps looking while the sheet waits for a request: a sync of every target, then the copy's
                // `joins/` (build 11: one look when the sheet opened missed a request iCloud delivered later). The
                // look itself re-checks after every wait that the sheet is still open and nothing is approving.
                approval.model = model
                while !Task.isCancelled, approval.active {
                    await approval.look()
                    try? await Task.sleep(for: model.joinLookInterval)
                }
            }
            .onDisappear { approval.close() }
            .confirmationDialog(Text("Decline “\(declining.map { DeviceName.display($0.name) } ?? "")”?",
                                     comment: "Add Device: confirm declining a join request; the value is the device's name"),
                                isPresented: Binding(get: { declining != nil }, set: { if !$0 { declining = nil } }),
                                titleVisibility: .visible, presenting: declining) { request in
                Button("Decline", role: .destructive) { Task { await approval.decline(request) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("That device is not added. To join, it cancels on its join screen and asks again.")
            }
        }
        // No swipe away while an approval is going: closing then could not stop what was already written.
        .interactiveDismissDisabled(working)
        .accessibilityIdentifier("addDeviceSheet")
    }

    private func approve(qr: String?) {
        approval.model = model
        let typed = qr == nil ? TypedWords.split(words) : nil
        Task { await approval.approve(words: typed, qr: qr) }
    }
}

/// Take Over with Recovery Kit (design §5.6 rule 3, §6.3): for a lost or stolen device that managed devices, or a
/// device joining with the kit. The kit's key (and, for a device that never opened the vault, its root) or the
/// passphrase; then a checkbox per device (the current list checked, devices a later change removed unchecked),
/// the changes the takeover undoes; then this device manages devices.
struct TakeoverView: View {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var keys: RememberedKeys
    let onDone: () -> Void
    @State private var keyText = ""
    @State private var rootText = ""
    @State private var passphrase = ""
    @State private var draft: TakeoverDraft?
    @State private var keep: Set<Data> = []
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        Form {
            if let draft {
                pick(draft)
            } else {
                Section {
                    SecureField("AGE-SECRET-KEY-PQ-1…", text: $keyText)
                        .font(.body.monospaced())
                        .accessibilityIdentifier("takeover.key")
                    TextField("Root fingerprint (16 groups)", text: $rootText, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    // The kit's two codes (design §6.3): the key's and the root's; each lands in its field.
                    QRScanButton { text in
                        switch Self.kitCode(text) {
                        case .root: rootText = text; failure = nil
                        case .key: keyText = text; failure = nil
                        case nil: failure = Self.notAKitCode
                        }
                    }
                } header: {
                    Text("The recovery kit")
                } footer: {
                    Text("Scan the kit's two codes, or type the key and the root printed under it. A device that has opened this vault before does not need the root.")
                }
                Section {
                    SecureField("Passphrase", text: $passphrase)
                } header: {
                    Text("Or the recovery key's passphrase")
                }
                Section {
                    Button("Continue", systemImage: "arrow.right") { plan() }
                        .disabled(keyText.isEmpty && passphrase.isEmpty)
                        .accessibilityIdentifier("takeover.continue")
                } footer: {
                    Text("The recovery key is used for this one signature and is not kept on this device.")
                }
            }
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .navigationTitle("Take Over")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    draft = nil
                    onDone()
                }.help("Close without taking over")
            }
        }
        .disabled(working)
        .accessibilityIdentifier("takeoverView")
    }

    @ViewBuilder private func pick(_ d: TakeoverDraft) -> some View {
        if !d.plan.dropped.isEmpty {
            Section {
                ForEach(d.plan.dropped, id: \.epoch) { e in
                    Text("Change \(e.epoch) (\(e.reason)) by \(model.rememberedDeviceNames(model.vault?.vaultId ?? UUID())[e.author] ?? e.author)",
                         comment: "Takeover: an epoch it drops; values are an epoch number, its reason and author")
                }
            } header: {
                Text("The takeover undoes")
            } footer: {
                Text("Changes made after this device's last checked list, for example by a stolen device that managed devices.")
            }
        }
        Section {
            ForEach(d.plan.candidates, id: \.fingerprint) { c in
                Toggle(isOn: Binding(get: { keep.contains(c.fingerprint) },
                                     set: { if $0 { keep.insert(c.fingerprint) } else { keep.remove(c.fingerprint) } })) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(verbatim: DeviceName.display(c.name))
                            Text(verbatim: c.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if !c.nameTrusted {
                            Text("Name not confirmed: the device that changed the list may have renamed it")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text(TakeoverView.status(c)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Keep these devices")
        } footer: {
            Text("Uncheck any device you no longer have. This device manages devices from now on; every unchecked device is removed.")
        }
        Section {
            Button("Take Over", systemImage: "key.viewfinder") { takeOver(d) }
                .accessibilityIdentifier("takeover.confirm")
        }
    }

    enum KitCode: Equatable { case key, root }

    /// Which of the recovery kit's two codes `text` is (re-check of #88): the key's (`AGE-SECRET-KEY-…`) or the
    /// root's (`sempere-root:…`); nil for any other code, which fills no field.
    static func kitCode(_ text: String) -> KitCode? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("sempere-root:") { return .root }
        if t.uppercased().hasPrefix("AGE-SECRET-KEY-") { return .key }
        return nil
    }

    static let notAKitCode = String(localized: "That code is not one of the recovery kit's. Scan the code next to the kit's key, or the one next to its root.")

    /// A candidate's line (review of #88, S6): on the current list, removed by a change this takeover undoes, or
    /// removed by an earlier change.
    static func status(_ c: Vault.TakeoverCandidate) -> String {
        if c.removedByDroppedEpoch { return String(localized: "Removed by a change this takeover undoes") }
        return c.listed ? String(localized: "On the current list") : String(localized: "Removed by an earlier change")
    }

    private func plan() {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                let (identity, root) = try await model.recoveryForTakeover(keyText: keyText.isEmpty ? nil : keyText,
                                                                           rootText: rootText, passphrase: passphrase)
                let d = try await model.planTakeover(recovery: identity, root: root, store: keys.store)
                keep = Set(d.plan.candidates.filter(\.checkedByDefault).map(\.fingerprint))
                draft = d
                keyText = ""; passphrase = ""
            } catch { failure = DeviceChangeText.message(error) }
        }
    }

    private func takeOver(_ d: TakeoverDraft) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                _ = try await model.takeOver(d, keep: keep, store: keys.store)
                draft = nil
                await keys.refresh(model)
                onDone()
            } catch {
                draft = nil   // the recovery key is not kept after a failure either
                failure = DeviceChangeText.message(error)
            }
        }
    }
}

/// Confirm Vault (demovault-mac, build 11): a device key opened the vault, and this device has no record of it and no
/// root to check its list against (a key file made with sempere elsewhere, such as the demo vault's), so it reads and
/// writes nothing. The root fingerprint from the vault's recovery kit (typed, or its code scanned) confirms it
/// (`AppModel.confirmVaultRoot`); the vault is writable from then on.
struct ConfirmVaultSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rootText = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Root fingerprint (16 groups)", text: $rootText, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("confirmVault.root")
                    QRScanButton { text in
                        if TakeoverView.kitCode(text) == .root { rootText = text; failure = nil } else { failure = TakeoverView.notAKitCode }
                    }
                    Button("Confirm", systemImage: "checkmark.shield") { confirm() }
                        .disabled(rootText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("confirmVault.confirm")
                } header: {
                    Text("Root fingerprint, from the recovery kit")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This device's key is on the vault's list, but this device has not checked that this vault is the one the key belongs to.")
                        Text(ListAlert.rootExplained)
                        Text("Without it the vault stays read-only here; joining from the device that manages devices, or taking over with the recovery kit, also lets this device write.")
                    }
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle("Confirm Vault")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .help("Close; the vault stays read-only")
                }
            }
            .disabled(working)
        }
        .accessibilityIdentifier("confirmVaultSheet")
    }

    private func confirm() {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await model.confirmVaultRoot(rootText)
                dismiss()
            } catch let e as DeviceJoinError {
                failure = e.description
            } catch VaultError.untrustedList(let problem) where problem.reason == .rootMismatch {
                failure = String(localized: "That root fingerprint is not this vault's. Check it against the vault's recovery kit.")
            } catch {
                failure = DeviceChangeText.message(error)
            }
        }
    }
}
