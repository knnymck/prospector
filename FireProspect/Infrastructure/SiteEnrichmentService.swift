import Foundation

enum SitemapAvailability: String, Sendable, Equatable, Codable {
    case https = "HTTPS sitemap"
    case httpOnly = "HTTP-only sitemap"
    case unavailable = "No sitemap found"
}

/// Persists free sitemap checks so revisiting a saved search does not repeat every request.
struct SitemapSnapshot: Equatable, Sendable {
    var availability: SitemapAvailability
    var urls: [URL]
    var fetchedAt: Date

    static let empty = SitemapSnapshot(availability: .unavailable, urls: [], fetchedAt: .distantPast)
}

struct SitemapAvailabilityCache {
    static let maximumStoredURLCount = 400
    private static let defaultsKey = "sitemapAvailabilityByHost.v1"
    private static let linksKey = "sitemapCandidateLinksByHost.v1"
    private static let snapshotKey = "sitemapSnapshotByHost.v1"

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

    static func snapshot(for website: URL, defaults: UserDefaults = .standard) -> SitemapSnapshot? {
        guard let host = website.host?.lowercased(),
              let payload = defaults.dictionary(forKey: snapshotKey)?[host] as? [String: Any],
              let availabilityRaw = payload["availability"] as? String,
              let availability = SitemapAvailability(rawValue: availabilityRaw),
              let strings = payload["urls"] as? [String] else { return nil }
        let fetchedAt = (payload["fetchedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
        return SitemapSnapshot(
            availability: availability,
            urls: strings.compactMap(URL.init(string:)),
            fetchedAt: fetchedAt
        )
    }

    static func storeSnapshot(_ snapshot: SitemapSnapshot, for website: URL, defaults: UserDefaults = .standard) {
        guard let host = website.host?.lowercased() else { return }
        var values = defaults.dictionary(forKey: snapshotKey) as? [String: [String: Any]] ?? [:]
        values[host] = [
            "availability": snapshot.availability.rawValue,
            "urls": Array(snapshot.urls.prefix(maximumStoredURLCount).map(\.absoluteString)),
            "fetchedAt": snapshot.fetchedAt.timeIntervalSince1970
        ]
        defaults.set(values, forKey: snapshotKey)
        store(snapshot.availability, for: website, defaults: defaults)
        storeLinks(snapshot.urls, for: website, defaults: defaults)
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
        case .invalidWebsite: "This business doesn’t have a usable website."
        case .noCandidateLinks: "We couldn’t find a team or staff page on this website."
        }
    }
}

/// Free first pass: inspects the server-rendered homepage navigation without using Firecrawl.
protocol SiteLinkDiscovering: Sendable {
    func discover(on website: URL) async throws -> LinkDiscovery
    func loadSitemap(for website: URL) async -> SitemapSnapshot
}

actor SiteLinkDiscoveryService: SiteLinkDiscovering {
    static let shared = SiteLinkDiscoveryService()
    static let maximumCandidateCount = 30

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func discover(on website: URL) async throws -> LinkDiscovery {
        guard let host = website.host, isPublicHost(host) else { throw SiteEnrichmentError.invalidWebsite }
        let homepageData = await fetch(website)
        let navigation = Self.navigationLinks(in: homepageData, baseURL: website)
        let pageHints = Self.personnelHintLinks(in: homepageData, baseURL: website)
        let links = Array((navigation + pageHints).prefix(Self.maximumCandidateCount))
        return LinkDiscovery(
            links: links,
            sitemapAvailability: SitemapAvailabilityCache.cached(for: website) ?? .unavailable,
            usedHomepage: true
        )
    }

    /// Checks the conventional sitemap endpoint using URLSession only. This path never calls Firecrawl.
    func sitemapAvailability(on website: URL) async -> SitemapAvailability {
        await loadSitemap(for: website).availability
    }

    func loadSitemap(for website: URL) async -> SitemapSnapshot {
        if let cached = SitemapAvailabilityCache.snapshot(for: website) {
            return cached
        }
        guard let host = website.host, isPublicHost(host) else { return .empty }
        let snapshot = await fetchSitemapSnapshot(host: host, website: website)
        SitemapAvailabilityCache.storeSnapshot(snapshot, for: website)
        return snapshot
    }

    private func fetchSitemapSnapshot(host: String, website: URL) async -> SitemapSnapshot {
        let roots = [
            (URL(string: "https://\(host)/sitemap.xml")!, SitemapAvailability.https),
            (URL(string: "https://\(host)/sitemap_index.xml")!, SitemapAvailability.https),
            (URL(string: "http://\(host)/sitemap.xml")!, SitemapAvailability.httpOnly),
            (URL(string: "http://\(host)/sitemap_index.xml")!, SitemapAvailability.httpOnly)
        ]
        for (url, availability) in roots {
            guard let data = await fetch(url), Self.isSitemapDocument(data) else { continue }
            let urls = await expandSitemap(data, website: website)
            if !urls.isEmpty || availability != .unavailable {
                return SitemapSnapshot(availability: availability, urls: urls, fetchedAt: Date())
            }
        }
        return SitemapSnapshot(availability: .unavailable, urls: [], fetchedAt: Date())
    }

    private func expandSitemap(_ data: Data, website: URL) async -> [URL] {
        let text = String(data: data, encoding: .utf8) ?? ""
        let locs = Self.locURLs(in: text, baseURL: website)
        if text.lowercased().contains("<sitemapindex") {
            let childMaps = prioritizedChildSitemaps(locs)
            var collected: [URL] = []
            var seen = Set<String>()
            for child in childMaps.prefix(12) {
                guard let childData = await fetch(child), Self.isSitemapDocument(childData) else { continue }
                for url in Self.sameSiteLinks(in: childData, baseURL: website) where seen.insert(url.absoluteString).inserted {
                    collected.append(url)
                    if collected.count >= SitemapAvailabilityCache.maximumStoredURLCount { return collected }
                }
            }
            return collected
        }
        return Array(Self.sameSiteLinks(in: data, baseURL: website).prefix(SitemapAvailabilityCache.maximumStoredURLCount))
    }

    private func prioritizedChildSitemaps(_ locs: [URL]) -> [URL] {
        let preferred = ["page-sitemap", "post-sitemap", "pages", "posts"]
        return locs.sorted { lhs, rhs in
            let left = preferred.firstIndex(where: lhs.absoluteString.lowercased().contains) ?? preferred.count
            let right = preferred.firstIndex(where: rhs.absoluteString.lowercased().contains) ?? preferred.count
            return left == right ? lhs.absoluteString < rhs.absoluteString : left < right
        }
    }

    nonisolated static func locURLs(in text: String, baseURL: URL) -> [URL] {
        sameSiteLinks(in: Data(text.utf8), baseURL: baseURL)
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

    /// Same-site homepage links whose path or label looks like About / Team, including links outside header/nav/footer.
    nonisolated static func personnelHintLinks(in data: Data?, baseURL: URL) -> [URL] {
        guard let data, let html = String(data: data, encoding: .utf8), let baseHost = baseURL.host?.lowercased() else { return [] }
        let anchorPattern = #"(?is)<a\b[^>]*href\s*=\s*[\"']([^\"'#]+)[\"'][^>]*>(.*?)</a\s*>"#
        guard let anchors = try? NSRegularExpression(pattern: anchorPattern) else { return [] }
        let htmlRange = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var links: [URL] = []
        for anchor in anchors.matches(in: html, range: htmlRange) {
            guard let hrefRange = Range(anchor.range(at: 1), in: html),
                  let labelRange = Range(anchor.range(at: 2), in: html) else { continue }
            let href = String(html[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  url.host?.lowercased() == baseHost else { continue }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            guard let normalizedURL = components?.url, seen.insert(normalizedURL.absoluteString).inserted else { continue }
            let label = String(html[labelRange])
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .lowercased()
            let evidence = "\(label) \(normalizedURL.path)".lowercased()
            let hints = ["our team", "meet our team", "about us", "about", "leadership", "staff", "people", "team"]
            guard hints.contains(where: evidence.contains) else { continue }
            links.append(normalizedURL)
        }
        return links
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

    nonisolated static func sameSiteLinks(in data: Data?, baseURL: URL) -> [URL] {
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

enum PersonnelPageCandidates {
    static let maximumCount = 30

    static func ranked(navigation: [URL], sitemap: [URL]) -> [URL] {
        var seen = Set<String>()
        let scored: [(URL, Int)] = (navigation + sitemap).compactMap { url in
            let key = normalized(url)
            guard seen.insert(key).inserted else { return nil }
            let value = score(url)
            guard value >= 0 else { return nil }
            return (url, value)
        }
        return scored.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.absoluteString < rhs.0.absoluteString : lhs.1 > rhs.1
        }.prefix(maximumCount).map(\.0)
    }

    static func preferredListing(in urls: [URL]) -> URL? {
        urls.first { score($0) >= 60 }
    }

    static func score(_ url: URL) -> Int {
        let path = url.path.lowercased()
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/").map(String.init)
        if parts.contains(where: { ["project", "projects", "product", "products", "wp-content", "wp-json", "intranet"].contains($0) }) {
            return -1
        }
        if [["our-team"], ["our-people"], ["meet-the-team"], ["meet-our-team"]].contains(parts) { return 100 }
        if [["team"], ["staff"], ["people"], ["leadership"]].contains(parts) { return 90 }
        if parts.last == "about" || parts == ["about-us"] || parts == ["about", "us"] { return 75 }
        if parts.contains(where: { ["leadership", "staff", "professionals"].contains($0) }) { return 70 }
        if parts.contains("about") { return 65 }
        if parts.first == "team", parts.count >= 2 { return 45 }
        if parts.contains("team") { return 50 }
        if parts.contains("contact") || parts.contains("careers") { return 15 }
        return 8
    }

    private static func normalized(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        components?.scheme = components?.scheme?.lowercased()
        components?.host = components?.host?.lowercased()
        if let path = components?.path, path.count > 1, path.hasSuffix("/") {
            components?.path.removeLast()
        }
        return components?.string ?? url.absoluteString.lowercased()
    }
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

    func findPersonnelPage(website: URL) async throws -> EnrichmentReceipt {
        async let sitemapLoad: SitemapSnapshot = discoveryService.loadSitemap(for: website)
        let discovery = try await discoveryService.discover(on: website)
        let sitemap = await sitemapLoad
        let candidates = PersonnelPageCandidates.ranked(navigation: discovery.links, sitemap: sitemap.urls)
        let merged = LinkDiscovery(
            links: candidates,
            sitemapAvailability: sitemap.availability == .unavailable ? discovery.sitemapAvailability : sitemap.availability,
            usedHomepage: discovery.usedHomepage
        )
        guard !candidates.isEmpty else { throw SiteEnrichmentError.noCandidateLinks }

        let capability = await model.capability()
        let preferred = PersonnelPageCandidates.preferredListing(in: candidates)
        guard case .available = capability else {
            return EnrichmentReceipt(
                selectedURL: preferred,
                discovery: merged,
                usedFirecrawlMap: false,
                personnel: PersonnelExtraction(people: []),
                aiEnhancement: .skipped(capability)
            )
        }
        let selection = await model.selectPersonnelURLIfAvailable(from: candidates)
        if case .value(let selected) = selection {
            return EnrichmentReceipt(selectedURL: selected, discovery: merged, usedFirecrawlMap: false, personnel: PersonnelExtraction(people: []), aiEnhancement: .completed)
        }
        let reason: LocalModelCapability
        if case .unavailable(let unavailable) = selection { reason = unavailable } else { reason = .loadFailed("Personnel selection failed.") }
        return EnrichmentReceipt(
            selectedURL: preferred,
            discovery: merged,
            usedFirecrawlMap: false,
            personnel: PersonnelExtraction(people: []),
            aiEnhancement: preferred == nil ? .skipped(reason) : .completed
        )
    }

    func enrichOnePage(website: URL, apiKey: String, knownTeamPage: URL? = nil) async throws -> EnrichmentReceipt {
        let receipt: EnrichmentReceipt
        if let knownTeamPage {
            let discovery = (try? await discoveryService.discover(on: website))
                ?? LinkDiscovery(links: [knownTeamPage], sitemapAvailability: .unavailable, usedHomepage: false)
            receipt = EnrichmentReceipt(
                selectedURL: knownTeamPage,
                discovery: discovery,
                usedFirecrawlMap: false,
                personnel: PersonnelExtraction(people: []),
                aiEnhancement: .completed
            )
        } else {
            receipt = try await findPersonnelPage(website: website)
        }
        let selected = receipt.selectedURL ?? knownTeamPage
        guard let selected else { return receipt }

        let personnel = await collectPersonnel(from: selected, website: website, apiKey: apiKey)
        return EnrichmentReceipt(
            selectedURL: selected,
            discovery: receipt.discovery,
            usedFirecrawlMap: false,
            personnel: personnel,
            aiEnhancement: receipt.selectedURL == nil ? receipt.aiEnhancement : .completed
        )
    }

    /// Reads the team page, header/footer company emails, then the stored sitemap layer below if needed.
    private func collectPersonnel(from teamPage: URL, website: URL, apiKey: String) async -> PersonnelExtraction {
        let sitemap = await discoveryService.loadSitemap(for: website)
        let siteHost = website.host ?? teamPage.host ?? ""
        let teamHTML = await fetchHTML(teamPage)
        var collected: [PersonnelExtraction.Person] = []
        var openedPages = Set<String>()
        if let teamHTML {
            collected.append(contentsOf: TeamPagePersonnelParser.people(in: teamHTML, pageURL: teamPage))
            collected.append(contentsOf: TeamPagePersonnelParser.headerFooterPeople(in: teamHTML, siteHost: siteHost))
            let profiles = TeamPagePersonnelParser.profileURLs(in: teamHTML, teamPage: teamPage)
            if !profiles.isEmpty {
                collected.append(contentsOf: await peopleFromProfilePages(profiles))
                openedPages.formUnion(profiles.map(\.absoluteString))
            }
        }

        var merged = TeamPagePersonnelParser.merging(collected)
        if !SiteEmailPolicy.hasCompanyContacts(merged, siteHost: siteHost) {
            let children = TeamPagePersonnelParser.childPages(in: sitemap.urls, under: teamPage)
            let decision = await deeperLookupDecision(teamPage: teamPage, children: children, hasDomainContacts: false)
            if decision.shouldExplore {
                let remaining = decision.selectedURLs.filter { openedPages.insert($0.absoluteString).inserted }
                collected.append(contentsOf: await peopleFromProfilePages(remaining))
                merged = TeamPagePersonnelParser.merging(collected)
            }
        }

        if SiteEmailPolicy.hasCompanyContacts(merged, siteHost: siteHost) || !merged.isEmpty {
            return PersonnelExtraction(people: merged)
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PersonnelExtraction(people: [])
        }
        return (try? await FirecrawlService.shared.extractPersonnel(fromSinglePage: teamPage, apiKey: apiKey))
            ?? PersonnelExtraction(people: [])
    }

    private func deeperLookupDecision(teamPage: URL, children: [URL], hasDomainContacts: Bool) async -> DeeperLookupDecision {
        switch await model.decideDeeperLookupIfAvailable(teamPage: teamPage, childPages: children, hasDomainContacts: hasDomainContacts) {
        case .value(let decision): return decision
        case .unavailable:
            return DeeperLookupDecision.heuristic(children: children, hasDomainContacts: hasDomainContacts)
        }
    }

    private func peopleFromProfilePages(_ urls: [URL]) async -> [PersonnelExtraction.Person] {
        await withTaskGroup(of: [PersonnelExtraction.Person].self) { group in
            for url in urls.prefix(TeamPagePersonnelParser.maximumProfileCount) {
                group.addTask {
                    guard let html = await self.fetchHTML(url) else { return [] }
                    return TeamPagePersonnelParser.people(in: html, pageURL: url)
                }
            }
            var people: [PersonnelExtraction.Person] = []
            for await batch in group { people.append(contentsOf: batch) }
            return people
        }
    }

    private func fetchHTML(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("FireProspect/2.4 Team Page Lookup", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count <= 5_000_000 else { return nil }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        } catch {
            return nil
        }
    }
}
