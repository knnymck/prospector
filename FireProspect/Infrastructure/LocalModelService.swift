import Foundation

struct KeywordExpansion: Codable, Equatable, Sendable {
    static let maximumKeywordCount = 5

    let source: String
    let keywords: [String]

    init(source: String, keywords: [String]) throws {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 80 }
            .reduce(into: [String]()) { result, keyword in
                if !result.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) {
                    result.append(keyword)
                }
            }

        guard !source.isEmpty, !cleaned.isEmpty, cleaned.count <= Self.maximumKeywordCount else {
            throw LocalModelError.invalidExpansion
        }
        self.source = source
        self.keywords = cleaned
    }

    static func fallback(for source: String) -> KeywordExpansion {
        // The caller already rejects an empty category, so this cannot fail.
        try! KeywordExpansion(source: source, keywords: [source])
    }
}

enum LocalModelAvailability: Equatable, Sendable {
    case checking
    case ready
    case runtimeUnavailable
    case modelMissing
    case installing(Double?)

    var label: String {
        switch self {
        case .checking: "Checking Gemma 4 2B…"
        case .ready: "Gemma 4 2B ready"
        case .runtimeUnavailable: "Local runtime unavailable"
        case .modelMissing: "Gemma 4 2B not installed"
        case .installing(let progress):
            progress.map { "Installing Gemma 4 2B (\(Int($0 * 100))%)" } ?? "Installing Gemma 4 2B…"
        }
    }
}

enum LocalModelError: LocalizedError {
    case runtimeUnavailable
    case modelInstallationFailed
    case invalidExpansion

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable: "Ollama is not running. Install and open Ollama to enable Gemma 4 2B."
        case .modelInstallationFailed: "Gemma 4 2B could not be installed by the local runtime."
        case .invalidExpansion: "The local model returned an invalid keyword expansion."
        }
    }
}

/// Talks only to the user's local Ollama runtime. No prompt or business category leaves the Mac.
actor LocalModelService {
    static let shared = LocalModelService()
    static let modelDefaultsKey = "localModelIdentifier"
    static let defaultModel = "gemma4:2b"

    nonisolated static var configuredModel: String {
        let value = UserDefaults.standard.string(forKey: modelDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultModel : value
    }

    nonisolated static func configure(model: String) {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelDefaultsKey)
    }

    private let baseURL = URL(string: "http://127.0.0.1:11434")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func availability() async -> LocalModelAvailability {
        do {
            let (data, response) = try await session.data(from: baseURL.appending(path: "api/tags"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .runtimeUnavailable }
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            let required = Self.configuredModel.lowercased()
            return tags.models.contains(where: { $0.name.lowercased() == required }) ? .ready : .modelMissing
        } catch {
            return .runtimeUnavailable
        }
    }

    func ensureInstalled(progress: (@Sendable (Double?) async -> Void)? = nil) async throws {
        switch await availability() {
        case .ready: return
        case .runtimeUnavailable: throw LocalModelError.runtimeUnavailable
        default: break
        }

        var request = URLRequest(url: baseURL.appending(path: "api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PullRequest(name: Self.configuredModel, stream: false))
        await progress?(nil)
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LocalModelError.modelInstallationFailed
        }
        await progress?(1)
    }

    func expand(_ category: String) async throws -> KeywordExpansion {
        try await ensureInstalled()
        let prompt = """
        Return JSON only. Expand the business category into 1 to \(KeywordExpansion.maximumKeywordCount) precise MapKit search phrases.
        Avoid locations, explanations, broad terms, and unrelated industries.
        Schema: {"source":"the exact input","keywords":["phrase"]}
        Input: \(category)
        """
        var request = URLRequest(url: baseURL.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GenerateRequest(model: Self.configuredModel, prompt: prompt, stream: false, format: "json"))
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LocalModelError.invalidExpansion }
        let envelope = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let decoded = try JSONDecoder().decode(ExpansionPayload.self, from: Data(envelope.response.utf8))
        guard decoded.source.caseInsensitiveCompare(category.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame else {
            throw LocalModelError.invalidExpansion
        }
        return try KeywordExpansion(source: category, keywords: decoded.keywords)
    }

    func selectPersonnelURL(from candidates: [URL]) async throws -> URL {
        let bounded = Array(candidates.prefix(30))
        guard !bounded.isEmpty else { throw SiteEnrichmentError.noCandidateLinks }
        try await ensureInstalled()
        let list = bounded.enumerated().map { "\($0.offset + 1). \($0.element.absoluteString)" }.joined(separator: "\n")
        let prompt = """
        Select the single URL most likely to contain business executives or staff names, job titles, and contact details.
        Avoid careers, recruiting, projects, news, and generic history pages. Select only an exact URL from the list.
        Respond as JSON only: {"best_url":"URL_HERE"}
        \(list)
        """
        let response = try await generateJSON(prompt: prompt)
        let choice = try JSONDecoder().decode(URLChoice.self, from: Data(response.utf8))
        guard let selected = bounded.first(where: { $0.absoluteString == choice.bestURL }) else {
            throw LocalModelError.invalidExpansion
        }
        return selected
    }

    private func generateJSON(prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GenerateRequest(model: Self.configuredModel, prompt: prompt, stream: false, format: "json"))
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LocalModelError.invalidExpansion }
        return try JSONDecoder().decode(GenerateResponse.self, from: data).response
    }

    private struct TagsResponse: Decodable { let models: [Model] }
    private struct Model: Decodable { let name: String }
    private struct PullRequest: Encodable { let name: String; let stream: Bool }
    private struct GenerateRequest: Encodable { let model: String; let prompt: String; let stream: Bool; let format: String }
    private struct GenerateResponse: Decodable { let response: String }
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
