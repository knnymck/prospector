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
