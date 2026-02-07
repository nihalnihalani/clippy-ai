import Foundation
import os

// MARK: - AI Capability

enum AICapability: String, CaseIterable, Hashable {
    case textGeneration
    case streaming
    case vision
    case tagging
}

// MARK: - Provider Type

enum ProviderType: String {
    case local
    case cloud
}

// MARK: - AI Provider Protocol

@MainActor
protocol AIProvider: AIServiceProtocol {
    var id: String { get }
    var displayName: String { get }
    var providerType: ProviderType { get }
    var capabilities: Set<AICapability> { get }
    var isAvailable: Bool { get }
}

// MARK: - AI Provider Registry

@MainActor
class AIProviderRegistry: ObservableObject {
    @Published private(set) var providers: [String: any AIProvider] = [:]

    func register(_ provider: any AIProvider) {
        providers[provider.id] = provider
        Logger.ai.info("Registered AI provider: \(provider.displayName, privacy: .public)")
    }

    func provider(for id: String) -> (any AIProvider)? {
        providers[id]
    }

    func availableProviders() -> [any AIProvider] {
        providers.values.filter { $0.isAvailable }
    }
}

// MARK: - AI Router (fallback chain)

@MainActor
class AIRouter: ObservableObject {
    private let registry: AIProviderRegistry
    private let circuitBreakers: [String: CircuitBreaker]

    @Published var preferredProviderId: String

    init(registry: AIProviderRegistry, preferredProviderId: String) {
        self.registry = registry
        self.preferredProviderId = preferredProviderId
        self.circuitBreakers = [:]
    }

    /// Resolve the best available provider using the fallback chain:
    /// preferred -> any available cloud -> local (always available).
    func resolve() -> (any AIProvider)? {
        // 1. Try preferred
        if let preferred = registry.provider(for: preferredProviderId), preferred.isAvailable {
            return preferred
        }

        // 2. Try any available cloud provider
        if let cloud = registry.availableProviders().first(where: { $0.providerType == .cloud }) {
            return cloud
        }

        // 3. Fall back to local (always available)
        if let local = registry.availableProviders().first(where: { $0.providerType == .local }) {
            return local
        }

        return nil
    }

    func generateAnswer(
        question: String,
        clipboardContext: [RAGContextItem],
        appName: String?
    ) async -> String? {
        guard let provider = resolve() else {
            Logger.ai.error("No AI provider available")
            return nil
        }
        Logger.ai.info("Routing query to: \(provider.displayName, privacy: .public)")
        return await provider.generateAnswer(question: question, clipboardContext: clipboardContext, appName: appName)
    }

    func generateTags(
        content: String,
        appName: String?,
        context: String?
    ) async -> [String] {
        guard let provider = resolve() else { return [] }
        return await provider.generateTags(content: content, appName: appName, context: context)
    }
}
