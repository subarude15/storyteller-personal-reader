import Foundation

/// Asks the user's Shelfarr server to fetch a title. Credentials live on
/// `SilveranGlobalConfig` (Settings), not a second store.
public enum ShelfarrRequestManager {
    public static func request(
        _ idea: ReadingIdea,
        mediums: [ShelfarrMedium],
    ) async -> Result<Void, ShelfarrError> {
        let settings = await SettingsActor.shared.config
        let client = ShelfarrClient(
            baseURL: settings.shelfarrBaseURL,
            token: settings.shelfarrAPIToken,
        )
        return await client.createRequest(for: idea, mediums: mediums)
    }
}

public enum ShelfarrMedium: String, CaseIterable, Sendable {
    case ebook
    case audiobook
}
