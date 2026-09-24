import Foundation
import ZIPFoundation

#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif

public enum AlignmentRestartMode: String, Sendable {
    case none = "false"
    case full = "full"
    case transcription = "transcription"
    case sync = "sync"
}

public enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

public enum HTTPResult: Sendable {
    case success
    case failure
    case noConnection
}

public enum ActivitySource: String, Hashable, Sendable {
    case app
    case mac
    case tv
    case watch
    case carPlay
}

public actor StorytellerActor {

    let sourceRecordValue: BookSourceRecord
    private var observers: (@Sendable () -> Void)? = nil

    private var username: String?
    private var password: String?
    /// User-facing public Storyteller URL (primary).
    private var publicServerURL: URL?
    /// Optional LAN URL as stored (nil = use default; resolved via StorytellerLANRouting).
    private var storedLANURL: String?
    private var apiBaseURL: URL?
    var accessToken: AccessToken?
    public private(set) var networkRoute: StorytellerNetworkRoute = .public
    private(set) public var libraryMetadata: [BookMetadata] = []
    public var lastUpdateBookError: String?
    private var cachedStatuses: [BookStatus] = []
    public private(set) var connectionStatus: ConnectionStatus = .disconnected
    private var cachedBookCreatePermission: Bool?
    private var cachedBookUpdatePermission: Bool?

    public var isConfigured: Bool {
        apiBaseURL != nil && username != nil && password != nil
    }

    public var currentApiBaseURL: URL? {
        apiBaseURL
    }

    let urlSession: URLSession
    /// PATCH uploads of large audiobooks. The shared session's resource timeout is too short.
    let uploadURLSession: URLSession
    private let downloadDelegate: StorytellerDownloadDelegate
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    /// Make authentication non-reentrant
    private var authenticationTask: Task<Bool, Never>? = nil

    private var monitoringTask: Task<Void, Never>? = nil
    private var isAppActive: Bool = false
    private var activeSources: Set<ActivitySource> = []
    private var reconnectFailureCount: Int = 0
    private var reconnectCooldownUntil: Date? = nil
    private var networkAvailable = true
    public private(set) var lastNetworkOpSucceeded: Bool? = nil
    #if canImport(Network)
    private var networkMonitor: NWPathMonitor? = nil
    private let networkMonitorQueue = DispatchQueue(label: "StorytellerActor.NetworkMonitor")
    #endif

    public init(
        sourceRecord: BookSourceRecord,
        session: URLSession? = nil,
    ) {
        self.sourceRecordValue = sourceRecord
        let delegate = StorytellerDownloadDelegate()
        let configuration: URLSessionConfiguration = {
            if let session {
                return session.configuration
            }
            return URLSessionConfiguration.default
        }()
        configuration.urlCache = URLCache(
            memoryCapacity: 0,
            diskCapacity: 0,
            diskPath: nil,
        )
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600

        urlSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil,
        )
        let uploadConfiguration = URLSessionConfiguration.default
        uploadConfiguration.timeoutIntervalForRequest = 120
        uploadConfiguration.timeoutIntervalForResource = 6 * 60 * 60
        uploadConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        uploadConfiguration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
        uploadURLSession = URLSession(configuration: uploadConfiguration)
        downloadDelegate = delegate
        decoder = JSONDecoder()
        encoder = JSONEncoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        delegate.recordNetworkError = { [weak self] error in
            Task {
                await self?.recordNetworkError(error)
            }
        }
    }

    func logStorytellerError(_ message: String, error: Error) {
        if let urlError = error as? URLError {
            debugLog(
                "[StorytellerActor] \(message): \(urlError.code.rawValue) \(urlError.localizedDescription) host=\(apiBaseURL?.host ?? "?")"
            )
        } else {
            debugLog("[StorytellerActor] \(message): \(error)")
        }
        Task {
            await self.recordNetworkError(error)
        }
    }

    public func request_notify(callback: @escaping @Sendable () -> Void) {
        self.observers = callback
    }

    public func setActive(_ active: Bool, source: ActivitySource) async {
        if active {
            activeSources.insert(source)
        } else {
            activeSources.remove(source)
        }

        let wasActive = isAppActive
        isAppActive = !activeSources.isEmpty

        debugLog(
            "[StorytellerActor] setActive: source=\(source.rawValue), active=\(active), activeSources=\(activeSources.map { $0.rawValue }.sorted())"
        )

        if active && !wasActive {
            await handleActivation()
        } else if wasActive && !isAppActive {
            await handleDeactivation()
        }
    }

    /// Shows the yellow "connecting" state only for a fresh attempt with no known outcome.
    /// Once a source has failed (.error), background retries keep showing red instead of
    /// flickering back to yellow on every retry tick.
    private func beginConnectingIfFresh() async {
        if connectionStatus == .disconnected {
            await updateConnectionStatus(.connecting)
        }
    }

    private func updateConnectionStatus(_ status: ConnectionStatus) async {
        let wasNotConnected = connectionStatus != .connected
        debugLog(
            "[StorytellerActor] updateConnectionStatus: \(connectionStatus) -> \(status), wasNotConnected: \(wasNotConnected)"
        )
        connectionStatus = status
        observers?()

        if wasNotConnected && status == .connected {
            debugLog("[StorytellerActor] Connection restored, scheduling pending queue flush")
            await ProgressSyncActor.shared.scheduleQueueFlush(notifyUser: true)
        }
    }

    private func handleActivation() async {
        guard isConfigured else { return }

        await ProgressSyncActor.shared.recordWakeEvent()
        await ProgressSyncActor.shared.startPolling()

        guard networkAvailable else { return }

        await refreshNetworkRoute(reauthenticateIfChanged: false)

        var reconnected = false
        if connectionStatus != .connected {
            reconnected = await attemptReconnect()
        } else {
            await verifyConnection()
        }

        if connectionStatus == .connected, !reconnected {
            let _ = await fetchLibraryInformation()
            await ProgressSyncActor.shared.scheduleQueueFlush(notifyUser: true)
        }
    }

    private func handleDeactivation() async {
    }

    private func startMonitoring() {
        startNetworkMonitoring()
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let currentStatus = await self.connectionStatus
                let sleepInterval: Duration =
                    if currentStatus == .connected {
                        .seconds(30)
                    } else {
                        .seconds(3)
                    }

                try? await Task.sleep(for: sleepInterval)
                guard !Task.isCancelled else { break }

                guard await self.isAppActive else {
                    continue
                }

                if await self.connectionStatus != .connected {
                    await self.attemptReconnect()
                }
            }
        }
    }

    private func verifyConnection() async {
        guard let apiBaseURL = apiBaseURL, let token = accessToken else {
            debugLog("[StorytellerActor] verifyConnection: no credentials, marking disconnected")
            await updateConnectionStatus(.disconnected)
            return
        }

        let statusesURL = apiBaseURL.appendingPathComponent("statuses")
        do {
            let response = try await httpGet(
                statusesURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: Set(200..<300).union([401, 403]),
            )

            if response.statusCode == 401 || response.statusCode == 403 {
                debugLog("[StorytellerActor] verifyConnection: token expired/invalid, clearing")
                accessToken = nil
                lastNetworkOpSucceeded = false
                await updateConnectionStatus(.error("Session expired"))
            } else {
                debugLog("[StorytellerActor] verifyConnection: connection verified")
                await recordNetworkSuccess()
            }
        } catch {
            debugLog("[StorytellerActor] verifyConnection: failed - \(error)")
            if await recordNetworkError(error) {
                return
            }
            lastNetworkOpSucceeded = false
            await updateConnectionStatus(.error("Connection lost"))
        }
    }

    private func canAttemptReconnect() -> Bool {
        guard networkAvailable else { return false }
        guard let cooldownUntil = reconnectCooldownUntil else { return true }
        return cooldownUntil <= Date()
    }

    private func scheduleReconnectBackoff() {
        reconnectFailureCount += 1
        let delay = min(60.0, Double(reconnectFailureCount) * 5.0)
        reconnectCooldownUntil = Date().addingTimeInterval(delay)
        debugLog("[StorytellerActor] attemptReconnect: backoff \(Int(delay))s")
    }

    private func resetReconnectBackoff() {
        reconnectFailureCount = 0
        reconnectCooldownUntil = nil
    }

    @discardableResult
    private func attemptReconnect() async -> Bool {
        guard username != nil, password != nil, apiBaseURL != nil else {
            return false
        }
        guard canAttemptReconnect() else { return false }

        debugLog("[StorytellerActor] attemptReconnect: trying to reconnect...")

        if await authenticate() {
            debugLog("[StorytellerActor] attemptReconnect: success")
            await recordNetworkSuccess()
            let _ = await fetchLibraryInformation()
            return true
        } else {
            debugLog("[StorytellerActor] attemptReconnect: failed")
            return false
        }
    }

    public func appWillResignActive() async {
        debugLog("[StorytellerActor] appWillResignActive")
        await setActive(false, source: .app)
    }

    private func startNetworkMonitoring() {
        #if canImport(Network)
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.handleNetworkPathUpdate(path) }
        }
        monitor.start(queue: networkMonitorQueue)
        #endif
    }

    private func stopNetworkMonitoring() {
        #if canImport(Network)
        networkMonitor?.cancel()
        networkMonitor = nil
        #endif
    }

    #if canImport(Network)
    private func handleNetworkPathUpdate(_ path: NWPath) async {
        debugLog("[StorytellerActor] network path update: status=\(path.status)")
        await networkAvailabilityDidChange(path.status == .satisfied)
    }
    #endif

    public func networkAvailabilityDidChange(_ available: Bool) async {
        networkAvailable = available
        if !available {
            lastNetworkOpSucceeded = false
            await updateConnectionStatus(.error("No network"))
            return
        }

        guard isAppActive else { return }
        resetReconnectBackoff()
        await refreshNetworkRoute(reauthenticateIfChanged: true)
        if connectionStatus == .connected {
            await verifyConnection()
        } else {
            await attemptReconnect()
        }
    }

    private func isConnectivityError(_ error: URLError) -> Bool {
        switch error.code {
            case .notConnectedToInternet,
                .networkConnectionLost,
                .cannotFindHost,
                .cannotConnectToHost,
                .timedOut,
                .dnsLookupFailed:
                return true
            default:
                return false
        }
    }

    private func recordNetworkSuccess(notifyWhenAlreadyConnected: Bool = true) async {
        lastNetworkOpSucceeded = true
        resetReconnectBackoff()
        if connectionStatus != .connected {
            await updateConnectionStatus(.connected)
        } else if notifyWhenAlreadyConnected {
            observers?()
        }
    }

    @discardableResult
    func recordNetworkError(_ error: Error) async -> Bool {
        guard let urlError = error as? URLError, isConnectivityError(urlError) else {
            return false
        }

        if await fallbackFromLANToPublicIfNeeded() {
            return true
        }

        lastNetworkOpSucceeded = false
        switch connectionStatus {
            case .connected, .connecting:
                await updateConnectionStatus(.error("Connection lost"))
            default:
                observers?()
        }
        return true
    }

    public func setLogin(
        baseURL baseURLString: String,
        lanURL lanURLString: String? = nil,
        username: String,
        password: String,
    ) async -> Bool {
        guard
            await configureCredentials(
                baseURL: baseURLString,
                lanURL: lanURLString,
                username: username,
                password: password,
            )
        else {
            return false
        }
        _ = try? await FilesystemActor.shared.loadOrCreateBookSources()

        await updateConnectionStatus(.connecting)
        let success = await ensureAuthentication() != nil

        if success {
            await updateConnectionStatus(.connected)
            let _ = await fetchLibraryInformation()
        }

        startMonitoring()
        if isAppActive {
            await ProgressSyncActor.shared.startPolling()
        }
        return success
    }

    public enum CredentialTestResult: Sendable {
        case success
        case invalidCredentials
        case failure(String)
    }

    /// Validates Storyteller credentials without registering or mutating any source.
    /// Uses an ephemeral session with a short timeout so it never hangs the UI.
    public static func validateCredentials(
        baseURL baseURLString: String,
        lanURL lanURLString: String? = nil,
        username: String,
        password: String,
    ) async -> CredentialTestResult {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let publicBaseURL = URL(string: trimmedURL), publicBaseURL.scheme != nil else {
            return .failure("Invalid server URL")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        // Match the runtime Storyteller actor route selection: when a LAN URL is
        // configured and reachable, validate credentials against LAN first. The
        // public URL may sit behind Cloudflare/WAF while the NAS API is reachable
        // only on home Wi‑Fi, so testing public-only makes the app look unable to
        // see Storyteller even when the actual route would work.
        var lanCandidate: URL?
        var lanReachable = false
        if let effectiveLAN = StorytellerLANRouting.effectiveLANURL(stored: lanURLString),
            let lanURL = URL(string: effectiveLAN),
            lanURL.scheme != nil
        {
            lanCandidate = lanURL
            lanReachable = await StorytellerLANRouting.probeReachability(serverURL: lanURL)
        }
        let basesToTry = StorytellerLANRouting.credentialValidationBaseURLs(
            publicURL: publicBaseURL,
            lanURL: lanCandidate,
            lanReachable: lanReachable,
        )

        var lastFailure: CredentialTestResult = .failure("Could not connect to this server.")
        for baseURL in basesToTry {
            let tokenURL = resolveAPIBaseURL(from: baseURL).appendingPathComponent("token")
            do {
                _ = try await httpPost(
                    tokenURL.absoluteString,
                    headers: [
                        "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                        "Accept": "application/json",
                    ],
                    formParameters: [
                        "usernameOrEmail": username,
                        "password": password,
                    ],
                    session: session,
                )
                return .success
            } catch HTTPRequestError.unauthorized {
                // A reachable Storyteller API rejected the credentials; do not mask
                // that with public fallback because the password is route-independent.
                return .invalidCredentials
            } catch let error as URLError {
                lastFailure = .failure(error.localizedDescription)
            } catch {
                lastFailure = .failure("Could not connect to this server.")
            }
        }
        return lastFailure
    }

    public func configureCredentials(
        baseURL baseURLString: String,
        lanURL lanURLString: String? = nil,
        username: String,
        password: String,
    ) async -> Bool {
        self.username = username
        self.password = password
        self.accessToken = nil
        self.storedLANURL = lanURLString
        guard let baseURL = URL(string: baseURLString) else {
            debugLog("[StorytellerActor] Invalid base URL: \(baseURLString)")
            await updateConnectionStatus(.error("Invalid server URL"))
            return false
        }
        publicServerURL = baseURL
        networkRoute = .public
        apiBaseURL = StorytellerActor.resolveAPIBaseURL(from: baseURL)
        await refreshNetworkRoute(reauthenticateIfChanged: false)
        startNetworkMonitoring()
        return true
    }

    /// Probe optional LAN URL and prefer it when reachable; otherwise keep public.
    public func refreshNetworkRoute(reauthenticateIfChanged: Bool) async {
        let previous = networkRoute
        let effectiveLAN = StorytellerLANRouting.effectiveLANURL(stored: storedLANURL)

        var preferLAN = false
        if let lanString = effectiveLAN, let lanURL = URL(string: lanString), lanURL.scheme != nil {
            preferLAN = await StorytellerLANRouting.probeReachability(serverURL: lanURL)
        }

        let next: StorytellerNetworkRoute = preferLAN ? .lan : .public
        applyNetworkRoute(next)

        if previous != networkRoute {
            debugLog(
                "[StorytellerActor] network route \(previous.rawValue) -> \(networkRoute.rawValue)"
            )
            accessToken = nil
            observers?()
            if reauthenticateIfChanged, networkAvailable {
                _ = await ensureAuthentication()
            }
        }
    }

    private func applyNetworkRoute(_ route: StorytellerNetworkRoute) {
        networkRoute = route
        switch route {
            case .lan:
                if let lanString = StorytellerLANRouting.effectiveLANURL(stored: storedLANURL),
                    let lanURL = URL(string: lanString)
                {
                    apiBaseURL = StorytellerActor.resolveAPIBaseURL(from: lanURL)
                    return
                }
                networkRoute = .public
                fallthrough
            case .public:
                if let publicServerURL {
                    apiBaseURL = StorytellerActor.resolveAPIBaseURL(from: publicServerURL)
                }
        }
    }

    /// Soft fail: LAN selected but unreachable mid-flight → flip to public once.
    @discardableResult
    private func fallbackFromLANToPublicIfNeeded() async -> Bool {
        guard networkRoute == .lan, publicServerURL != nil else { return false }
        debugLog("[StorytellerActor] LAN request failed; falling back to public")
        accessToken = nil
        applyNetworkRoute(.public)
        resetReconnectBackoff()
        lastNetworkOpSucceeded = nil
        observers?()
        return true
    }

    /// Calls Storyteller's `/api/v2/token` endpoint to exchange credentials for a bearer token.
    /// Server implementation: `storyteller/web/src/app/api/v2/token/route.ts`.
    /// If successful, token will be stored on instance for future methods.
    @discardableResult
    func authenticate() async -> Bool {
        guard let apiBaseURL = apiBaseURL,
            let password = password,
            let username = username
        else {
            return false
        }
        /// Don't duplicate auth requests to server if one is already pending
        if let task = authenticationTask {
            return await task.value
        }

        /// A source that just failed is in backoff; short-circuit so lazy callers
        /// (cover loads, refresh, progress sync) don't re-probe a dead server every tick.
        guard canAttemptReconnect() else {
            return false
        }

        let task = Task {
            defer { authenticationTask = nil }
            let authStart = CFAbsoluteTimeGetCurrent()
            let authHost = apiBaseURL.host ?? "?"
            debugLog("[ConnDiag] authenticate start host=\(authHost)")
            defer {
                let authElapsed = (CFAbsoluteTimeGetCurrent() - authStart) * 1000
                debugLog(
                    "[ConnDiag] authenticate finished host=\(authHost) elapsed=\(String(format: "%.0f", authElapsed))ms"
                )
            }
            await beginConnectingIfFresh()
            do {
                let tokenURL = apiBaseURL.appendingPathComponent("token")

                let response = try await httpPost(
                    tokenURL.absoluteString,
                    headers: [
                        "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                        "Accept": "application/json",
                    ],
                    formParameters: [
                        "usernameOrEmail": username,
                        "password": password,
                    ],
                    session: urlSession,
                    requestTimeout: 10,
                )

                self.accessToken = try decoder.decode(AccessToken.self, from: response.data)
                resetReconnectBackoff()
                return true
            } catch let error as HTTPRequestError {
                logStorytellerError("authenticate", error: error)
                switch error {
                    case .unauthorized:
                        await updateConnectionStatus(.error("Invalid credentials"))
                    default:
                        await updateConnectionStatus(.error("Connection failed"))
                }
                scheduleReconnectBackoff()
                return false
            } catch let error as URLError {
                logStorytellerError("authenticate", error: error)
                await updateConnectionStatus(.error("Connection failed"))
                scheduleReconnectBackoff()
                return false
            } catch {
                logStorytellerError("authenticate", error: error)
                await updateConnectionStatus(.error("Connection failed"))
                scheduleReconnectBackoff()
                return false
            }
        }
        authenticationTask = task
        return await task.value
    }

    @discardableResult
    func ensureAuthentication(forceReauth: Bool = false) async -> (URL, AccessToken)? {
        if forceReauth {
            accessToken = nil
        }

        if let accessToken = accessToken, let apiBaseURL = apiBaseURL {
            return (apiBaseURL, accessToken)
        }

        guard username != nil, password != nil, apiBaseURL != nil else {
            debugLog("[StorytellerActor] ensureAuthentication: not configured")
            return nil
        }

        if await authenticate(), let accessToken = accessToken, let apiBaseURL = apiBaseURL {
            await updateConnectionStatus(.connected)
            return (apiBaseURL, accessToken)
        }

        // Soft fail: auth against LAN failed → try public once.
        if networkRoute == .lan, await fallbackFromLANToPublicIfNeeded() {
            if await authenticate(), let accessToken = accessToken, let apiBaseURL = apiBaseURL {
                await updateConnectionStatus(.connected)
                return (apiBaseURL, accessToken)
            }
        }

        return nil
    }

    public enum PermissionCheckResult: Sendable {
        case allowed
        case denied
        case error(String)
    }

    /// Whether the logged-in user may create books on this server, for gating upload UI. The
    /// server gates its new-book endpoints with `bookCreate` (`bookUpdate` only covers editing
    /// existing books). A definitive server answer is cached for the session. Unknown (not
    /// connected, or a transient error) reports true so connection hiccups don't hide features;
    /// the upload itself will report the real failure.
    public func currentUserCanUploadBooks() async -> Bool {
        if let cachedBookCreatePermission {
            return cachedBookCreatePermission
        }
        guard connectionStatus == .connected else { return true }
        switch await checkUserPermission(named: "bookCreate") {
            case .allowed:
                cachedBookCreatePermission = true
                return true
            case .denied:
                cachedBookCreatePermission = false
                return false
            case .error:
                return true
        }
    }

    /// Fresh `bookCreate` check for the upload sheet. Unknown is not treated as allowed.
    public func bookCreateAccess() async -> StorytellerBookCreateAccess {
        switch await checkUserPermission(named: "bookCreate") {
            case .allowed:
                cachedBookCreatePermission = true
                return .allowed
            case .denied:
                cachedBookCreatePermission = false
                return .denied
            case .error:
                return .needsReconnect
        }
    }

    /// Whether the logged-in user definitively holds `bookUpdate`, which the replace-asset
    /// endpoint is gated on. Unlike the menu-gating `currentUserCanUploadBooks`, unknown is NOT
    /// treated as allowed: the caller is deciding whether to create a book that a later denial
    /// would strand half-made, so only a server-confirmed yes passes. Definitive answers are
    /// cached for the session.
    public func currentUserCanUpdateBooks() async -> Bool {
        if let cachedBookUpdatePermission {
            return cachedBookUpdatePermission
        }
        switch await checkUserPermission(named: "bookUpdate") {
            case .allowed:
                cachedBookUpdatePermission = true
                return true
            case .denied:
                cachedBookUpdatePermission = false
                return false
            case .error:
                return false
        }
    }

    /// Checks if the current user has the `bookUpdate` permission.
    public func checkBookUpdatePermission() async -> PermissionCheckResult {
        await checkUserPermission(named: "bookUpdate")
    }

    /// Server implementation: `storyteller/applications/web/src/app/api/v2/user/route.ts`.
    private func checkUserPermission(named permission: String) async -> PermissionCheckResult {
        guard let (baseURL, token) = await ensureAuthentication() else {
            return .error("Not connected to server")
        }

        let result = await fetchUserPermission(named: permission, baseURL: baseURL, token: token)
        if case .error = result {
            guard let (retryURL, retryToken) = await ensureAuthentication(forceReauth: true) else {
                return .error("Authentication failed")
            }
            return await fetchUserPermission(
                named: permission,
                baseURL: retryURL,
                token: retryToken,
            )
        }
        return result
    }

    private func fetchUserPermission(
        named permission: String,
        baseURL: URL,
        token: AccessToken,
    ) async
        -> PermissionCheckResult
    {
        let userURL = baseURL.appendingPathComponent("user")
        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)

        do {
            let response = try await httpGet(
                userURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            switch evaluateResponse(
                response,
                methodName: "checkUserPermission",
                context: "user permissions",
            ) {
                case .success:
                    break
                case .unauthorized:
                    return .error("Unauthorized")
                default:
                    return .error("Unexpected server response (\(response.statusCode))")
            }

            guard
                let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                let permissions = json["permissions"] as? [String: Any],
                let granted = permissions[permission] as? Bool
            else {
                return .error("Invalid response from server")
            }
            return granted ? .allowed : .denied
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Fetches library metadata from `/api/v2/books`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/route.ts`.
    public func fetchLibraryInformation() async -> [BookMetadata]? {
        await fetchLibraryInformation(allowLANFailover: true)
    }

    private func fetchLibraryInformation(allowLANFailover: Bool) async -> [BookMetadata]? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let booksURL = baseURL.appendingPathComponent("books")

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                booksURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchLibraryInformation",
                    context: "library listing",
                )
            else {
                return nil
            }

            do {
                let wrapper = try decoder.decode(
                    LenientArrayWrapper<StorytellerBookMetadataPayload>.self,
                    from: response.data,
                )
                libraryMetadata = wrapper.values.map { payload in
                    payload.scoped(to: sourceRecordValue.id)
                }

                if let jsonArray = try? JSONSerialization.jsonObject(with: response.data) as? [Any]
                {
                    let totalCount = jsonArray.count
                    if totalCount > libraryMetadata.count {
                        let skipped = totalCount - libraryMetadata.count
                        debugLog(
                            "[StorytellerActor] WARNING: Skipped \(skipped) book(s) due to decode errors (loaded \(libraryMetadata.count)/\(totalCount))"
                        )
                    }
                }
            } catch {
                debugLog("[StorytellerActor] DECODE ERROR in fetchLibraryInformation:")
                debugLog("[StorytellerActor] Error: \(error)")
                if let decodingError = error as? DecodingError {
                    logDetailedDecodingError(decodingError, data: response.data)
                }
                throw error
            }

            try? await LocalMediaActor.shared.updateSourceCacheMetadata(
                libraryMetadata,
                replacingSourceID: sourceRecordValue.id,
            )

            await recordNetworkSuccess()
            return libraryMetadata
        } catch {
            logStorytellerError("fetchLibraryInformation", error: error)
            if allowLANFailover,
                let urlError = error as? URLError,
                isConnectivityError(urlError),
                await fallbackFromLANToPublicIfNeeded()
            {
                return await fetchLibraryInformation(allowLANFailover: false)
            }
            return nil
        }
    }

    /// Downloads the cover image from `/api/v2/books/{bookId}/cover`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/cover/route.ts`.
    /// Returns `nil` when the server responds with 304 (Not Modified) or 404 (no cover available).
    public func fetchCoverImage(
        for bookId: String,
        audio: Bool = false,
        // Hard-code sizes. Storyteller server current returns 404 if you give no dimensions for non-readaloud books--a bug?
        width: Int? = 209,
        height: Int? = 320,
        version: String? = nil,
        ifNoneMatch: String? = nil,
        ifModifiedSince: String? = nil,
    ) async -> BookCover? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }

        let coverURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)
            .appendingPathComponent("cover")

        var queryParameters: [String: String] = [:]
        if let width {
            queryParameters["w"] = String(width)
        }
        if let height {
            queryParameters["h"] = String(height)
        }
        if audio {
            queryParameters["audio"] = "true"
        }
        if let version = Self.coverVersionQueryValue(from: version) {
            queryParameters["v"] = version
        }
        debugLog(
            "[MetadataCoverRefresh] StorytellerActor fetchCoverImage request bookID=\(bookId) audio=\(audio) width=\(width.map(String.init) ?? "nil") height=\(height.map(String.init) ?? "nil") versionInput=\(version ?? "nil") query=\(queryParameters)"
        )

        var headers: [String: String] = [
            "Accept": "image/*",
            "Authorization": authorizationHeaderValue(for: token),
        ]
        if let ifNoneMatch {
            headers["If-None-Match"] = ifNoneMatch
        }
        if let ifModifiedSince {
            headers["If-Modified-Since"] = ifModifiedSince
        }

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(304)
        allowedStatuses.insert(404)

        do {
            let response = try await httpGet(
                coverURL.absoluteString,
                headers: headers,
                queryParameters: queryParameters,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchCoverImage",
                    context: "cover for \(bookId)",
                )
            else {
                return nil
            }

            let httpResponse = response.response
            debugLog(
                "[MetadataCoverRefresh] StorytellerActor fetchCoverImage response bookID=\(bookId) status=\(response.statusCode) bytes=\(response.data.count) etag=\(httpResponse.value(forHTTPHeaderField: "Etag") ?? "nil") lastModified=\(httpResponse.value(forHTTPHeaderField: "Last-Modified") ?? "nil") cacheControl=\(httpResponse.value(forHTTPHeaderField: "Cache-Control") ?? "nil")"
            )
            return BookCover(
                data: response.data,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                etag: httpResponse.value(forHTTPHeaderField: "Etag"),
                lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified"),
                cacheControl: httpResponse.value(forHTTPHeaderField: "Cache-Control"),
                contentDisposition: httpResponse.value(
                    forHTTPHeaderField: "Content-Disposition"
                ),
            )
        } catch {
            debugLog(
                "[MetadataCoverRefresh] StorytellerActor fetchCoverImage error bookID=\(bookId) error=\(error)"
            )
            logStorytellerError("fetchCoverImage", error: error)
            return nil
        }
    }

    public nonisolated static func coverVersionQueryValue(from updatedAt: String?) -> String? {
        guard let updatedAt, !updatedAt.isEmpty else { return nil }
        if let numeric = Int64(updatedAt) {
            return String(numeric)
        }

        guard let date = SilveranDate.parse(updatedAt, field: .coverVersion) else { return nil }
        return SilveranDate.epochMillisString(from: date)
    }

    private func handleDownloadFailure(
        _ failure: StorytellerDownloadFailure,
        bookId: String,
    ) async {
        switch failure {
            case .nonHTTPResponse:
                debugLog("[StorytellerActor] fetchBook received non-HTTP response.")
            case .unauthorized:
                debugLog("[StorytellerActor] fetchBook unauthorized for \(bookId).")
                accessToken = nil
                await updateConnectionStatus(.error("Unauthorized"))
            case .notFound:
                debugLog("[StorytellerActor] fetchBook asset not found for \(bookId).")
            case .unexpectedStatus(let status):
                debugLog("[StorytellerActor] fetchBook unexpected status \(status) for \(bookId).")
        }
    }

    public func createAuthenticatedDownloadRequest(
        for bookId: String,
        format: StorytellerBookFormat,
    ) async -> URLRequest? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }

        let fileURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)
            .appendingPathComponent("files")

        do {
            let requestURL = try urlWithQueryParameters(
                fileURL,
                queryParameters: ["format": downloadQueryValue(for: format)],
            )

            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.setValue(downloadAcceptHeader(for: format), forHTTPHeaderField: "Accept")
            request.setValue(
                authorizationHeaderValue(for: token),
                forHTTPHeaderField: "Authorization",
            )
            return request
        } catch {
            logStorytellerError("createAuthenticatedDownloadRequest", error: error)
            return nil
        }
    }

    /// Builds a ready-to-send positions POST for use with a background URLSession.
    /// The body is returned separately because background upload tasks require
    /// file-based bodies rather than request.httpBody.
    public func createAuthenticatedPositionUploadRequest(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
    ) async -> ProgressUploadRequest? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }

        let url = baseURL.appendingPathComponent("books/\(bookId)/positions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            authorizationHeaderValue(for: token),
            forHTTPHeaderField: "Authorization",
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "locator": encodeLocatorToDict(locator),
            "timestamp": Int64(timestamp),
        ]

        do {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            return ProgressUploadRequest(request: request, body: bodyData)
        } catch {
            logStorytellerError("createAuthenticatedPositionUploadRequest", error: error)
            return nil
        }
    }

    /// Fetches detailed metadata for a single book via `/api/v2/books/{bookId}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/route.ts` (GET handler).
    func fetchBookDetails(for bookId: String) async -> BookMetadata? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let bookURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                bookURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchBookDetails",
                    context: "book detail \(bookId)",
                )
            else {
                return nil
            }

            do {
                let metadata = try decoder.decode(
                    StorytellerBookMetadataPayload.self,
                    from: response.data,
                ).scoped(to: sourceRecordValue.id)
                debugLog(
                    "[MetadataCoverRefresh] StorytellerActor fetchBookDetails success bookID=\(bookId) updatedAt=\(metadata.updatedAt ?? "nil")"
                )
                return metadata
            } catch {
                debugLog("[StorytellerActor] DECODE ERROR in fetchBookDetails for book \(bookId):")
                debugLog("[StorytellerActor] Error: \(error)")
                if let decodingError = error as? DecodingError {
                    logDetailedDecodingError(decodingError, data: response.data)
                }
                throw error
            }
        } catch {
            debugLog(
                "[MetadataCoverRefresh] StorytellerActor fetchBookDetails error bookID=\(bookId) error=\(error)"
            )
            logStorytellerError("fetchBookDetails", error: error)
            return nil
        }
    }

    private static func resolveAPIBaseURL(from serverURL: URL) -> URL {
        let trimmedPath = serverURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmedPath.hasSuffix("api/v2") {
            return serverURL
        }

        if trimmedPath.hasSuffix("api") {
            return serverURL.appendingPathComponent("v2")
        }

        return
            serverURL
            .appendingPathComponent("api")
            .appendingPathComponent("v2")
    }

    func authorizationHeaderValue(for token: AccessToken) -> String {
        if token.tokenType.compare("bearer", options: .caseInsensitive) == .orderedSame {
            return "Bearer \(token.accessToken)"
        }
        return "\(token.tokenType) \(token.accessToken)"
    }

    private func fallbackFilename(
        for bookId: String,
        format: StorytellerBookFormat,
    ) -> String {
        let fileExtension: String =
            switch format {
                case .ebook, .readaloud:
                    "epub"
                case .audiobook:
                    "m4b"
            }
        return "\(bookId).\(fileExtension)"
    }

    private func downloadQueryValue(for format: StorytellerBookFormat) -> String {
        switch format {
            case .audiobook:
                return "audiobook-rpf"
            case .ebook, .readaloud:
                return format.rawValue
        }
    }

    private func downloadAcceptHeader(for format: StorytellerBookFormat) -> String {
        switch format {
            case .audiobook:
                return "application/audiobook+zip"
            case .ebook, .readaloud:
                return "application/octet-stream"
        }
    }

    private func defaultFilename(
        for bookId: String,
        format: StorytellerBookFormat,
        response: HTTPURLResponse,
    ) -> String {
        let guessedExtension =
            if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
                let uti = mimeTypeToPreferredExtension(contentType)
            {
                ".\(uti)"
            } else {
                switch format {
                    case .ebook:
                        ".epub"
                    case .audiobook:
                        ".m4b"
                    case .readaloud:
                        ".epub"
                }
            }
        return "\(bookId)\(guessedExtension)"
    }

    private func mimeTypeToPreferredExtension(_ mimeType: String) -> String? {
        if mimeType == "application/epub+zip" { return "epub" }
        if mimeType == "application/zip" { return "zip" }
        if mimeType == "audio/mpeg" { return "mp3" }
        if mimeType == "audio/mp4" { return "m4a" }
        if mimeType == "audio/x-m4a" { return "m4a" }
        return nil
    }

    /// Retrieves available reading statuses from `/api/v2/statuses`.
    /// Server implementation: `storyteller/web/src/app/api/v2/statuses/route.ts`.
    private func fetchStatuses() async -> [BookStatus]? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let statusesURL = baseURL.appendingPathComponent("statuses")

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                statusesURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchStatuses",
                    context: "statuses",
                )
            else {
                return nil
            }

            let statuses = try decoder.decode([BookStatus].self, from: response.data)
            cachedStatuses = statuses
            return statuses
        } catch {
            logStorytellerError("fetchStatuses", error: error)
            return nil
        }
    }

    /// Returns available statuses for UI display. Uses cached values if available, otherwise fetches from server.
    public func getAvailableStatuses() async -> [BookStatus] {
        if !cachedStatuses.isEmpty {
            return cachedStatuses
        }
        return await fetchStatuses() ?? []
    }

    /// Updates the status for a set of books using `/api/v2/books/status`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/status/route.ts` (PUT handler).
    public func updateStatus(forBooks bookIds: [String], toStatusNamed statusName: String) async
        -> Bool
    {
        guard !bookIds.isEmpty else {
            debugLog("[StorytellerActor] updateStatus requires at least one book id.")
            return false
        }

        if cachedStatuses.isEmpty {
            _ = await fetchStatuses()
        }

        guard let status = cachedStatuses.first(where: { $0.name == statusName }) else {
            debugLog(
                "[StorytellerActor] updateStatus error: status '\(statusName)' not found in cached statuses"
            )
            return false
        }

        guard let statusUUID = status.uuid else {
            debugLog("[StorytellerActor] updateStatus error: status '\(statusName)' has no UUID")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let statusURL = baseURL.appendingPathComponent("books/status")

        struct StatusBody: Encodable {
            let books: [String]
            let status: String
        }

        let body = StatusBody(books: bookIds, status: statusUUID)

        do {
            let payload = try encoder.encode(body)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)

            let response = try await httpPut(
                statusURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            let succeeded =
                evaluateResponse(
                    response,
                    methodName: "updateStatus",
                    context: "status update",
                ) == .success
            if succeeded {
                // Refresh this source's own cache so observers reflect the new status without the
                // caller forcing a cross-source refetch.
                _ = await fetchLibraryInformation()
            }
            return succeeded
        } catch {
            logStorytellerError("updateStatus", error: error)
            return false
        }
    }

    /// Removes tags from books using `/api/v2/books/tags` (DELETE).
    /// Server implementation: `storyteller/web/src/app/api/v2/books/tags/route.ts`.
    /// TODO: UNTESTED
    func removeTags(_ tagUUIDs: [String], fromBooks bookIds: [String]) async -> Bool {
        guard !bookIds.isEmpty else {
            debugLog("[StorytellerActor] removeTags requires at least one book id.")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let tagsURL = baseURL.appendingPathComponent("books/tags")

        struct RemoveTagsBody: Encodable {
            let tags: [String]
            let books: [String]
        }

        let body = RemoveTagsBody(tags: tagUUIDs, books: bookIds)

        do {
            let payload = try encoder.encode(body)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)

            let response = try await httpDelete(
                tagsURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            return evaluateResponse(
                response,
                methodName: "removeTags",
                context: "tag removal",
            ) == .success
        } catch {
            logStorytellerError("removeTags", error: error)
            return false
        }
    }



    static func bookFormatLinkAuthReason(_ status: ConnectionStatus) -> String {
        if case .error(let message) = status {
            let lower = message.lowercased()
            if lower.contains("credential") || lower.contains("unauthorized") {
                return "auth failed"
            }
        }
        return "offline"
    }



    /// Logs out of the remote Storyteller instance and clears cached auth state.
    /// Server implementation: `storyteller/web/src/app/api/v2/logout/route.ts`.
    public func logout() async -> Bool {
        guard let token = accessToken else {
            libraryMetadata.removeAll()
            return true
        }
        guard let apiBaseURL = apiBaseURL else {
            return false
        }

        let logoutURL = apiBaseURL.appendingPathComponent("logout")

        var succeeded = true
        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)

            let response = try await httpPost(
                logoutURL.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token)
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            let status = evaluateResponse(response, methodName: "logout", context: "session")
            switch status {
                case .success, .unauthorized:
                    break
                default:
                    succeeded = false
            }
        } catch {
            logStorytellerError("logout", error: error)
            succeeded = false
        }

        accessToken = nil
        username = nil
        password = nil
        publicServerURL = nil
        storedLANURL = nil
        networkRoute = .public
        self.apiBaseURL = nil
        libraryMetadata.removeAll()
        await updateConnectionStatus(.disconnected)
        monitoringTask?.cancel()
        monitoringTask = nil
        stopNetworkMonitoring()
        return succeeded
    }

    enum StorytellerResponseStatus: Equatable {
        case success
        case notModified
        case unauthorized
        case notFound
        case unexpected(Int)
    }

    func evaluateResponse(
        _ response: HTTPResponse,
        methodName: String,
        context: String,
    ) -> StorytellerResponseStatus {
        let statusCode = response.statusCode

        if (200..<300).contains(statusCode) {
            return .success
        }

        switch statusCode {
            case 304:
                debugLog("[StorytellerActor] \(methodName) \(context) not modified.")
                return .notModified
            case 401, 403:
                debugLog(
                    "[StorytellerActor] \(methodName) \(context) unauthorized (\(statusCode))."
                )
                accessToken = nil
                Task { await self.updateConnectionStatus(.error("Unauthorized")) }
                return .unauthorized
            case 404:
                debugLog("[StorytellerActor] \(methodName) \(context) not found.")
                return .notFound
            default:
                if let body = String(data: response.data, encoding: .utf8), !body.isEmpty {
                    debugLog(
                        "[StorytellerActor] \(methodName) \(context) unexpected status \(statusCode): \(body)"
                    )
                } else {
                    debugLog(
                        "[StorytellerActor] \(methodName) \(context) unexpected status \(statusCode)."
                    )
                }
                return .unexpected(statusCode)
        }
    }


    private func encodeLocatorToDict(_ locator: BookLocator) -> [String: Any] {
        var dict: [String: Any] = [
            "href": locator.href,
            "type": locator.type,
        ]

        if let title = locator.title {
            dict["title"] = title
        }

        if let locations = locator.locations {
            var locationsDict: [String: Any] = [:]

            if let progression = locations.progression {
                locationsDict["progression"] = progression
            }
            if let totalProgression = locations.totalProgression {
                locationsDict["totalProgression"] = totalProgression
            }
            if let position = locations.position {
                locationsDict["position"] = position
            }
            if let partialCfi = locations.partialCfi {
                locationsDict["partialCfi"] = partialCfi
            }
            if let cssSelector = locations.cssSelector {
                locationsDict["cssSelector"] = cssSelector
            }
            if let fragments = locations.fragments {
                locationsDict["fragments"] = fragments
            }

            if !locationsDict.isEmpty {
                dict["locations"] = locationsDict
            }
        }

        if let text = locator.text {
            var textDict: [String: Any] = [:]
            if let before = text.before {
                textDict["before"] = before
            }
            if let after = text.after {
                textDict["after"] = after
            }
            if let highlight = text.highlight {
                textDict["highlight"] = highlight
            }

            if !textDict.isEmpty {
                dict["text"] = textDict
            }
        }

        debugLog("[StorytellerActor] Encoded locator to dictionary")
        return dict
    }

    public func sendProgressToServer(
        bookId: String,
        locator: BookLocator,
        timestamp: Double,
    ) async -> HTTPResult {
        debugLog(
            "[StorytellerActor] sendProgressToServer: bookId=\(bookId), timestamp=\(timestamp)"
        )

        guard let baseURL = apiBaseURL else {
            debugLog("[StorytellerActor] sendProgressToServer: no API base URL")
            return .noConnection
        }

        guard let token = accessToken?.accessToken else {
            debugLog("[StorytellerActor] sendProgressToServer: no access token")
            return .noConnection
        }

        let url = baseURL.appendingPathComponent("books/\(bookId)/positions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Position payloads are tiny; a wedged connection should fail fast so the
        // background flush can retry later instead of pinning the queue for a minute.
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "locator": encodeLocatorToDict(locator),
            "timestamp": Int64(timestamp),
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                debugLog("[StorytellerActor] sendProgressToServer: invalid response type")
                return .failure
            }

            debugLog("[StorytellerActor] sendProgressToServer: status=\(httpResponse.statusCode)")

            switch httpResponse.statusCode {
                case 204:
                    return .success
                case 409, 404:
                    return .failure
                default:
                    return .failure
            }
        } catch {
            debugLog("[StorytellerActor] sendProgressToServer: request failed - \(error)")
            return .noConnection
        }
    }

    public func fetchBookProgress(bookId: String, log: Bool = true) async -> BookReadingPosition? {
        if log {
            debugLog("[StorytellerActor] fetchBookProgress: bookId=\(bookId)")
        }

        guard let metadata = await fetchBookDetails(for: bookId) else {
            if log {
                debugLog("[StorytellerActor] fetchBookProgress: failed to fetch metadata")
            }
            return nil
        }

        if log {
            debugLog(
                "[StorytellerActor] fetchBookProgress: returning position with timestamp=\(metadata.position?.timestamp ?? 0)"
            )
        }
        return metadata.position
    }

    /// Fetches only the position for a book using the slim /positions endpoint.
    /// Returns just {locator, timestamp} without full book metadata.
    public func fetchBookPosition(bookId: String) async -> BookReadingPosition? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }

        let url =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)
            .appendingPathComponent("positions")

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                url.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            // A 404 from the slim positions endpoint means the server has no saved
            // position for this book yet. The progress poller can hit this path
            // repeatedly, so keep it out of the generic failure logger.
            if response.statusCode == 404 {
                await recordNetworkSuccess(notifyWhenAlreadyConnected: false)
                return nil
            }

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchBookPosition",
                    context: "position for \(bookId)",
                )
            else {
                return nil
            }

            await recordNetworkSuccess()
            return try decoder.decode(BookReadingPosition.self, from: response.data)
        } catch {
            logStorytellerError("fetchBookPosition", error: error)
            return nil
        }
    }

    // TODO: Remaining API wrappers
    // - `/api/v2/books/events` (storyteller/web/src/app/api/v2/books/events/route.ts) – real-time catalogue updates.
    // - `/api/v2/books` POST/DELETE (storyteller/web/src/app/api/v2/books/route.ts) – server-side ingest utilities.
    // - `/api/v2/books/[bookId]/cache` (storyteller/web/src/app/api/v2/books/[bookId]/cache/route.ts) – purge cached assets.
    // - `/api/v2/series` & `/api/v2/series/books` (storyteller/web/src/app/api/v2/series/**/*.ts) – manage series metadata.
    // - `/api/v2/settings` & `/api/v2/settings/maxUploadChunkSize` (storyteller/web/src/app/api/v2/settings/**/*.ts) – admin settings.
    // - `/api/v2/creators` (storyteller/web/src/app/api/v2/creators/route.ts) – creator directory.
    // - `/api/v2/users` and `/api/v2/users/{userId}` (storyteller/web/src/app/api/v2/users/**/*.ts) – user administration.
    // - `/api/v2/invites` endpoints (storyteller/web/src/app/api/v2/invites/**/*.ts) – invite management.
    // - `/api/v2/reports` (storyteller/web/src/app/api/v2/reports/**/*.ts) – processing reports and transcripts.
    // - `/api/v2/validate` (storyteller/web/src/app/api/v2/validate/route.ts) – session validation helper.
}



private enum StorytellerDownloadError: Error, Sendable {
    case missingTaskState
    case fileMoveFailed(underlying: Error)
}

private final class StorytellerDownloadDelegate: NSObject, URLSessionDownloadDelegate,
    URLSessionTaskDelegate
{
    var recordNetworkError: (@Sendable (Error) -> Void)?

    struct TaskState: Sendable {
        var continuation: AsyncThrowingStream<StorytellerDownloadEvent, Error>.Continuation
        let fallbackFilename: String
        let bookId: String
        let format: StorytellerBookFormat
        let failureHandler: @Sendable (StorytellerDownloadFailure) -> Void
        var filename: String?
        var expectedBytes: Int64?
        var contentType: String?
        var etag: String?
        var lastModified: String?
        var lastProgressTime: CFAbsoluteTime = 0
    }

    private let stateQueue = DispatchQueue(
        label: "com.kyonifer.silveran.storyteller.download-state"
    )
    private var states: [Int: TaskState] = [:]

    func register(task: URLSessionDownloadTask, state: TaskState) {
        stateQueue.sync {
            self.states[task.taskIdentifier] = state
        }
    }

    private func mutateState<Result>(
        for task: URLSessionTask,
        _ mutation: (inout TaskState) -> Result,
    ) -> (TaskState, Result)? {
        var updatedState: TaskState?
        var mutationResult: Result?
        stateQueue.sync {
            guard var state = states[task.taskIdentifier] else { return }
            let result = mutation(&state)
            states[task.taskIdentifier] = state
            updatedState = state
            mutationResult = result
        }
        if let updatedState, let mutationResult {
            return (updatedState, mutationResult)
        }
        return nil
    }

    private func removeState(for task: URLSessionTask) -> TaskState? {
        var removed: TaskState?
        stateQueue.sync {
            removed = states.removeValue(forKey: task.taskIdentifier)
        }
        return removed
    }

    #if canImport(ObjectiveC)
    @objc(urlSession:downloadTask:didReceiveResponse:completionHandler:)
    #endif
    private func handleDownloadResponse(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void,
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            if let state = removeState(for: downloadTask) {
                state.failureHandler(.nonHTTPResponse)
                state.continuation.finish(throwing: StorytellerDownloadFailure.nonHTTPResponse)
            }
            completionHandler(.cancel)
            return
        }

        let statusCode = httpResponse.statusCode
        guard (200..<300).contains(statusCode) else {
            let failure: StorytellerDownloadFailure
            switch statusCode {
                case 401, 403:
                    failure = .unauthorized
                case 404:
                    failure = .notFound
                default:
                    failure = .unexpectedStatus(statusCode)
            }
            if let state = removeState(for: downloadTask) {
                state.failureHandler(failure)
                state.continuation.finish(throwing: failure)
            }
            completionHandler(.cancel)
            return
        }

        let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")
        let resolvedFilename =
            mutateState(for: downloadTask) { state -> StorytellerDownloadEvent in
                let filename =
                    parseFilename(fromContentDisposition: contentDisposition)
                    ?? state.fallbackFilename
                let contentLengthString = httpResponse.value(forHTTPHeaderField: "Content-Length")
                let expectedLength = contentLengthString.flatMap { Int64($0) }
                state.filename = filename
                state.expectedBytes = expectedLength
                state.contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
                state.etag = httpResponse.value(forHTTPHeaderField: "Etag")
                state.lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified")
                return .response(
                    filename: filename,
                    expectedBytes: expectedLength,
                    contentType: state.contentType,
                    etag: state.etag,
                    lastModified: state.lastModified,
                )
            }

        if let (state, event) = resolvedFilename {
            state.continuation.yield(event)
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        let updateResult = mutateState(for: downloadTask) { state -> (Int64?, String, Bool) in
            if state.expectedBytes == nil, totalBytesExpectedToWrite > 0 {
                state.expectedBytes = totalBytesExpectedToWrite
            }
            let shouldEmit = now - state.lastProgressTime >= 0.1
            if shouldEmit {
                state.lastProgressTime = now
            }
            return (state.expectedBytes, state.bookId, shouldEmit)
        }

        guard let (state, (expectedBytes, _, shouldEmit)) = updateResult, shouldEmit else { return }
        state.continuation.yield(
            .progress(
                receivedBytes: totalBytesWritten,
                expectedBytes: expectedBytes,
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL,
    ) {
        let persistentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: persistentURL.path) {
                try fm.removeItem(at: persistentURL)
            }
            try fm.moveItem(at: location, to: persistentURL)
        } catch {
            if let state = removeState(for: downloadTask) {
                state.continuation.finish(
                    throwing: StorytellerDownloadError.fileMoveFailed(underlying: error)
                )
            }
            return
        }

        if let state = removeState(for: downloadTask) {
            state.continuation.yield(.finished(temporaryURL: persistentURL))
            state.continuation.finish()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?,
    ) {
        guard let error else { return }

        if let urlError = error as? URLError {
            recordNetworkError?(urlError)
        }

        if let state = removeState(for: task) {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                state.continuation.finish()
            } else {
                state.continuation.finish(throwing: error)
            }
        }
    }

    #if canImport(ObjectiveC)
    @objc(urlSession:task:didReceiveResponse:completionHandler:)
    #endif
    func handleTaskResponse(
        _ session: URLSession,
        task: URLSessionTask,
        response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void,
    ) {
        if let downloadTask = task as? URLSessionDownloadTask {
            handleDownloadResponse(
                session,
                downloadTask: downloadTask,
                response: response,
                completionHandler: completionHandler,
            )
        } else {
            completionHandler(.allow)
        }
    }
}

extension StorytellerDownloadDelegate: @unchecked Sendable {}

func logStorytellerError(_ message: String, error: Error) {
    debugLog("[StorytellerActor] \(message): \(error)")
}

func logDetailedDecodingError(_ error: DecodingError, data: Data) {
    switch error {
        case .typeMismatch(let type, let context):
            debugLog("[StorytellerActor] Type mismatch for type \(type)")
            debugLog(
                "[StorytellerActor] Coding path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))"
            )
            debugLog("[StorytellerActor] Context: \(context.debugDescription)")
            printJSONSnippet(data: data, codingPath: context.codingPath)
        case .valueNotFound(let type, let context):
            debugLog("[StorytellerActor] Value not found for type \(type)")
            debugLog(
                "[StorytellerActor] Coding path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))"
            )
            debugLog("[StorytellerActor] Context: \(context.debugDescription)")
            printJSONSnippet(data: data, codingPath: context.codingPath)
        case .keyNotFound(let key, let context):
            debugLog("[StorytellerActor] Key not found: \(key.stringValue)")
            debugLog(
                "[StorytellerActor] Coding path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))"
            )
            debugLog("[StorytellerActor] Context: \(context.debugDescription)")
        case .dataCorrupted(let context):
            debugLog("[StorytellerActor] Data corrupted")
            debugLog(
                "[StorytellerActor] Coding path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))"
            )
            debugLog("[StorytellerActor] Context: \(context.debugDescription)")
            printJSONSnippet(data: data, codingPath: context.codingPath)
        @unknown default:
            debugLog("[StorytellerActor] Unknown decoding error: \(error)")
    }
}

func printJSONSnippet(data: Data, codingPath: [CodingKey]) {
    guard let jsonData = try? JSONSerialization.jsonObject(with: data)
    else {
        debugLog("[StorytellerActor] Could not parse JSON for snippet")
        return
    }

    var current: Any = jsonData
    var pathSoFar: [String] = []

    for key in codingPath {
        pathSoFar.append(key.stringValue)
        if let dict = current as? [String: Any], let next = dict[key.stringValue] {
            current = next
        } else if let array = current as? [Any], let index = key.intValue, index < array.count {
            current = array[index]
        } else {
            debugLog(
                "[StorytellerActor] Could not navigate to path: \(pathSoFar.joined(separator: " -> "))"
            )
            return
        }
    }

    if let snippetData = try? JSONSerialization.data(
        withJSONObject: current,
        options: [.prettyPrinted, .sortedKeys],
    ),
        let snippetString = String(data: snippetData, encoding: .utf8)
    {
        debugLog(
            "[StorytellerActor] JSON at error location (\(pathSoFar.joined(separator: " -> "))):"
        )
        let lines = snippetString.split(separator: "\n")
        for (index, line) in lines.prefix(20).enumerated() {
            debugLog("[StorytellerActor]   \(line)")
            if index == 19 && lines.count > 20 {
                debugLog("[StorytellerActor]   ... (\(lines.count - 20) more lines)")
            }
        }
    }
}

func parseFilename(fromContentDisposition contentDisposition: String?) -> String? {
    guard let contentDisposition else { return nil }
    let components = contentDisposition.split(separator: ";")
    var foundFile: String? = nil
    for component in components {
        let trimmed = component.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("filename*=") {
            // RFC 5987 encoded
            let value = trimmed.dropFirst("filename*=".count)
            if let encoded = value.split(separator: "''", maxSplits: 1).last,
                let decoded = encoded.removingPercentEncoding
            {
                return decoded
            }
        }
        if trimmed.lowercased().hasPrefix("filename=") {
            let value = trimmed.dropFirst("filename=".count)
            foundFile = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }
    return foundFile ?? nil
}
