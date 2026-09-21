import SwiftUI
import SilveranAppleKit

#if os(macOS)
import SilveranContentServer
#endif
#if os(iOS) || os(macOS)
import SilveranReadaloud
#endif

@main
class EntryPointStub {
    static func main() {
        #if os(macOS)
        macAppEntryPoint(
            environment: SilveranEnvironment(
                contentServer: ContentServer(),
                readaloudAligner: ReadaloudEngine(),
                showStorytellerLockup: true,
            )
        )
        #elseif os(iOS)
        // ink+amp: inject the five-tab shell (Home · Library · Shelf · Podcasts · More)
        // as the iOS root. Silveran's app shell (background sync, keychain, reader,
        // now-playing) runs normally underneath; AppLaunchContext.iosRootView replaces
        // just the root library view.
        AppLaunchContext.iosRootView = AnyView(PunkRallyTabView())
        iosAppEntryPoint(
            environment: SilveranEnvironment(readaloudAligner: ReadaloudEngine())
        )
        #elseif os(watchOS)
        watchAppEntryPoint()
        #elseif os(tvOS)
        tvAppEntryPoint()
        #endif
    }
}