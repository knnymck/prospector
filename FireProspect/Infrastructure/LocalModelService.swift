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
        guard !source.isEmpty, !cleaned.isEmpty, cleaned.count <= Self.maximumKeywordCount else { throw LocalModelError.invalidExpansion }
        self.source = source
        self.keywords = cleaned
    }

    static func fallback(for source: String) -> KeywordExpansion { try! KeywordExpansion(source: source, keywords: [source]) }
}

/// The one supported, tested model. This public MLX checkpoint does not require a Hugging Face token.
struct LocalModelManifest: Sendable {
    static let gemma4TwoB = LocalModelManifest(
        displayName: "Gemma4 2B",
        repositoryID: "mlx-community/gemma-2-2b-it-4bit",
        detail: "Apple Silicon optimized • 4-bit • about 1.5 GB"
    )
    let displayName: String
    let repositoryID: String
    let detail: String
}

enum LocalModelAvailability: Equatable, Sendable {
    case checking, ready, modelMissing
    case installing(Double?)
    var label: String {
        switch self {
        case .checking: "Checking Gemma4 2B…"
        case .ready: "Gemma4 2B ready with MLX"
        case .modelMissing: "Gemma4 2B not installed"
        case .installing(let progress): progress.map { "Installing Gemma4 2B (\(Int($0 * 100)))%" } ?? "Installing Gemma4 2B…"
        }
    }
}

enum LocalModelError: LocalizedError {
    case appleSiliconRequired, installationFailed(String), invalidExpansion
    var errorDescription: String? {
        switch self {
        case .appleSiliconRequired: "Gemma4 2B requires an Apple Silicon Mac (M1 or newer)."
        case .installationFailed(let message): "MLX could not install the model: \(message)"
        case .invalidExpansion: "The local model returned invalid JSON. Try again."
        }
    }
}

/// Native Apple MLX inference. MLX downloads the public checkpoint from Hugging Face into its app cache.
actor LocalModelService {
    static let shared = LocalModelService()
    static let manifest = LocalModelManifest.gemma4TwoB
    private static let installedKey = "mlxGemma4TwoBInstalled"

    private var container: ModelContainer?

    nonisolated static var configuredModel: String { manifest.repositoryID }

    func availability() -> LocalModelAvailability {
        container != nil || UserDefaults.standard.bool(forKey: Self.installedKey) ? .ready : .modelMissing
    }

    func ensureInstalled(progress: (@Sendable (Double?) async -> Void)? = nil) async throws {
        if container != nil { return }
#if !arch(arm64)
        throw LocalModelError.appleSiliconRequired
#else
        do {
            await progress?(0)
            let configuration = ModelConfiguration(id: Self.manifest.repositoryID)
            container = try await LLMModelFactory.shared.loadContainer(configuration: configuration) { download in
                Task { await progress?(download.fractionCompleted) }
            }
            UserDefaults.standard.set(true, forKey: Self.installedKey)
            await progress?(1)
        } catch {
            UserDefaults.standard.set(false, forKey: Self.installedKey)
            throw LocalModelError.installationFailed(error.localizedDescription)
        }
#endif
    }

    func verify() async throws {
        let response = try await generateJSON(prompt: "Reply with JSON only: {\"ready\":true}", maximumTokens: 20)
        guard response.contains("ready") else { throw LocalModelError.invalidExpansion }
    }

    func expand(_ category: String) async throws -> KeywordExpansion {
        let prompt = """
        Return JSON only. Expand the business category into 1 to \(KeywordExpansion.maximumKeywordCount) precise MapKit search phrases.
        Avoid locations, explanations, broad terms, and unrelated industries.
        Schema: {"source":"the exact input","keywords":["phrase"]}
        Input: \(category)
        """
        let decoded = try JSONDecoder().decode(ExpansionPayload.self, from: Data(try await generateJSON(prompt: prompt).utf8))
        guard decoded.source.caseInsensitiveCompare(category.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else { throw LocalModelError.invalidExpansion }
        return try KeywordExpansion(source: category, keywords: decoded.keywords)
    }

    func selectPersonnelURL(from candidates: [URL]) async throws -> URL {
        let bounded = Array(candidates.prefix(30))
        guard !bounded.isEmpty else { throw SiteEnrichmentError.noCandidateLinks }
        let list = bounded.enumerated().map { "\($0.offset + 1). \($0.element.absoluteString)" }.joined(separator: "\n")
        let response = try await generateJSON(prompt: "Select the URL most likely to list staff and contacts. Return JSON only: {\"best_url\":\"URL\"}\n\(list)")
        let choice = try JSONDecoder().decode(URLChoice.self, from: Data(response.utf8))
        guard let selected = bounded.first(where: { $0.absoluteString == choice.bestURL }) else { throw LocalModelError.invalidExpansion }
        return selected
    }

    private func generateJSON(prompt: String, maximumTokens: Int = 300) async throws -> String {
        try await ensureInstalled()
        guard let container else { throw LocalModelError.invalidExpansion }
        let result = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(prompt: prompt))
            return try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: 0.1),
                context: context
            ) { tokens in tokens.count >= maximumTokens ? .stop : .more }
        }
        return Self.extractJSONObject(from: result.output)
    }

    static func extractJSONObject(from output: String) -> String {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start <= end else { return output }
        return String(output[start...end])
    }

    private struct ExpansionPayload: Decodable { let source: String; let keywords: [String] }
    private struct URLChoice: Decodable {
        let bestURL: String
        enum CodingKeys: String, CodingKey { case bestURL = "best_url" }
    }
}

enum SemanticProspectPolicy {
    private static let excludedTerms = ["university", "college", "school", "government", "city hall", "county office"]
    static func accepts(_ candidate: ProspectCandidate) -> Bool {
        let value = "\(candidate.name) \(candidate.address.formatted)".lowercased()
        return !excludedTerms.contains(where: value.contains)
    }
}
