# AltStore Classic Sideload Guide (Free Apple ID)

This guide explains how to install **ink+amp** on an iPhone or iPad using **AltStore Classic** and a **free Apple ID**, with **AltServer on Windows** (or macOS) for automated 7-day refreshes. No paid Apple Developer membership ($99/year) is required.

---

## 1. Prerequisites

### On Windows
1. **iTunes** (direct from Apple, NOT the Microsoft Store version):
   - [Download iTunes for Windows (64-bit)](https://www.apple.com/itunes/download/win64)
2. **iCloud** (direct from Apple, NOT the Microsoft Store version):
   - [Download iCloud for Windows](https://updates.cdn-apple.com/2020/windows/001-39935-20200911-1A70AA56-F44B-11EA-8109-3E3482570F65/iCloudSetup.exe)
3. **AltServer for Windows**:
   - Download from [altstore.io](https://altstore.io) and install it.
4. An **Apple ID** (free personal account is sufficient; 10 App ID limit per week, 3 active apps max per device).

### On iOS (iPhone / iPad)
- iOS 18.0 or later.
- If running iOS 16+, enable **Developer Mode**:
  - `Settings` → `Privacy & Security` → `Developer Mode` → Turn **On** → Restart device.

---

## 2. Setting Up AltServer & AltStore

1. Launch **AltServer** on Windows. It will appear as an icon in your notification tray.
2. Connect your iPhone/iPad to your PC via USB cable.
3. Unlock your iOS device and tap **Trust This Computer** if prompted.
4. In iTunes, select your device icon and check **"Sync with this iPhone over Wi-Fi"** so refreshes work wirelessly when on the same Wi-Fi network.
5. In your Windows tray, click the **AltServer icon** → `Install AltStore` → select your device.
6. Enter your Apple ID and password when prompted (AltServer uses this to request a free 7-day provisioning profile from Apple).
7. On your iOS device, go to `Settings` → `General` → `VPN & Device Management` → select your Apple ID under Developer App → tap **Trust "[Your Apple ID]"**.
8. Open the **AltStore** app on your device to confirm it is working.

---

## 3. Downloading the ink+amp Unsigned IPA

1. Navigate to the GitHub repository: `subarude15/storyteller-personal-reader`
2. Go to the **Actions** tab.
3. Click on the latest workflow run on the `ink-amp-ios` branch (or your active PR).
4. Scroll down to the **Artifacts** section at the bottom of the run summary.
5. Download `punkrally-sideload-unsigned-ipa`.
6. Unzip the downloaded file on your computer or directly on your iPhone/iPad to get `punkrally-sideload-unsigned.ipa`.

---

## 4. Installing ink+amp via AltStore

### Method A: Direct on iPhone/iPad (Recommended)
1. AirDrop or download `punkrally-sideload-unsigned.ipa` to the **Files** app on your iPhone/iPad.
2. Open **AltStore** on your iPhone/iPad (ensure your PC running AltServer is powered on and on the same Wi-Fi network, or connect via USB).
3. Go to the **My Apps** tab in AltStore.
4. Tap the **`+`** button in the top left corner.
5. Select `punkrally-sideload-unsigned.ipa` from your Files.
6. AltStore will resign the application using your free Apple ID and install it to your home screen.

### Method B: Via AltServer on Windows (Sideload from PC)
1. Hold `Shift` and left-click the **AltServer** icon in the Windows notification tray.
2. Select **Sideload .ipa...**
3. Choose your connected iPhone/iPad.
4. Browse to and select `punkrally-sideload-unsigned.ipa`.
5. Enter your Apple ID and password if prompted. AltServer will install the app directly.

---

## 5. Slim Sideload Architecture: What Was Stripped & Kept

Free Personal Team Apple IDs have strict constraints:
- Maximum of **10 App IDs** active per 7-day period.
- Maximum of **3 active sideloaded apps** simultaneously on a device.
- **Restricted entitlements**: CarPlay (`com.apple.developer.carplay-audio`) requires an Apple-approved MFi entitlement that free accounts cannot sign; App Groups with custom prefixes or extensions burn additional App IDs.

To provide a flawless 1-click install on free Apple IDs, the **Silveran Reader Sideload (iOS)** target includes:

| Component | Status | Reason / Details |
|-----------|--------|------------------|
| **Core Reader & EPUB/SMIL engine** | **Kept** | Full SilveranKit Storyteller reading and playback. |
| **Storyteller Sync & Shelf** | **Kept** | Progress sync, server connect, and offline downloads. |
| **Podcasts (RSS)** | **Kept** | Integrated 5-tab shell module. |
| **Reading Stats** | **Kept** | Local session analytics and stats strip. |
| **Background Audio & Fetch** | **Kept** | Standard background playback and sync refresh. |
| **Home Continue Hero & Sync Chip** | **Kept** | Dynamic resume from library/shelf. |
| **Bundle ID** | Clean `com.punkrally.reader` | Single bundle ID, avoids split identifier confusion. |
| **Continue Widget Extension** | **Kept (honest)** | Embedded in Sideload IPA (`com.punkrally.reader.widgets`). Burns a second App ID. Gallery kind **`inkamp.continue.v3`** named **ink+amp Continue**. Wipe old tiles after install; v3 is charcoal+white static deep-link (`punkrally://continue`). Live cover/title need App Groups (paid / SideStore). |
| **Library shelf widget** | **Omitted from Sideload extension** | Old `ContinueWidget.swift` / `SilveranReadingWidget.swift` are **not compiled** into the Sideload iOS widgets target. `@main` lives in `SideloadContinueWidget.swift` only (zero AppIntents). Re-enable for paid Apple Developer / SideStore. |
| **App Group** | `group.com.punkrally.reader` (literal) | Baked into Sideload + widgets entitlements / `SILVERAN_WIDGET_APP_GROUP`. **Free AltStore typically does not grant App Groups** (Josh confirmed) — live Continue cover/title and Library shelf require **paid Apple Developer** or **SideStore**. **Not** a Keychain access group. Never ship unexpanded `$(APP_GROUP_ID)`. |
| **CarPlay Entitlement & Scene** | **Removed** | Free developer accounts cannot sign `com.apple.developer.carplay-audio` or CarPlay scenes. |
| **watchOS Companion** | **Excluded** | Companion apps burn additional App IDs on personal teams. |
| **Keychain Access Groups** | Fallback to default | Single app uses default app keychain without team group errors. Never reintroduce `KEYCHAIN_ACCESS_GROUP` on Sideload. |

### Continue widget + AltStore notes

**Honest free-AltStore contract (Josh-verified):** free AltStore resign does **not** grant App Groups. After installing a Sideload IPA that includes kind `inkamp.continue.v3`:

1. **Remove all old ink+amp widgets** from Home / Lock Screen (blank Library tiles and the previous Continue kinds). iOS keeps dead kinds until you delete them.
2. Add Widget → **ink+amp Continue** only. Do not re-add Library or the old Continue entry.
3. Free AltStore = deep-link tile: charcoal + white **Open ink+amp** / **Tap to continue**. Tap opens `punkrally://continue` → Now Playing / Home Continue. No Edit / configure “no books” path.
4. Live cover + title + play/pause, and a Library shelf widget with book picker, require **paid Apple Developer** or **SideStore** App Groups.

**Blank tile but tap still works:** wipe old tiles after install; v3 is charcoal+white static deep-link (`SideloadContinueWidget.swift` alone — SwiftUI+WidgetKit only, zero AppIntents / App Group reads).

Details still baked for when groups work:

- **App Group id (baked literal):** `group.com.punkrally.reader`
  - Sideload entitlements (`SilveranReaderSideload.entitlements`) and widgets entitlements (`SilveranReaderWidgets.entitlements`) embed this string **literally** — never `$(APP_GROUP_ID)` in the Sideload IPA (unsigned `package-ipa` does not expand entitlement placeholders).
  - Sideload + widgets Info keys `SILVERAN_WIDGET_APP_GROUP` are also the literal `group.com.punkrally.reader`.
  - Paid/Automatic Xcode iOS target may still use `$(APP_GROUP_ID)` from xcconfig; Sideload path must not.
- Console probe: `[ContinueWidget] publish|timeline appGroup=… container=ok|nil`. `container=nil` on free AltStore is expected; deep-link Continue still works.
- Play/pause on the Sideload tile is **not** shipped (no `AudioPlaybackIntent` in the extension). Prefer **system Lock Screen Now Playing** for transport on free AltStore. Paid/SideStore can re-enable interactive Continue later.
- Do **not** mark Continue widget fully Shipped in `ROADMAP.md` until Josh verifies this honest UX.

---

## 6. Keeping the App Active (7-Day Refreshes)

- Free Apple ID provisioning certificates expire every **7 days**.
- As long as **AltServer** is running on your Windows PC and your iPhone is connected to the same Wi-Fi network, AltStore will automatically refresh the app in the background.
- You can also open **AltStore** on your iPhone anytime, go to `My Apps`, and tap **Refresh All** while on your home Wi-Fi.
