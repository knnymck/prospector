import Foundation
import MLXLLM
import MLXLMCommon

struct KeywordExpansion: Codable, Equatable, Sendable {
    static let maximumKeywordCount = 5
    let source: String
    let keywords: [String]

    init(source: String, keywords: [String]) throws {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 80 }
            .reduce(into: [String]()) { result, keyword in
                if !result.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) { result.append(keyword) }
            }
        guard !source.isEmpty, !cleaned.isEmpty, cleaned.count <= Self.maximumKeywordCount else { throw LocalModelError.invalidResponse }
        self.source = source
        self.keywords = cleaned
    }

    static func fallback(for source: String) -> KeywordExpansion { try! KeywordExpansion(source: source, keywords: [source]) }
}

struct LocalModelManifest: Sendable {
    static let gemmaThreeOneB = LocalModelManifest(displayName: "On-device AI", repositoryID: "mlx-community/gemma-3-1b-it-4bit", detail: "Runs privately on this Mac • Suggests related search terms")
    let displayName: String
    let repositoryID: String
    let detail: String
}

/// A capability result, not an installation preference. Only `available` permits inference.
enum LocalModelCapability: Equatable, Sendable {
    case available
    case notInstalled
    case cacheInvalid
    case loadFailed(String)

    var unavailableDescription: String {
        switch self {
        case .available: "On-device AI is available."
        case .notInstalled: "On-device AI is not installed."
        case .cacheInvalid: "The on-device AI files need to be installed again."
        case .loadFailed(let detail): "On-device AI could not be loaded: \(detail)"
        }
    }
}

enum LocalModelAvailability: Equatable, Sendable {
    case checking, ready, modelMissing, cacheInvalid, loadFailed
    case installing(Double?)
    var label: String {
        switch self {
        case .checking: "Checking on-device AI…"
        case .ready: "On-device AI is ready"
        case .modelMissing: "On-device AI is not installed"
        case .cacheInvalid: "On-device AI needs to be installed again"
        case .loadFailed: "On-device AI could not be loaded"
        case .installing(let progress): progress.map { "Installing on-device AI (\(Int($0 * 100)))%" } ?? "Installing on-device AI…"
        }
    }
}

enum LocalModelResult<Value: Sendable>: Sendable {
    case value(Value)
    case unavailable(LocalModelCapability)
}

protocol LocalModelServing: Sendable {
    func capability() async -> LocalModelCapability
    func expandIfAvailable(_ category: String) async -> LocalModelResult<KeywordExpansion>
    func selectPersonnelURLIfAvailable(from candidates: [URL]) async -> LocalModelResult<URL>
}

struct KeywordExpansionResolution: Sendable {
    let expansion: KeywordExpansion
    let status: String?
}

/// Keeps search orchestration testable and bounds model work without making MapKit wait indefinitely.
struct KeywordExpansionResolver: Sendable {
    let model: any LocalModelServing
    var timeout: Duration = .seconds(20)

    func resolve(_ category: String) async -> KeywordExpansionResolution {
        let gate = ContinuationGate()
        let result: LocalModelResult<KeywordExpansion>? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { await gate.install(continuation) }
                Task {
                    let value = await model.expandIfAvailable(category)
                    await gate.resume(value)
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    await gate.resume(nil)
                }
            }
        } onCancel: { Task { await gate.resume(nil) } }
        switch result {
        case .value(let expansion): return KeywordExpansionResolution(expansion: expansion, status: nil)
        case .unavailable(let reason):
            return KeywordExpansionResolution(expansion: .fallback(for: category), status: "Related search terms weren’t available, so we searched your category as entered. \(reason.unavailableDescription)")
        case nil:
            return KeywordExpansionResolution(expansion: .fallback(for: category), status: "Related search terms took too long, so we searched your category as entered.")
        }
    }

    private actor ContinuationGate {
        private var continuation: CheckedContinuation<LocalModelResult<KeywordExpansion>?, Never>?
        private var pendingValue: LocalModelResult<KeywordExpansion>??
        func install(_ continuation: CheckedContinuation<LocalModelResult<KeywordExpansion>?, Never>) {
            if let pendingValue { continuation.resume(returning: pendingValue) }
            else { self.continuation = continuation }
        }
        func resume(_ value: LocalModelResult<KeywordExpansion>?) {
            if let continuation { continuation.resume(returning: value); self.continuation = nil }
            else if pendingValue == nil { pendingValue = .some(value) }
        }
    }
}

enum LocalModelError: LocalizedError {
    case appleSiliconRequired, installationFailed(String), invalidResponse
    var errorDescription: String? {
        switch self {
        case .appleSiliconRequired: "On-device AI requires an Apple silicon Mac (M1 or newer)."
        case .installationFailed(let message): "On-device AI could not be installed: \(message)"
        case .invalidResponse: "On-device AI returned an unexpected answer."
        }
    }
}

/// Native MLX inference with an explicit local-only boundary. Normal feature calls never use a repository id.
actor LocalModelService: LocalModelServing {
    static let shared = LocalModelService()
    static let manifest = LocalModelManifest.gemmaThreeOneB
    // Model-specific keys prevent a previously installed Gemma 2 checkpoint from
    // being reported as ready after this model migration.
    private static let installedKey = "mlxGemmaThreeOneBInstalled"
    private static let checkpointKey = "mlxGemmaThreeOneBCheckpoint"
    private var container: ModelContainer?
    private var loadFailure: String?

    /// Fast filesystem verification. A stale preference is never sufficient.
    func capability() -> LocalModelCapability {
        if container != nil { return .available }
        if let loadFailure { return .loadFailed(loadFailure) }
        guard UserDefaults.standard.bool(forKey: Self.installedKey) else { return .notInstalled }
        guard let directory = recordedCheckpoint(), Self.isValidCheckpoint(directory) else {
            clearInstallationMetadata()
            return .cacheInvalid
        }
        return .available
    }

    func availability() -> LocalModelAvailability {
        switch capability() {
        case .available: .ready
        case .notInstalled: .modelMissing
        case .cacheInvalid: .cacheInvalid
        case .loadFailed: .loadFailed
        }
    }

    /// Installation entry point. This is called only by `LocalModelSetupWizard`.
    func ensureInstalled(progress: (@Sendable (Double?) async -> Void)? = nil) async throws {
        if container != nil { return }
#if !arch(arm64)
        throw LocalModelError.appleSiliconRequired
#else
        do {
            await progress?(0)
            container = try await LLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(id: Self.manifest.repositoryID)) { download in
                Task { await progress?(download.fractionCompleted) }
            }
            guard let checkpoint = Self.findCachedCheckpoint() else { throw LocalModelError.installationFailed("The downloaded checkpoint could not be verified.") }
            UserDefaults.standard.set(checkpoint.path, forKey: Self.checkpointKey)
            UserDefaults.standard.set(true, forKey: Self.installedKey)
            loadFailure = nil
            await progress?(1)
        } catch {
            clearInstallationMetadata()
            throw LocalModelError.installationFailed(error.localizedDescription)
        }
#endif
    }

    func verify() async throws {
        let result = await generateJSONIfAvailable(prompt: "Reply with JSON only: {\"ready\":true}", maximumTokens: 20)
        guard case .value(let response) = result, response.contains("ready") else { throw LocalModelError.invalidResponse }
    }

    func expandIfAvailable(_ category: String) async -> LocalModelResult<KeywordExpansion> {
        var validFallback: KeywordExpansion?
        for prompt in Self.keywordExpansionPrompts(for: category) {
            switch await generateJSONIfAvailable(prompt: prompt) {
            case .unavailable(let reason): return .unavailable(reason)
            case .value(let json):
                guard let expansion = Self.decodeKeywordExpansion(json, expectedSource: category) else { continue }
                if expansion.keywords.count > 1 { return .value(expansion) }
                validFallback = expansion
            }
        }
        if let validFallback { return .value(validFallback) }
        return .unavailable(.loadFailed("On-device AI did not return usable related search terms."))
    }

    /// These instructions are category-agnostic: results are generated by the
    /// model, not selected from hard-coded examples. A second, shorter prompt
    /// gives a small model another chance when its first answer is malformed or
    /// merely echoes the input.
    nonisolated static func keywordExpansionPrompts(for category: String) -> [String] {
        let contract = """
        Output exactly one JSON object matching this schema:
        {"source":"<exact input>","keywords":["<exact input>","<related business phrase>"]}
        """
        return [
            """
            You generate business discovery phrases for Apple Maps.
            Generate 3 to \(KeywordExpansion.maximumKeywordCount) useful phrases for the input. Preserve the exact input first, then add specific synonyms and closely related business types.
            Do not emit locations, explanations, unrelated industries, or implementation vocabulary such as MapKit, search, query, keyword, and category.
            \(contract)
            Input: \(category)
            """,
            """
            The previous answer was invalid or contained no useful expansion. Try again with 3 to \(KeywordExpansion.maximumKeywordCount) concrete business-type phrases. The first phrase and source must exactly equal the input. Return JSON only.
            \(contract)
            Input: \(category)
            """
        ]
    }

    nonisolated static func decodeKeywordExpansion(_ json: String, expectedSource: String) -> KeywordExpansion? {
        guard let decoded = try? JSONDecoder().decode(ExpansionPayload.self, from: Data(json.utf8)),
              decoded.source.caseInsensitiveCompare(expectedSource.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else { return nil }
        let keywords = validatedModelKeywords(source: expectedSource, keywords: decoded.keywords)
        return try? KeywordExpansion(source: expectedSource, keywords: keywords)
    }

    /// Model output is untrusted. Keep the user's exact category so a weak
    /// generation can never replace a useful query, then remove common prompt
    /// and implementation vocabulary before it reaches MapKit.
    nonisolated static func validatedModelKeywords(source: String, keywords: [String]) -> [String] {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbiddenKeywords: Set<String> = ["search", "query", "keyword", "keywords", "category", "map kit", "mapkit"]
        var result = [source]

        for candidate in keywords {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.lowercased()
            guard !trimmed.isEmpty,
                  trimmed.count <= 80,
                  !normalized.contains("mapkit"),
                  !forbiddenKeywords.contains(normalized),
                  !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
            result.append(trimmed)
            if result.count == KeywordExpansion.maximumKeywordCount { break }
        }
        return result
    }

    func selectPersonnelURLIfAvailable(from candidates: [URL]) async -> LocalModelResult<URL> {
        let bounded = Array(candidates.prefix(30))
        guard !bounded.isEmpty else { return .unavailable(.loadFailed(SiteEnrichmentError.noCandidateLinks.localizedDescription)) }
        let list = bounded.enumerated().map { "\($0.offset + 1). \($0.element.absoluteString)" }.joined(separator: "\n")
        switch await generateJSONIfAvailable(prompt: "Select the URL most likely to list staff and contacts. Return JSON only using its numbered position: {\"best_index\":1}\n\(list)") {
        case .unavailable(let reason): return .unavailable(reason)
        case .value(let response):
            guard let selected = Self.resolvePersonnelURL(from: response, candidates: bounded) else {
                return .unavailable(.loadFailed("On-device AI could not match a team page from the website links."))
            }
            return .value(selected)
        }
    }

    /// Gemma variants may return either the requested one-based index or the older URL schema.
    /// Accepting both avoids treating harmless URL formatting differences as a model load failure.
    nonisolated static func resolvePersonnelURL(from response: String, candidates: [URL]) -> URL? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = Int(trimmed), candidates.indices.contains(index - 1) { return candidates[index - 1] }
        if let mentioned = candidates.first(where: { trimmed.localizedCaseInsensitiveContains($0.absoluteString) }) { return mentioned }

        guard let data = extractJSONObject(from: trimmed).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let rawIndex = object["best_index"] ?? object["index"]
        let index: Int? = (rawIndex as? NSNumber)?.intValue ?? (rawIndex as? String).flatMap(Int.init)
        if let index, candidates.indices.contains(index - 1) { return candidates[index - 1] }

        guard let choice = object["best_url"] as? String else { return nil }
        if let index = Int(choice), candidates.indices.contains(index - 1) { return candidates[index - 1] }
        let normalizedChoice = normalizedURLString(choice)
        return candidates.first { normalizedURLString($0.absoluteString) == normalizedChoice }
    }

    nonisolated private static func normalizedURLString(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed.lowercased() }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.count > 1, components.path.hasSuffix("/") { components.path.removeLast() }
        return (components.string ?? trimmed).lowercased()
    }

    private func generateJSONIfAvailable(prompt: String, maximumTokens: Int = 300) async -> LocalModelResult<String> {
        guard case .available = capability() else { return .unavailable(capability()) }
        if container == nil {
            guard let directory = recordedCheckpoint() else { clearInstallationMetadata(); return .unavailable(.cacheInvalid) }
            do {
                // A directory configuration is local-only and cannot resolve or download a remote checkpoint.
                container = try await LLMModelFactory.shared.loadContainer(configuration: ModelConfiguration(directory: directory)) { _ in }
            } catch {
                loadFailure = error.localizedDescription
                clearInstallationMetadata()
                return .unavailable(.loadFailed(error.localizedDescription))
            }
        }
        guard let container else { return .unavailable(.loadFailed("Model container is unavailable.")) }
        do {
            let result = try await container.perform { context in
                let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
                return try MLXLMCommon.generate(input: input, parameters: GenerateParameters(temperature: 0.1), context: context) { $0.count >= maximumTokens ? .stop : .more }
            }
            return .value(Self.extractJSONObject(from: result.output))
        } catch { return .unavailable(.loadFailed(error.localizedDescription)) }
    }

    private func recordedCheckpoint() -> URL? {
        UserDefaults.standard.string(forKey: Self.checkpointKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func clearInstallationMetadata() {
        UserDefaults.standard.removeObject(forKey: Self.installedKey)
        UserDefaults.standard.removeObject(forKey: Self.checkpointKey)
    }

    nonisolated static func isValidCheckpoint(_ directory: URL) -> Bool {
        let fm = FileManager.default
        let configuration = directory.appendingPathComponent("config.json")
        guard let configurationData = fm.contents(atPath: configuration.path),
              let configurationText = String(data: configurationData, encoding: .utf8)?.lowercased(),
              configurationText.contains("gemma3") || configurationText.contains("gemma-3"),
              let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
        return files.contains { $0.pathExtension == "safetensors" }
    }

    nonisolated private static func findCachedCheckpoint() -> URL? {
        let fm = FileManager.default
        let roots = fm.urls(for: .cachesDirectory, in: .userDomainMask) + fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                if enumerator.level > 8 { enumerator.skipDescendants(); continue }
                if isValidCheckpoint(url) { return url }
            }
        }
        return nil
    }

    static func extractJSONObject(from output: String) -> String {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start <= end else { return output }
        return String(output[start...end])
    }

    private struct ExpansionPayload: Decodable { let source: String; let keywords: [String] }
}

enum SemanticProspectPolicy {
    private static let excludedTerms = ["university", "college", "school", "government", "city hall", "county office"]
    static func accepts(_ candidate: ProspectCandidate) -> Bool {
        let value = "\(candidate.name) \(candidate.address.formatted)".lowercased()
        return !excludedTerms.contains(where: value.contains)
    }
}
