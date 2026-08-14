import CoreLocation
import Foundation

struct ProspectID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init?(websiteURL: URL) {
        guard let host = websiteURL.host?.lowercased(), !host.isEmpty else { return nil }
        self.rawValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct TeamMemberID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID) { self.rawValue = rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue.uuidString < rhs.rawValue.uuidString }
}

struct Timestamp: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: Date
    init(rawValue: Date) { self.rawValue = rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum CrawlStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case notStarted
    case queued
    case crawling
    case completed
    case failed
}

struct Relevance: Codable, Hashable, Sendable {
    let score: Double?
    let rationale: String?

    init(score: Double? = nil, rationale: String? = nil) {
        self.score = score.map { min(max($0, 0), 1) }
        self.rationale = rationale
    }
}

struct ProspectProvenance: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case mapKit, crawl, manual }
    let source: Source
    let query: String
    let postalCode: PostalCodeID
    let discoveredAt: Timestamp
}

struct PostalAddress: Codable, Hashable, Sendable {
    let street: String?
    let city: String?
    let state: String?
    let postalCode: String?

    var formatted: String {
        [street, city, state, postalCode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct ProspectCandidate: Identifiable, Hashable, Sendable {
    let id: ProspectID
    let name: String
    let websiteURL: URL
    let phoneNumber: String?
    let address: PostalAddress
    let latitude: Double
    let longitude: Double
    let provenance: ProspectProvenance

    func persisted(at timestamp: Timestamp = .init(rawValue: Date())) -> ProspectRecord {
        ProspectRecord(
            id: id, name: name, websiteURL: websiteURL, phoneNumber: phoneNumber,
            address: address, latitude: latitude, longitude: longitude,
            crawlStatus: .notStarted, assignedTeamMemberID: nil,
            relevance: .init(), provenance: [provenance], createdAt: timestamp, updatedAt: timestamp
        )
    }
}

struct ProspectRecord: Identifiable, Codable, Hashable, Sendable {
    let id: ProspectID
    var name: String
    var websiteURL: URL
    var phoneNumber: String?
    var address: PostalAddress
    var latitude: Double
    var longitude: Double
    var crawlStatus: CrawlStatus
    var assignedTeamMemberID: TeamMemberID?
    var relevance: Relevance
    var provenance: [ProspectProvenance]
    let createdAt: Timestamp
    var updatedAt: Timestamp
}

/// An immutable snapshot of one completed prospect search.
struct SearchHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let searchedAt: Date
    let results: [ProspectRecord]
    /// The exact terms and locations used to produce this snapshot. Optional so
    /// history written by earlier app versions remains decodable.
    let keywords: [String]?
    let locations: [String]?

    init(
        id: UUID = UUID(),
        searchedAt: Date = Date(),
        results: [ProspectRecord],
        keywords: [String]? = nil,
        locations: [String]? = nil
    ) {
        self.id = id
        self.searchedAt = searchedAt
        self.results = results
        self.keywords = keywords
        self.locations = locations
    }

    var title: String {
        searchedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

enum SearchHistoryStore {
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let directory = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("FireProspect", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("search-history.json")
    }

    static func load(from url: URL? = nil) -> [SearchHistoryEntry] {
        do {
            let source = try (url ?? defaultURL())
            let data = try Data(contentsOf: source)
            return try JSONDecoder().decode([SearchHistoryEntry].self, from: data)
                .sorted { $0.searchedAt > $1.searchedAt }
        } catch {
            return []
        }
    }

    static func save(_ entries: [SearchHistoryEntry], to url: URL? = nil) throws {
        let destination = try (url ?? defaultURL())
        let data = try JSONEncoder().encode(entries.sorted { $0.searchedAt > $1.searchedAt })
        try data.write(to: destination, options: .atomic)
    }
}

/// A separately persisted home-page feed. Clearing it never deletes the full search archive.
enum RecentSearchStore {
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        try SearchHistoryStore.defaultURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("recent-searches.json")
    }

    static func load(fallback: [SearchHistoryEntry], from url: URL? = nil) -> [SearchHistoryEntry] {
        guard let source = try? (url ?? defaultURL()), FileManager.default.fileExists(atPath: source.path) else { return fallback }
        guard let data = try? Data(contentsOf: source), let entries = try? JSONDecoder().decode([SearchHistoryEntry].self, from: data) else { return [] }
        return entries.sorted { $0.searchedAt > $1.searchedAt }
    }

    static func save(_ entries: [SearchHistoryEntry], to url: URL? = nil) throws {
        try JSONEncoder().encode(entries).write(to: try (url ?? defaultURL()), options: .atomic)
    }
}

struct ProspectList: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var prospects: [ProspectRecord]
    let createdAt: Date

    init(id: UUID = UUID(), name: String, prospects: [ProspectRecord] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.prospects = prospects
        self.createdAt = createdAt
    }
}

enum ProspectListStore {
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let directory = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FireProspect", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("prospect-lists.json")
    }

    static func load(from url: URL? = nil) -> [ProspectList] {
        guard let source = try? (url ?? defaultURL()), let data = try? Data(contentsOf: source) else { return [] }
        return (try? JSONDecoder().decode([ProspectList].self, from: data)) ?? []
    }

    static func save(_ lists: [ProspectList], to url: URL? = nil) throws {
        try JSONEncoder().encode(lists).write(to: try (url ?? defaultURL()), options: .atomic)
    }

    static func adding(_ prospect: ProspectRecord, to listID: UUID, in lists: [ProspectList]) -> [ProspectList] {
        var updated = lists
        guard let index = updated.firstIndex(where: { $0.id == listID }) else { return lists }
        if let existing = updated[index].prospects.firstIndex(where: { $0.id == prospect.id }) {
            updated[index].prospects[existing] = prospect
        } else {
            updated[index].prospects.append(prospect)
        }
        return updated
    }
}

struct TeamMember: Identifiable, Codable, Hashable, Sendable {
    let id: TeamMemberID
    var name: String
    var email: String
    var role: String
    var isActive: Bool
    let createdAt: Timestamp
    var updatedAt: Timestamp
}

struct ProspectRowModel: Identifiable, Hashable, Sendable {
    let id: ProspectID
    let name: String
    let address: String
    let phone: String
    let websiteURL: URL
    let crawlStatus: CrawlStatus
    let relevanceScore: Double?

    init(record: ProspectRecord) {
        id = record.id
        name = record.name
        address = record.address.formatted.isEmpty ? "N/A" : record.address.formatted
        phone = record.phoneNumber ?? "N/A"
        websiteURL = record.websiteURL
        crawlStatus = record.crawlStatus
        relevanceScore = record.relevance.score
    }
}

struct PersonnelExtraction: Codable, Hashable, Sendable {
    let people: [Person]

    struct Person: Codable, Identifiable, Hashable, Sendable {
        var id: String { [name, title, email, phone].compactMap { $0 }.joined(separator: "|") }
        let name: String?
        let title: String?
        let email: String?
        let phone: String?

        init(name: String? = nil, title: String? = nil, email: String? = nil, phone: String? = nil) {
            self.name = name
            self.title = title
            self.email = email
            self.phone = phone
        }
    }
}
