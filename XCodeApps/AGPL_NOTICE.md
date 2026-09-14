# AGPL-3.0 Attribution Notice — punk+rally Reader

Portions of the `punk+rally` Reader iOS app are ported from
[**Enve Book Player**](https://github.com/opisaac9001/Enve-Book-Player),
which is licensed under the **GNU Affero General Public License v3.0
(AGPL-3.0-only)**.

## Ported modules

| Module | Ported files | Original Enve source |
|--------|--------------|----------------------|
| Podcasts (RSS rail) | `XCodeApps/PunkRallyModules/Podcasts/RSSPodcastParser.swift`, `PodcastSubscriptionStore.swift`, `PodcastsViewModel.swift`, `PodcastsHomeView.swift` | `ios/enve/Networking/Providers/RSSPodcastParser.swift`, `ios/enve/Services/Integrations/PodcastSubscriptionStore.swift`, `ios/enve/Screens/Podcasts/PodcastsModel.swift`, `ios/enve/Screens/Podcasts/PodcastsHomeScreen.swift` |
| Stats (reading/listening) | `XCodeApps/PunkRallyModules/Stats/PunkRallyStatsModels.swift`, `SessionTracker.swift`, `StatsView.swift` | `ios/enve/Models/Statistics/*`, `ios/enve/Services/ListeningStats/ListeningStatsTracker.swift`, `ios/enve/Screens/Journal/*` |

Every ported file carries an `SPDX-License-Identifier: AGPL-3.0-only`
header comment referencing the original.

## License status

- **Silveran Reader core** (SilveranKit, SilveranAppleKit): permissive MIT-like license.
- **Ported Enve modules** (Podcasts + Stats code above): AGPL-3.0-only.
  The AGPL applies to these files and their derivatives.

## Obligations

If you distribute or serve this app to others over a network, the AGPL
requires you to offer the complete corresponding source of the ported
modules. The ported files are kept in a clearly separate directory
(`XCodeApps/PunkRallyModules/`) to make compliance straightforward.

Full AGPL-3.0 license text: <https://www.gnu.org/licenses/agpl-3.0.txt>

## Settings → Licenses

End users should see this notice under **Settings → Licenses** in the app.