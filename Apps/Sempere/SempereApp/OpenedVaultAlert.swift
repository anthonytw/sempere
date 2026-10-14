import SwiftUI

/// Asks before a vault handed to the app from outside (AirDrop, Files, another
/// app) replaces the vault open in this window's model (security review
/// 2026-10 stage 4, S16): a lookalike folder must not close the user's vault
/// and take its place without a word. Attached by every window that handles
/// `onOpenURL` (the library window and note windows).
struct OpenedVaultAlert: ViewModifier {
    @AppModelEnvironment private var model
    @AppEnvironmentObject private var library: VaultLibrary
    @Binding var pending: AppModel.OpenedVaultConfirmation?

    func body(content: Content) -> some View {
        content.alert(Text("Open “\(pending?.name ?? "")”?"),
                      isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                      presenting: pending) { request in
            Button("Open") {
                pending = nil
                Task { await model.handleOpened(request.url, library: library, confirmed: true) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { request in
            Text("This closes “\(request.current)”. Open a vault you received only if you know where it came from.")
        }
    }
}

extension View {
    /// `OpenedVaultAlert` for `pending`.
    func openedVaultAlert(_ pending: Binding<AppModel.OpenedVaultConfirmation?>) -> some View {
        modifier(OpenedVaultAlert(pending: pending))
    }
}
