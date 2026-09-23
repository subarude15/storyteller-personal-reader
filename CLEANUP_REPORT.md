# Silveran Reader - Codebase Cleanup & Refactoring Report

## Executive Summary

As the Silveran Reader repository has grown—merging products and adding new features across iOS, macOS, watchOS, tvOS, and Android—the codebase has accumulated significant bloat. While the architecture (as described in `ARCHITECTURE.md`) has a solid modular foundation with distinct app shells and shared `SilveranKit` / `SilveranAppleKit` components, several individual files and classes have become massively overgrown, violating the Single Responsibility Principle (SRP).

This report outlines the primary areas of bloat and provides concrete, actionable advice on how to refactor and modularize the codebase to improve maintainability, testability, and developer velocity.

---

## 1. Massive Actors & View Models (The "God Objects")

Several actors and view models have absorbed too many responsibilities over time. They handle everything from network connectivity to UI state orchestration.

### The Worst Offenders
* **`StorytellerActor.swift` (~4,100 lines):**
  * **Current State:** This is the largest file in the codebase. It currently handles connection status monitoring, authentication, API requests (fetching libraries, details, permissions), network reachability (NWPathMonitor), reconnection backoffs, and download/upload requests.
  * **Recommendation:** Break this actor into smaller, cohesive domain services:
    * `StorytellerAuthService`: Handles logins, tokens, and permission checks.
    * `StorytellerNetworkMonitor`: Dedicated to tracking `NWPathMonitor` and reachability state.
    * `StorytellerAPIClient`: Purely responsible for encoding/decoding API requests and responses.
    * `StorytellerConnectionManager`: Manages the high-level connection state (connecting, backoff, retry).
    * `StorytellerActor`: Should merely coordinate these sub-services rather than implement them all natively.

* **`MediaViewModel.swift` (~2,700 lines):**
  * **Current State:** It appears to be managing the entire library state, including a `CoverLoadLimiter`, download progress tracking, sidebar rendering states, smart shelf fetching, and widget snapshot publishing.
  * **Recommendation:** Extract the sub-responsibilities:
    * Move the cover loading and caching logic into a dedicated `CoverImageManager` or `MediaAssetManager`.
    * Move download tracking into a `DownloadProgressCoordinator`.
    * Scope the view model down to just the immediate data needs of the views it supports, possibly creating smaller ViewModels for specific sections of the library (e.g., `SidebarViewModel`, `SmartShelfViewModel`).

* **`FolderSourceActor.swift` (~2,000 lines), `LibraryDerivationActor.swift` (~1,700 lines), `BookServiceActor.swift` (~1,700 lines):**
  * **Recommendation:** These data-layer actors are likely doing too much data processing inline. Identify pure data transformation functions and move them into easily testable, stateless utility `struct`s or separate "Worker" actors.

---

## 2. Bloated SwiftUI Views

SwiftUI views are meant to be lightweight, declarative descriptions of the UI. However, several views have grown to thousands of lines, which typically means they are handling too much layout logic, inline state manipulation, and deeply nested view hierarchies in a single file.

### The Worst Offenders
* **`MetadataEditorScopeLayout.swift` (~3,100 lines)**
* **`MediaTableView.swift` (~3,100 lines)**
* **`iOSLibraryView.swift` (~3,000 lines)**
* **`SettingsView.swift` (~2,200 lines)**
* **`MediaGridView.swift` (~1,800 lines)**
* **`TVPlayerView.swift` (~1,500 lines)**

### Recommendations for UI Refactoring
* **Extract Subviews:** Break down large `body` properties into smaller, private structural components. If a subview doesn't rely heavily on the parent's entire environment, extract it to its own file.
* **Extract View Modifiers:** If there are repetitive styles (padding, fonts, backgrounds) applied across many elements, create custom `ViewModifier`s.
* **De-couple State:** Massive views often have a massive list of `@State` and `@Binding` properties. Move complex business logic or multi-step state interactions out of the view and into a targeted ViewModel.
* **Componentize the Settings/Editors:** A 3,000-line editor or 2,200-line settings view should be split by category/tab. For example, `iOSLibraryView.swift` can be broken down into `iOSLibrarySidebarView.swift`, `iOSLibraryContentView.swift`, `iOSLibraryToolbarView.swift`, etc.

---

## 3. General Architecture & Organization Improvements

* **Protocol & Dependency Injection Cleanups:** The facade protocols mentioned in `ARCHITECTURE.md` (e.g. `SilveranPlatform`, `SilveranEnvironment`) are great. Ensure that massive objects like `StorytellerActor` are actually utilizing dependencies through interfaces rather than tightly coupling to concrete implementations, which makes unit testing incredibly difficult for a 4,000-line file.
* **Separation of "App Shell" and "Core Domain":** The `AppleKit` module has some files (like `MobileDesktop`) that are very heavy. Ensure that domain logic hasn't accidentally leaked into the `MobileDesktop` UI layer. UI layers should only be consuming and rendering data, not transforming or deriving complex state.
* **Reduce Inline Closures and Nested Logic:** Deeply nested closures in network callbacks or UI action handlers contribute heavily to line count and readability issues. Extract these into discrete, named functions.

---

## Summary Action Plan

To safely clean up the bloat without breaking existing functionality:
1. **Do not mass-delete or rewrite everything at once.**
2. **Phase 1 (Low Risk):** Extract pure UI subviews into separate files for the massive SwiftUI files (`iOSLibraryView.swift`, `MediaTableView.swift`).
3. **Phase 2 (Medium Risk):** Break out independent utility classes (like `CoverLoadLimiter` from `MediaViewModel`) into their own files.
4. **Phase 3 (High Risk, High Reward):** Incrementally refactor `StorytellerActor.swift` by extracting one domain (e.g., Network Reachability) at a time, writing unit tests for the extracted module, and integrating it back into the main actor.
