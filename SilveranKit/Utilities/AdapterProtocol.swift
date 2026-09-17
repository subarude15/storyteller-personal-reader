public protocol BookAdapter: Sendable {
    var config: AdapterConfig { get }
    func fetch(query: String) async throws -> AdapterResult
}
