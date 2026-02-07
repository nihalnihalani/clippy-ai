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
    private var circuitBreakers: [String: CircuitBreaker] = [:]

    @Published var preferredProviderId: String

    init(registry: AIProviderRegistry, preferredProviderId: String) {
        self.registry = registry
        self.preferredProviderId = preferredProviderId
    }

    /// Get or create a circuit breaker for a provider.
    private func breaker(for providerId: String) -> CircuitBreaker {
        if let existing = circuitBreakers[providerId] {
            return existing
        }
        let cb = CircuitBreaker(name: providerId)
        circuitBreakers[providerId] = cb
        return cb
    }

    /// Resolve the best available provider using the fallback chain:
    /// preferred -> any available cloud -> local (always available).
    /// Skips providers whose circuit breakers are open.
    func resolve() async -> (any AIProvider)? {
        // 1. Try preferred
        if let preferred = registry.provider(for: preferredProviderId),
           preferred.isAvailable,
           await breaker(for: preferred.id).canExecute {
            return preferred
        }

        // 2. Try any available cloud provider
        for provider in registry.availableProviders() where provider.providerType == .cloud {
            if await breaker(for: provider.id).canExecute {
                return provider
            }
        }

        // 3. Fall back to local (always available, no circuit breaker needed)
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
        guard let provider = await resolve() else {
            Logger.ai.error("No AI provider available")
            return nil
        }
        Logger.ai.info("Routing query to: \(provider.displayName, privacy: .public)")
        let cb = breaker(for: provider.id)
        let result = await provider.generateAnswer(question: question, clipboardContext: clipboardContext, appName: appName)
        if result != nil {
            await cb.recordSuccess()
        } else {
            await cb.recordFailure()
        }
        return result
    }

    func generateTags(
        content: String,
        appName: String?,
        context: String?
    ) async -> [String] {
        guard let provider = await resolve() else { return [] }
        return await provider.generateTags(content: content, appName: appName, context: context)
    }
}
