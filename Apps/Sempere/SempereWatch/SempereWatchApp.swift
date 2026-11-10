import SwiftUI
import WidgetKit
import SempereCaptureShared

/// The watch app (docs/design/1.1-watch.md): one screen over `WatchModel`. A launch from a surface (a widget's link, the
/// intent, Siri) records at once; one from the app grid shows the large Record button.
@main
struct SempereWatchApp: App {
    @State private var model: WatchModel?
    @State private var startupProblem: String?
    @Environment(\.scenePhase) private var scenePhase
    private let client = WatchConnectivityClient()

    init() {
        let environment = WatchLaunch.environment(transport: client)
        do {
            let model = try WatchModel(environment: environment)
            client.attach(model)
            _model = State(initialValue: model)
            WatchActions.record = { model.startFromSurface() }
            WatchActions.stop = { await model.stop() }
            // A start that arrived before the hook was set (a cold launch from a surface).
            if WatchActions.pendingRecord {
                WatchActions.pendingRecord = false
                model.startFromSurface()
            }
        } catch {
            _startupProblem = State(initialValue: "\(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                WatchContentView(model: model)
                    .onOpenURL { model.open(url: $0) }
                    .task { await model.activate() }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { Task { await model.activate() } }
                    }
            } else {
                VStack(spacing: 6) {
                    Text("Sempere can't open its storage on this watch.").font(.footnote).multilineTextAlignment(.center)
                    if let startupProblem { Text(startupProblem).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// What the app is made of on a real watch; a debug launch swaps parts (`WatchDebugLaunch`).
enum WatchLaunch {
    @MainActor
    static func environment(transport: WatchConnectivityClient) -> WatchEnvironment {
        #if DEBUG
        if let debug = WatchDebugLaunch.environment() { return debug }
        #endif
        return WatchEnvironment(secrets: KeychainWatchSecretStore(), audio: WatchCaptureAudio(), transport: transport,
                                support: WatchStorage.support, statusStore: .shared,
                                reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() })
    }
}
