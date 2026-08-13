import Foundation

enum FirecrawlError: LocalizedError {
    case missingAPIKey
    case invalidResponse(Int)
    case requestFailed(String)
    case extractionTimedOut

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Firecrawl API key is missing. Add it in Settings."
        case .invalidResponse(let status): "Firecrawl returned HTTP \(status)."
        case .requestFailed(let message): "Firecrawl request failed: \(message)"
        case .extractionTimedOut: "Firecrawl extraction did not finish in time."
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

    /// The API payload is deliberately constrained to one URL. This is the testing credit guardrail.
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
            "people": .init(type: "array", items: .init(type: person.type, properties: ["name": string, "title": string, "email": string]))
        ])
        struct Payload: Encodable { let urls: [String]; let prompt: String; let schema: Schema }
        struct Start: Decodable { let success: Bool?; let id: String?; let data: JSONValue? }

        let payload = Payload(
            urls: [url.absoluteString],
            prompt: "Extract only personnel explicitly present on this page. Return names, job titles, and email addresses; do not infer missing values.",
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
