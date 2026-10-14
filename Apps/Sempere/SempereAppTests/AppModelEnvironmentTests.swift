import Foundation
import SwiftUI
import Testing
import UIKit
@testable import SempereApp

/// Which model `@AppModelEnvironment` handed a view, and how often its body ran.
@MainActor
final class ModelProbeLog {
    var models: [ObjectIdentifier] = []
    var bodies = 0
}

/// A view that reads its model through `@AppModelEnvironment` and an
/// observed property of it (`errorMessage`).
private struct ModelProbe: View {
    @AppModelEnvironment private var model
    let log: ModelProbeLog

    var body: some View {
        log.models.append(ObjectIdentifier(model))
        log.bodies += 1
        return Text(model.errorMessage ?? "none")
    }
}

/// A view that reads the remembered keys through `@AppEnvironmentObject`.
private struct KeysProbe: View {
    @AppEnvironmentObject private var keys: RememberedKeys
    let log: ModelProbeLog

    var body: some View {
        log.models.append(ObjectIdentifier(keys))
        log.bodies += 1
        return Text("keys")
    }
}

/// `AppModelEnvironment` (the Mac launch crash, "No Observable object of type
/// AppModel found"): an injected model wins, a view without one gets
/// `AppModel.current` and is counted, and changes to the model still update
/// the view through the wrapper.
@MainActor
@Suite(.serialized)
struct AppModelEnvironmentTests {
    static func host<V: View>(_ view: V) -> (UIWindow, UIHostingController<V>) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    @Test func anInjectedModelWinsOverTheAppsModel() {
        let fallbacks = AppModelEnvironment.fallbacks
        let injected = AppModel()
        let log = ModelProbeLog()
        let (window, _) = Self.host(ModelProbe(log: log).environment(injected))
        defer { window.isHidden = true }
        #expect(!log.models.isEmpty)
        #expect(log.models.allSatisfy { $0 == ObjectIdentifier(injected) })
        #expect(AppModelEnvironment.fallbacks == fallbacks)
    }

    @Test func aViewWithoutAModelGetsTheAppsModelAndIsCounted() {
        let saved = AppModel.current
        let shared = AppModel()
        AppModel.current = shared
        defer { AppModel.current = saved }
        let fallbacks = AppModelEnvironment.fallbacks
        let log = ModelProbeLog()
        let (window, _) = Self.host(ModelProbe(log: log))
        defer { window.isHidden = true }
        #expect(!log.models.isEmpty)
        #expect(log.models.allSatisfy { $0 == ObjectIdentifier(shared) })
        #expect(AppModelEnvironment.fallbacks > fallbacks)
    }

    @Test func aChangeToTheModelUpdatesTheViewThroughTheWrapper() async {
        let model = AppModel()
        let log = ModelProbeLog()
        let (window, controller) = Self.host(ModelProbe(log: log).environment(model))
        defer { window.isHidden = true }
        let before = log.bodies
        model.errorMessage = "changed"
        let updated = await TS.waitUntil {
            controller.view.layoutIfNeeded()
            return log.bodies > before
        }
        #expect(updated, "the body did not run again after an observed property changed")
    }

    @Test func theLibraryAndKeysFallBackTooAndAnInjectedOneWins() {
        let saved = RememberedKeys.current
        let shared = RememberedKeys(store: FakeKeyStore())
        RememberedKeys.current = shared
        defer { RememberedKeys.current = saved }
        let fallbacks = AppModelEnvironment.fallbacks
        let bare = ModelProbeLog()
        let (w1, _) = Self.host(KeysProbe(log: bare))
        defer { w1.isHidden = true }
        #expect(!bare.models.isEmpty)
        #expect(bare.models.allSatisfy { $0 == ObjectIdentifier(shared) })
        #expect(AppModelEnvironment.fallbacks > fallbacks)

        let own = RememberedKeys(store: FakeKeyStore())
        let injected = ModelProbeLog()
        let (w2, _) = Self.host(KeysProbe(log: injected).environment(own))
        defer { w2.isHidden = true }
        #expect(!injected.models.isEmpty)
        #expect(injected.models.allSatisfy { $0 == ObjectIdentifier(own) })
    }
}
