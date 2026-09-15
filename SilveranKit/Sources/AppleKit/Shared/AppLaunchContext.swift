import SilveranKit
import SwiftUI

/// Hands the environment across the App.main() boundary: @main App structs are
/// instantiated by SwiftUI, so entry points park the injected value here.
public enum AppLaunchContext {
    @MainActor public static var environment = SilveranEnvironment()

    /// Optional custom iOS root view injected by host apps (e.g. punk+rally's
    /// five-tab shell). Defaults to nil, in which case Silveran's own
    /// `iOSLibraryView` is used.
    @MainActor public static var iosRootView: AnyView? = nil
}
