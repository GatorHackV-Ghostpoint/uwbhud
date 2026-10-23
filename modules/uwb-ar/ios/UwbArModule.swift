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
        }
    }
}
