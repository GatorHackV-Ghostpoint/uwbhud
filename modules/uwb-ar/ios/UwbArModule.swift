import ExpoModulesCore

/// Registers the native view and helpers with React Native (Expo Modules API).
public class UwbArModule: Module {
    private lazy var broadcast: HUDBroadcast = {
        let publisher = HUDBroadcast()
        publisher.onStatus = { [weak self] state, message in
            var event: [String: Any] = ["state": state]
            if let message { event["message"] = message }
            self?.sendEvent("onBroadcastStatus", event)
        }
        return publisher
    }()

    public func definition() -> ModuleDefinition {
        Name("UwbAr")
        Events("onBroadcastStatus")
        AsyncFunction("startBroadcast") { (url: String, password: String) in
            try self.broadcast.start(endpoint: url, password: password)
        }.runOnQueue(.main)
        AsyncFunction("stopBroadcast") { self.broadcast.stop() }.runOnQueue(.main)
        OnDestroy {
            DispatchQueue.main.async { self.broadcast.stop() }
        }

        Function("isSupported") { () -> Bool in
            UWBTracker.isSupported
        }

        View(UwbArView.self) {
            Events("onPeers", "onStatus")

            // Name shown on the other phone. Must be set before the view appears.
            Prop("displayName") { (view: UwbArView, name: String) in
                view.displayName = String(name.prefix(40))
            }

            // Manual pairing code; empty connects to any nearby phone running the app.
            Prop("pairingCode") { (view: UwbArView, code: String) in
                view.pairingCode = String(code.prefix(12))
            }

            // [top, bottom, side] screen margins the JS HUD keeps clear; outside them a peer gets an edge arrow.
            Prop("tagInsets") { (view: UwbArView, insets: [Double]) in
                guard insets.count == 3 else { return }
                view.tagInsets = (top: insets[0], bottom: insets[1], side: insets[2])
            }
        }
    }
}
