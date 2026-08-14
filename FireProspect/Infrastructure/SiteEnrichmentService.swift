import Foundation

enum SitemapAvailability: String, Sendable, Equatable {
    case https = "HTTPS sitemap"
    case httpOnly = "HTTP-only sitemap"
    case unavailable = "No sitemap found"
}

struct LinkDiscovery: Sendable {
    let links: [URL]
    let sitemapAvailability: SitemapAvailability
    let usedHomepage: Bool
}

enum SiteEnrichmentError: LocalizedError {
    case invalidWebsite
    case noCandidateLinks

    var errorDescription: String? {
        switch self {
        case .invalidWebsite: "The prospect website URL is invalid."
        case .noCandidateLinks: "No same-site team or leadership URL could be discovered."
        }
    }
}

/// Free first pass: checks both sitemap transports and then server-rendered homepage HTML.
actor SiteLinkDiscoveryService {
    static let shared = SiteLinkDiscoveryService()
    static let maximumCandidateCount = 30

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func discover(on website: URL) async throws -> LinkDiscovery {
        guard let host = website.host, isPublicHost(host) else { throw SiteEnrichmentError.invalidWebsite }
        let (availability, sitemapData) = await fetchSitemap(host: host)

        let sitemapLinks = sameSiteLinks(in: sitemapData, baseURL: website)
        if !sitemapLinks.isEmpty {
            return LinkDiscovery(links: Array(sitemapLinks.prefix(Self.maximumCandidateCount)), sitemapAvailability: availability, usedHomepage: false)
        }

        let homepageData = await fetch(website)
        let homepageLinks = sameSiteLinks(in: homepageData, baseURL: website)
        return LinkDiscovery(links: Array(homepageLinks.prefix(Self.maximumCandidateCount)), sitemapAvailability: availability, usedHomepage: true)
    }

    /// Checks the conventional sitemap endpoint using URLSession only. This path never calls Firecrawl.
    func sitemapAvailability(on website: URL) async -> SitemapAvailability {
        guard let host = website.host, isPublicHost(host) else { return .unavailable }
        return await fetchSitemap(host: host).availability
    }

    private func fetchSitemap(host: String) async -> (availability: SitemapAvailability, data: Data?) {
        async let httpsResult = fetch(URL(string: "https://\(host)/sitemap.xml")!)
        async let httpResult = fetch(URL(string: "http://\(host)/sitemap.xml")!)
        let (httpsData, httpData) = await (httpsResult, httpResult)
        if let httpsData, Self.isSitemapDocument(httpsData) { return (.https, httpsData) }
        if let httpData, Self.isSitemapDocument(httpData) { return (.httpOnly, httpData) }
        return (.unavailable, nil)
    }

    static func isSitemapDocument(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(4_096), encoding: .utf8)?.lowercased() else { return false }
        return text.contains("<urlset") || text.contains("<sitemapindex")
    }

    private func isPublicHost(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host != "localhost", !host.hasSuffix(".local") else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return true }
        return !(octets[0] == 10 || octets[0] == 127 ||
                 (octets[0] == 169 && octets[1] == 254) ||
                 (octets[0] == 172 && (16...31).contains(octets[1])) ||
                 (octets[0] == 192 && octets[1] == 168))
    }

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("FireProspect/2.4 Link Discovery", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode), data.count <= 5_000_000 else { return nil }
            return data
        } catch { return nil }
    }

    private func sameSiteLinks(in data: Data?, baseURL: URL) -> [URL] {
        guard let data, let text = String(data: data, encoding: .utf8), let baseHost = baseURL.host?.lowercased() else { return [] }
        let pattern = #"(?i)(?:href\s*=\s*[\"']([^\"'#]+)|<loc>\s*([^<]+)\s*</loc>)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        let links = expression.matches(in: text, range: range).compactMap { match -> URL? in
            let capture = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            guard let swiftRange = Range(capture, in: text) else { return nil }
            let raw = String(text[swiftRange]).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                  url.host?.lowercased() == baseHost,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
        let hints = ["leadership", "our-team", "our_people", "people", "staff", "management", "executive", "about"]
        return links.sorted { lhs, rhs in
            let left = hints.firstIndex(where: lhs.absoluteString.lowercased().contains) ?? hints.count
            let right = hints.firstIndex(where: rhs.absoluteString.lowercased().contains) ?? hints.count
            return left == right ? lhs.absoluteString < rhs.absoluteString : left < right
        }
    }
}

struct EnrichmentReceipt: Sendable {
    let selectedURL: URL
    let discovery: LinkDiscovery
    let usedFirecrawlMap: Bool
    let personnel: PersonnelExtraction
}

/// Orchestrates free discovery, local selection, map fallback, and exactly one extract URL.
actor SiteEnrichmentService {
    static let shared = SiteEnrichmentService()

    func enrichOnePage(website: URL, apiKey: String) async throws -> EnrichmentReceipt {
        let discovery = try await SiteLinkDiscoveryService.shared.discover(on: website)
        var candidates = discovery.links
        var usedMap = false
        if candidates.isEmpty {
            candidates = try await FirecrawlService.shared.mapDomain(url: website, apiKey: apiKey)
            usedMap = true
        }
        guard !candidates.isEmpty else { throw SiteEnrichmentError.noCandidateLinks }
        let selected = try await LocalModelService.shared.selectPersonnelURL(from: candidates)
        let personnel = try await FirecrawlService.shared.extractPersonnel(fromSinglePage: selected, apiKey: apiKey)
        return EnrichmentReceipt(selectedURL: selected, discovery: discovery, usedFirecrawlMap: usedMap, personnel: personnel)
    }
}
