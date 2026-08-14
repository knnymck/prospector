import XCTest
@testable import FireProspect

final class FireProspectTests: XCTestCase {
    func testCityIDIncludesStateAndNormalizesName() {
        let maine = CityID(stateID: StateID(rawValue: "me"), normalizedName: "  Pórtland ")
        let oregon = CityID(stateID: StateID(rawValue: "OR"), normalizedName: "Portland")

        XCTAssertEqual(maine.stateID, StateID(rawValue: "ME"))
        XCTAssertEqual(maine.normalizedName, "portland")
        XCTAssertNotEqual(maine, oregon)
    }

    func testEmptyScopesResolveNoPostalCodes() async throws {
        let repository = BundledGeographyRepository(bundle: Bundle(for: Self.self))

        XCTAssertEqual(try await repository.postalCodes(for: .selectedCities([])), [])
        XCTAssertEqual(try await repository.postalCodes(for: .allCities(in: [])), [])
    }

    func testCSVExporterQuotesAndMitigatesFormulas() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("prospects.csv")
        let timestamp = Timestamp(rawValue: Date(timeIntervalSince1970: 0))
        let record = ProspectRecord(
            id: ProspectID(rawValue: "example.com"),
            name: "=HYPERLINK(\"bad\"), Inc.",
            websiteURL: URL(string: "https://example.com")!,
            phoneNumber: nil,
            address: PostalAddress(street: nil, city: "Portland", state: "ME", postalCode: "04101"),
            latitude: 0,
            longitude: 0,
            crawlStatus: .notStarted,
            assignedTeamMemberID: nil,
            relevance: Relevance(),
            provenance: [.init(source: .mapKit, query: "engineers", postalCode: .init(rawValue: "04101"), discoveredAt: timestamp)],
            createdAt: timestamp,
            updatedAt: timestamp
        )

        try CSVExporter().exportProspects([record], to: destination, exportedAt: timestamp)
        let csv = try String(contentsOf: destination, encoding: .utf8)

        XCTAssertTrue(csv.contains("\r\n"))
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"bad\"\"), Inc.\""))
        XCTAssertTrue(csv.contains(CSVExporter.prospectSchemaVersion))
    }

    func testKeywordExpansionBoundsAndDeduplicates() throws {
        let expansion = try KeywordExpansion(
            source: "Civil Engineering",
            keywords: ["Civil Engineering", " civil engineering ", "Structural Engineers"]
        )

        XCTAssertEqual(expansion.keywords, ["Civil Engineering", "Structural Engineers"])
        XCTAssertThrowsError(try KeywordExpansion(source: "Civil Engineering", keywords: ["1", "2", "3", "4", "5", "6"]))
    }

    func testKeywordExpansionFallbackPreservesInput() {
        XCTAssertEqual(KeywordExpansion.fallback(for: "Civil Engineering").keywords, ["Civil Engineering"])
    }

    func testLocalModelExtractsJSONFromChatOutput() {
        XCTAssertEqual(
            LocalModelService.extractJSONObject(from: "Here is the result:\n{\"ready\":true}\nDone"),
            "{\"ready\":true}"
        )
        XCTAssertEqual(LocalModelService.extractJSONObject(from: "plain response"), "plain response")
    }

    func testEnrichmentCandidateAndPageLimitsStayBounded() {
        XCTAssertEqual(SiteLinkDiscoveryService.maximumCandidateCount, 30)
        XCTAssertEqual(SitemapAvailability.httpOnly.rawValue, "HTTP-only sitemap")
    }

    func testSitemapDetectionRejectsHTMLSoft404s() {
        XCTAssertTrue(SiteLinkDiscoveryService.isSitemapDocument(Data("<?xml version=\"1.0\"?><urlset></urlset>".utf8)))
        XCTAssertTrue(SiteLinkDiscoveryService.isSitemapDocument(Data("<sitemapindex></sitemapindex>".utf8)))
        XCTAssertFalse(SiteLinkDiscoveryService.isSitemapDocument(Data("<html><h1>Not found</h1></html>".utf8)))
    }

    func testSafeFilenameRemovesPathCharacters() {
        XCTAssertEqual(
            CSVExporter.safeFilename(stem: "../../Civil / Engineering"),
            "prospects-civil-engineering.csv"
        )
    }

    func testCityDisplayNameUsesFullStateName() {
        let city = City(
            id: CityID(stateID: StateID(rawValue: "CA"), normalizedName: "San Francisco"),
            name: "San Francisco",
            stateName: "California"
        )

        XCTAssertEqual(city.displayName, "San Francisco, California")
    }

    func testBundledStateAbbreviationsResolveToFullNames() {
        XCTAssertEqual(
            BundledGeographyRepository.displayName(for: StateID(rawValue: "CA"), fallback: "CA"),
            "California"
        )
        XCTAssertEqual(
            BundledGeographyRepository.displayName(for: StateID(rawValue: "PR"), fallback: "PR"),
            "Puerto Rico"
        )
    }

    func testSearchHistoryRoundTripsNewestFirst() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destination) }
        let old = SearchHistoryEntry(searchedAt: Date(timeIntervalSince1970: 100), results: [])
        let new = SearchHistoryEntry(
            searchedAt: Date(timeIntervalSince1970: 200),
            results: [],
            keywords: ["Civil Engineering", "Structural Engineer"],
            locations: ["Portland, Maine"]
        )

        try SearchHistoryStore.save([old, new], to: destination)

        let loaded = SearchHistoryStore.load(from: destination)
        XCTAssertEqual(loaded.map(\.id), [new.id, old.id])
        XCTAssertEqual(loaded.first?.keywords, new.keywords)
        XCTAssertEqual(loaded.first?.locations, new.locations)
    }
}
