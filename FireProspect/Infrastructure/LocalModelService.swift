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
    static let gemma4TwoB = LocalModelManifest(displayName: "Gemma4 2B", repositoryID: "mlx-community/gemma-2-2b-it-4bit", detail: "Apple Silicon optimized • 4-bit • about 1.5 GB")
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
        case .available: "Local model is available."
        case .notInstalled: "Local model is not installed."
        case .cacheInvalid: "The local model cache is missing or invalid."
        case .loadFailed(let detail): "The local model could not be loaded: \(detail)"
        }
    }
}

enum LocalModelAvailability: Equatable, Sendable {
    case checking, ready, modelMissing, cacheInvalid, loadFailed
    case installing(Double?)
    var label: String {
        switch self {
        case .checking: "Checking Gemma4 2B…"
        case .ready: "Gemma4 2B ready with MLX"
        case .modelMissing: "Gemma4 2B not installed"
        case .cacheInvalid: "Gemma4 2B cache is missing or invalid"
        case .loadFailed: "Gemma4 2B could not be loaded"
        case .installing(let progress): progress.map { "Installing Gemma4 2B (\(Int($0 * 100)))%" } ?? "Installing Gemma4 2B…"
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
            return KeywordExpansionResolution(expansion: .fallback(for: category), status: "Keyword expansion skipped; using the original category. \(reason.unavailableDescription)")
        case nil:
            return KeywordExpansionResolution(expansion: .fallback(for: category), status: "Keyword expansion timed out or was cancelled; using the original category.")
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
        case .appleSiliconRequired: "Gemma4 2B requires an Apple Silicon Mac (M1 or newer)."
        case .installationFailed(let message): "MLX could not install the model: \(message)"
        case .invalidResponse: "The local model returned an invalid response."
        }
    }
}

/// Native MLX inference with an explicit local-only boundary. Normal feature calls never use a repository id.
actor LocalModelService: LocalModelServing {
    static let shared = LocalModelService()
    static let manifest = LocalModelManifest.gemma4TwoB
    private static let installedKey = "mlxGemma4TwoBInstalled"
    private static let checkpointKey = "mlxGemma4TwoBCheckpoint"
    private var container: ModelContainer?
    private var loadFailure: String?

    nonisolated static var configuredModel: String { manifest.repositoryID }

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
        let prompt = """
        Return JSON only. Expand the business category into 1 to \(KeywordExpansion.maximumKeywordCount) precise MapKit search phrases.
        Avoid locations, explanations, broad terms, and unrelated industries.
        Schema: {"source":"the exact input","keywords":["phrase"]}
        Input: \(category)
        """
        switch await generateJSONIfAvailable(prompt: prompt) {
        case .unavailable(let reason): return .unavailable(reason)
        case .value(let json):
            do {
                let decoded = try JSONDecoder().decode(ExpansionPayload.self, from: Data(json.utf8))
                guard decoded.source.caseInsensitiveCompare(category.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else { throw LocalModelError.invalidResponse }
                return .value(try KeywordExpansion(source: category, keywords: decoded.keywords))
            } catch { return .unavailable(.loadFailed(error.localizedDescription)) }
        }
    }

    func selectPersonnelURLIfAvailable(from candidates: [URL]) async -> LocalModelResult<URL> {
        let bounded = Array(candidates.prefix(30))
        guard !bounded.isEmpty else { return .unavailable(.loadFailed(SiteEnrichmentError.noCandidateLinks.localizedDescription)) }
        let list = bounded.enumerated().map { "\($0.offset + 1). \($0.element.absoluteString)" }.joined(separator: "\n")
        switch await generateJSONIfAvailable(prompt: "Select the URL most likely to list staff and contacts. Return JSON only: {\"best_url\":\"URL\"}\n\(list)") {
        case .unavailable(let reason): return .unavailable(reason)
        case .value(let response):
            guard let choice = try? JSONDecoder().decode(URLChoice.self, from: Data(response.utf8)),
                  let selected = bounded.first(where: { $0.absoluteString == choice.bestURL }) else { return .unavailable(.loadFailed(LocalModelError.invalidResponse.localizedDescription)) }
            return .value(selected)
        }
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
              configurationText.contains("gemma2") || configurationText.contains("gemma-2"),
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
    private struct URLChoice: Decodable { let bestURL: String; enum CodingKeys: String, CodingKey { case bestURL = "best_url" } }
}

enum SemanticProspectPolicy {
    private static let excludedTerms = ["university", "college", "school", "government", "city hall", "county office"]
    static func accepts(_ candidate: ProspectCandidate) -> Bool {
        let value = "\(candidate.name) \(candidate.address.formatted)".lowercased()
        return !excludedTerms.contains(where: value.contains)
    }
}
