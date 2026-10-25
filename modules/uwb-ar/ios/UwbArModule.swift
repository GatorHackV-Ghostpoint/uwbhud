import ExpoModulesCore

/// Registers the native view and helpers with React Native (Expo Modules API).
public class UwbArModule: Module {
    public func definition() -> ModuleDefinition {
        Name("UwbAr")

        Function("isSupported") { () -> Bool in
            UWBTracker.isSupported
        }

        View(UwbArView.self) {
            Events("onPeers", "onStatus")

            // Name shown on the other phone. Must be set before the view appears.
            Prop("displayName") { (view: UwbArView, name: String) in
                view.displayName = String(name.prefix(40))
            }

            // [top, bottom, side] screen margins the JS HUD keeps clear; outside them a peer gets an edge arrow.
            Prop("tagInsets") { (view: UwbArView, insets: [Double]) in
                guard insets.count == 3 else { return }
                view.tagInsets = (top: insets[0], bottom: insets[1], side: insets[2])
            }
        }
    }
}
