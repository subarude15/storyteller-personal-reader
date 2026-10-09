#if os(iOS)
import Foundation
import Observation
import SilveranKit

/// Shared prompt for imprecise format-switch vs newer destination saved place.
@MainActor
@Observable
public final class FormatSwitchPromptState {
    public static let shared = FormatSwitchPromptState()

    public struct DiscrepancyPrompt: Identifiable, Equatable {
        public let id: UUID
        public let bookTitle: String
        public let destinationLabel: String
        public let mappedPercentLabel: String
        public let destinationPercentLabel: String

        public init(
            id: UUID = UUID(),
            bookTitle: String,
            destinationLabel: String,
            mappedPercentLabel: String,
            destinationPercentLabel: String,
        ) {
            self.id = id
            self.bookTitle = bookTitle
            self.destinationLabel = destinationLabel
            self.mappedPercentLabel = mappedPercentLabel
            self.destinationPercentLabel = destinationPercentLabel
        }
    }

    public private(set) var discrepancy: DiscrepancyPrompt?

    @ObservationIgnored
    private var onChooseMapped: (@MainActor () async -> Void)?
    @ObservationIgnored
    private var onChooseDestination: (@MainActor () async -> Void)?

    private init() {}

    public func presentDiscrepancy(
        prompt: DiscrepancyPrompt,
        onChooseMapped: @escaping @MainActor () async -> Void,
        onChooseDestination: @escaping @MainActor () async -> Void,
    ) {
        self.onChooseMapped = onChooseMapped
        self.onChooseDestination = onChooseDestination
        self.discrepancy = prompt
    }

    public func chooseMapped() {
        let action = onChooseMapped
        clear()
        Task { @MainActor in await action?() }
    }

    public func chooseDestinationSaved() {
        let action = onChooseDestination
        clear()
        Task { @MainActor in await action?() }
    }

    public func cancel() {
        clear()
    }

    private func clear() {
        discrepancy = nil
        onChooseMapped = nil
        onChooseDestination = nil
    }
}
#endif
