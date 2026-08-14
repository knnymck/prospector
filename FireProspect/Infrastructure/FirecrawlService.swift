import Foundation

struct FirecrawlActivity: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let occurredAt: Date
    let website: URL
    let selectedPage: URL?
    let usedMapFallback: Bool
    let creditsBefore: Int?
    let creditsAfter: Int?
    let outcome: String

    init(id: UUID = UUID(), occurredAt: Date = Date(), website: URL, selectedPage: URL?, usedMapFallback: Bool, creditsBefore: Int?, creditsAfter: Int?, outcome: String) {
        self.id = id
        self.occurredAt = occurredAt
        self.website = website
        self.selectedPage = selectedPage
        self.usedMapFallback = usedMapFallback
        self.creditsBefore = creditsBefore
        self.creditsAfter = creditsAfter
        self.outcome = outcome
    }

    var creditsUsed: Int? {
        guard let creditsBefore, let creditsAfter else { return nil }
        return max(0, creditsBefore - creditsAfter)
    }
}

@MainActor
enum FirecrawlActivityStore {
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let directory = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FireProspect", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("firecrawl-activity.json")
    }

    static func load(from url: URL? = nil) -> [FirecrawlActivity] {
        guard let source = try? (url ?? defaultURL()), let data = try? Data(contentsOf: source) else { return [] }
        return ((try? JSONDecoder().decode([FirecrawlActivity].self, from: data)) ?? []).sorted { $0.occurredAt > $1.occurredAt }
    }

    static func append(_ activity: FirecrawlActivity, to url: URL? = nil) throws {
        try save([activity] + load(from: url), to: url)
    }

    static func save(_ activities: [FirecrawlActivity], to url: URL? = nil) throws {
        let destination = try (url ?? defaultURL())
        try JSONEncoder().encode(activities.sorted { $0.occurredAt > $1.occurredAt }).write(to: destination, options: .atomic)
    }

    static func clear(at url: URL? = nil) throws { try save([], to: url) }
}

enum FirecrawlError: LocalizedError {
    case missingAPIKey
    case invalidResponse(Int)
    case requestFailed(String)
    case extractionTimedOut

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add a Firecrawl API key in Settings to look up people."
        case .invalidResponse(let status): "The website lookup service returned an error (\(status))."
        case .requestFailed(let message): "The website lookup failed: \(message)"
        case .extractionTimedOut: "Looking up people took too long. Try again."
        }
    }
}

actor FirecrawlService {
    static let shared = FirecrawlService()
    private let baseURL = URL(string: "https://api.firecrawl.dev/v1")!
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func remainingCredits(apiKey: String) async throws -> Int {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FirecrawlError.missingAPIKey }
        var request = URLRequest(url: baseURL.appending(path: "team/credit-usage"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw FirecrawlError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let balance = (object?["data"] as? [String: Any]) ?? object
        let remaining = balance?["remainingCredits"] ?? balance?["creditsRemaining"] ?? balance?["remaining_credits"]
        guard let value = remaining as? NSNumber else {
            throw FirecrawlError.requestFailed("Credit balance was missing from the response.")
        }
        return value.intValue
    }

    func mapDomain(url: URL, apiKey: String) async throws -> [URL] {
        struct Payload: Encodable { let url: String; let limit: Int }
        struct Response: Decodable { let success: Bool?; let links: [String]? }
        let data = try await post(path: "map", body: Payload(url: url.absoluteString, limit: 30), apiKey: apiKey)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.links ?? []).compactMap(URL.init(string:))
    }

    /// The API payload is deliberately constrained to one URL. Firecrawl may still bill
    /// multiple usage-based credits for AI extraction; this is a page-count guardrail.
    func extractPersonnel(fromSinglePage url: URL, apiKey: String) async throws -> PersonnelExtraction {
        struct Schema: Encodable {
            let type = "object"
            let properties: [String: Property]
            struct Property: Encodable { let type: String; let items: Item? }
            struct Item: Encodable { let type: String; let properties: [String: Property]? }
        }
        let string = Schema.Property(type: "string", items: nil)
        let person = Schema.Property(type: "object", items: nil)
        let schema = Schema(properties: [
            "people": .init(type: "array", items: .init(type: person.type, properties: ["name": string, "title": string, "email": string, "phone": string]))
        ])
        struct Payload: Encodable { let urls: [String]; let prompt: String; let schema: Schema }
        struct Start: Decodable { let success: Bool?; let id: String?; let data: JSONValue? }

        let payload = Payload(
            urls: [url.absoluteString],
            prompt: "Extract people listed on this page, including names, job titles, email addresses, and phone numbers from visible text, mailto links, and tel links. Do not invent missing values.",
            schema: schema
        )
        let data = try await post(path: "extract", body: payload, apiKey: apiKey)
        let start = try JSONDecoder().decode(Start.self, from: data)
        if let value = start.data { return try value.decode(PersonnelExtraction.self) }
        guard let id = start.id else { throw FirecrawlError.requestFailed("No extraction job identifier returned.") }
        return try await pollExtraction(id: id, apiKey: apiKey)
    }

    private func pollExtraction(id: String, apiKey: String) async throws -> PersonnelExtraction {
        struct Status: Decodable { let status: String?; let data: JSONValue?; let error: String? }
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(1))
            var request = URLRequest(url: baseURL.appending(path: "extract/\(id)"))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw FirecrawlError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let result = try JSONDecoder().decode(Status.self, from: data)
            if result.status == "completed", let value = result.data { return try value.decode(PersonnelExtraction.self) }
            if result.status == "failed" { throw FirecrawlError.requestFailed(result.error ?? "Extraction failed.") }
        }
        throw FirecrawlError.extractionTimedOut
    }

    private func post<Body: Encodable>(path: String, body: Body, apiKey: String) async throws -> Data {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FirecrawlError.missingAPIKey }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw FirecrawlError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

private enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { self = .number(try container.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var jsonString: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}
