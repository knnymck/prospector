import Foundation

enum SitemapAvailability: String, Sendable, Equatable, Codable {
    case https = "HTTPS sitemap"
    case httpOnly = "HTTP-only sitemap"
    case unavailable = "No sitemap found"
}

/// Persists free sitemap checks so revisiting a saved search does not repeat every request.
struct SitemapAvailabilityCache {
    private static let defaultsKey = "sitemapAvailabilityByHost.v1"
    private static let linksKey = "sitemapCandidateLinksByHost.v1"

    static func cached(for website: URL, defaults: UserDefaults = .standard) -> SitemapAvailability? {
        guard let host = website.host?.lowercased(),
              let value = defaults.dictionary(forKey: defaultsKey)?[host] as? String else { return nil }
        return SitemapAvailability(rawValue: value)
    }

    static func store(_ availability: SitemapAvailability, for website: URL, defaults: UserDefaults = .standard) {
        guard let host = website.host?.lowercased() else { return }
        var values = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        values[host] = availability.rawValue
        defaults.set(values, forKey: defaultsKey)
    }

    static func links(for website: URL, defaults: UserDefaults = .standard) -> [URL] {
        guard let host = website.host?.lowercased(),
              let strings = defaults.dictionary(forKey: linksKey)?[host] as? [String] else { return [] }
        return strings.compactMap(URL.init(string:))
    }

    static func storeLinks(_ links: [URL], for website: URL, defaults: UserDefaults = .standard) {
        guard let host = website.host?.lowercased() else { return }
        var values = defaults.dictionary(forKey: linksKey) as? [String: [String]] ?? [:]
        values[host] = Array(links.prefix(SiteLinkDiscoveryService.maximumCandidateCount)).map(\.absoluteString)
        defaults.set(values, forKey: linksKey)
    }
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

/// Free first pass: inspects the server-rendered homepage navigation without using Firecrawl.
protocol SiteLinkDiscovering: Sendable { func discover(on website: URL) async throws -> LinkDiscovery }

actor SiteLinkDiscoveryService: SiteLinkDiscovering {
    static let shared = SiteLinkDiscoveryService()
    static let maximumCandidateCount = 30

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func discover(on website: URL) async throws -> LinkDiscovery {
        guard let host = website.host, isPublicHost(host) else { throw SiteEnrichmentError.invalidWebsite }
        let homepageData = await fetch(website)
        let links = Array(Self.navigationLinks(in: homepageData, baseURL: website).prefix(Self.maximumCandidateCount))
        return LinkDiscovery(
            links: links,
            sitemapAvailability: SitemapAvailabilityCache.cached(for: website) ?? .unavailable,
            usedHomepage: true
        )
    }

    /// Checks the conventional sitemap endpoint using URLSession only. This path never calls Firecrawl.
    func sitemapAvailability(on website: URL) async -> SitemapAvailability {
        guard let host = website.host, isPublicHost(host) else { return .unavailable }
        let result = await fetchSitemap(host: host)
        SitemapAvailabilityCache.store(result.availability, for: website)
        let links = sameSiteLinks(in: result.data, baseURL: website)
        SitemapAvailabilityCache.storeLinks(links, for: website)
        return result.availability
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

    /// Returns same-site links found specifically inside header, nav, and footer elements.
    /// Candidates with personnel-related anchor text or paths sort first for local-model reasoning.
    nonisolated static func navigationLinks(in data: Data?, baseURL: URL) -> [URL] {
        guard let data, let html = String(data: data, encoding: .utf8), let baseHost = baseURL.host?.lowercased() else { return [] }
        let sectionPattern = #"(?is)<(nav|header|footer)\b[^>]*>(.*?)</\1\s*>"#
        let anchorPattern = #"(?is)<a\b[^>]*href\s*=\s*[\"']([^\"'#]+)[\"'][^>]*>(.*?)</a\s*>"#
        guard let sections = try? NSRegularExpression(pattern: sectionPattern),
              let anchors = try? NSRegularExpression(pattern: anchorPattern) else { return [] }
        let htmlRange = NSRange(html.startIndex..., in: html)
        var candidates: [(url: URL, score: Int, order: Int)] = []
        var seen = Set<String>()
        var order = 0

        for section in sections.matches(in: html, range: htmlRange) {
            guard let bodyRange = Range(section.range(at: 2), in: html) else { continue }
            let body = String(html[bodyRange])
            let bodyNSRange = NSRange(body.startIndex..., in: body)
            for anchor in anchors.matches(in: body, range: bodyNSRange) {
                guard let hrefRange = Range(anchor.range(at: 1), in: body),
                      let labelRange = Range(anchor.range(at: 2), in: body) else { continue }
                let href = String(body[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
                guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                      url.host?.lowercased() == baseHost,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.fragment = nil
                guard let normalizedURL = components?.url,
                      seen.insert(normalizedURL.absoluteString).inserted else { continue }
                let label = String(body[labelRange])
                    .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                let evidence = "\(label) \(normalizedURL.path)".lowercased()
                let hints = ["our team", "our people", "leadership", "executive", "management", "professionals", "staff", "people", "team"]
                let score = hints.enumerated().reduce(0) { result, hint in
                    evidence.contains(hint.element) ? max(result, hints.count - hint.offset) : result
                }
                candidates.append((normalizedURL, score, order))
                order += 1
            }
        }
        return candidates.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.order < rhs.order : lhs.score > rhs.score
        }.map(\.url)
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
    let selectedURL: URL?
    let discovery: LinkDiscovery
    let usedFirecrawlMap: Bool
    let personnel: PersonnelExtraction
    let aiEnhancement: AIEnhancementOutcome
}

enum AIEnhancementOutcome: Sendable, Equatable {
    case completed
    case skipped(LocalModelCapability)
}

/// Orchestrates free homepage-navigation discovery, local selection, and exactly one extract URL.
actor SiteEnrichmentService {
    static let shared = SiteEnrichmentService()

    private let model: any LocalModelServing
    private let discoveryService: any SiteLinkDiscovering
    init(model: any LocalModelServing = LocalModelService.shared, discoveryService: any SiteLinkDiscovering = SiteLinkDiscoveryService.shared) {
        self.model = model
        self.discoveryService = discoveryService
    }

    func enrichOnePage(website: URL, apiKey: String) async throws -> EnrichmentReceipt {
        let discovery = try await discoveryService.discover(on: website)
        let capability = await model.capability()
        guard case .available = capability else {
            // Homepage navigation discovery above is useful independently. Do not select a
            // personnel page or extract names/titles when local reasoning is unavailable.
            return EnrichmentReceipt(
                selectedURL: nil,
                discovery: discovery,
                usedFirecrawlMap: false,
                personnel: PersonnelExtraction(people: []),
                aiEnhancement: .skipped(capability)
            )
        }
        let candidates = discovery.links
        guard !candidates.isEmpty else { throw SiteEnrichmentError.noCandidateLinks }
        let selection = await model.selectPersonnelURLIfAvailable(from: candidates)
        guard case .value(let selected) = selection else {
            let reason: LocalModelCapability
            if case .unavailable(let unavailable) = selection { reason = unavailable } else { reason = .loadFailed("Personnel selection failed.") }
            return EnrichmentReceipt(selectedURL: nil, discovery: discovery, usedFirecrawlMap: false, personnel: PersonnelExtraction(people: []), aiEnhancement: .skipped(reason))
        }
        let personnel = try await FirecrawlService.shared.extractPersonnel(fromSinglePage: selected, apiKey: apiKey)
        return EnrichmentReceipt(selectedURL: selected, discovery: discovery, usedFirecrawlMap: false, personnel: personnel, aiEnhancement: .completed)
    }
}
