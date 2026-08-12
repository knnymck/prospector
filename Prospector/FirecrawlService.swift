import Foundation

actor FirecrawlService {
    
    struct ScrapeResponse: Codable {
        let success: Bool?
        let data: ScrapeData?
    }
    
    struct ScrapeData: Codable {
        let markdown: String?
        let metadata: Metadata?
    }
    
    struct Metadata: Codable {
        let title: String?
        let description: String?
    }
    
    func scrapeDomain(url: String, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "Firecrawl", code: 401, userInfo: [NSLocalizedDescriptionKey: "Firecrawl API key is missing. Please set it in Settings."])
        }
        
        guard let endpoint = URL(string: "https://api.firecrawl.dev/v1/scrape") else {
            throw NSError(domain: "Firecrawl", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid API endpoint."])
        }
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "url": url,
            "formats": ["markdown"]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "Firecrawl", code: 500, userInfo: [NSLocalizedDescriptionKey: "Firecrawl API request failed."])
        }
        
        let decoded = try JSONDecoder().decode(ScrapeResponse.self, from: data)
        return decoded.data?.markdown ?? "No content returned."
    }
}
