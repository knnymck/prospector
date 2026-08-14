import XCTest
@testable import FireProspect

final class FireProspectTests: XCTestCase {
    func testClearingRecentSearchesDoesNotClearSearchHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json")
        let recentURL = directory.appendingPathComponent("recent.json")
        let entry = SearchHistoryEntry(results: [])

        try SearchHistoryStore.save([entry], to: historyURL)
        try RecentSearchStore.save([], to: recentURL)

        XCTAssertEqual(SearchHistoryStore.load(from: historyURL), [entry])
        XCTAssertEqual(RecentSearchStore.load(fallback: [entry], from: recentURL), [])
    }

    func testProspectListsPersistAndDoNotDuplicateACompany() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destination) }
        let record = ProspectRecord(
            id: ProspectID(rawValue: "example.com"), name: "Example", websiteURL: URL(string: "https://example.com")!,
            phoneNumber: nil, address: PostalAddress(street: nil, city: "Portland", state: "ME", postalCode: "04101"),
            latitude: 0, longitude: 0, crawlStatus: .notStarted, assignedTeamMemberID: nil, relevance: Relevance(),
            provenance: [], createdAt: Timestamp(rawValue: .distantPast), updatedAt: Timestamp(rawValue: .distantPast)
        )
        let list = ProspectList(name: "Priority")
        var lists = ProspectListStore.adding(record, to: list.id, in: [list])
        lists = ProspectListStore.adding(record, to: list.id, in: lists)
        try ProspectListStore.save(lists, to: destination)

        XCTAssertEqual(ProspectListStore.load(from: destination).first?.prospects, [record])
    }

    func testSearchAreaKeepsSelectedCityAndDropsHouston() {
        let tyler = PostalCodeRecord(
            id: PostalCodeID(rawValue: "75701"),
            cityName: "Tyler",
            stateID: StateID(rawValue: "TX"),
            stateName: "Texas",
            countyName: "Smith",
            latitude: 32.3513,
            longitude: -95.3011
        )
        let area = SearchArea(
            postalCodes: [tyler],
            selectedCityIDs: [CityID(stateID: StateID(rawValue: "TX"), normalizedName: "Tyler")],
            selectedStates: [StateID(rawValue: "TX")],
            includesEveryCityInSelectedStates: false
        )

        XCTAssertTrue(area.contains(prospect(city: "Tyler", state: "TX", postalCode: "75701", latitude: 32.35, longitude: -95.30)))
        XCTAssertTrue(area.contains(prospect(city: "Tyler", state: "Texas", postalCode: nil, latitude: 0, longitude: 0)))
        XCTAssertTrue(area.contains(prospect(city: nil, state: nil, postalCode: "75701-1842", latitude: 0, longitude: 0)))
        XCTAssertFalse(area.contains(prospect(city: "Houston", state: "TX", postalCode: "77002", latitude: 29.76, longitude: -95.37)))
        XCTAssertFalse(area.contains(prospect(city: "Houston", state: "Texas", postalCode: nil, latitude: 29.76, longitude: -95.37)))
    }

    func testSearchAreaAllCitiesInStateIncludesHouston() {
        let houston = PostalCodeRecord(
            id: PostalCodeID(rawValue: "77002"),
            cityName: "Houston",
            stateID: StateID(rawValue: "TX"),
            stateName: "Texas",
            countyName: "Harris",
            latitude: 29.76,
            longitude: -95.37
        )
        let area = SearchArea(
            postalCodes: [houston],
            selectedCityIDs: [],
            selectedStates: [StateID(rawValue: "TX")],
            includesEveryCityInSelectedStates: true
        )

        XCTAssertTrue(area.contains(prospect(city: "Houston", state: "TX", postalCode: "77002", latitude: 29.76, longitude: -95.37)))
        XCTAssertFalse(area.contains(prospect(city: "Shreveport", state: "LA", postalCode: "71101", latitude: 32.52, longitude: -93.75)))
    }

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

    func testLocalModelManifestUsesTheCheckpointFormalName() {
        XCTAssertEqual(LocalModelService.manifest.displayName, "On-device AI")
        XCTAssertEqual(LocalModelService.manifest.repositoryID, "mlx-community/gemma-3-1b-it-4bit")
    }

    func testModelKeywordValidationPreservesPizzaAndRejectsImplementationWords() {
        let keywords = LocalModelService.validatedModelKeywords(
            source: " pizza ",
            keywords: ["MapKit", "search", "pizza", "Pizzeria", "pizza restaurant", "query"]
        )

        XCTAssertEqual(keywords, ["pizza", "Pizzeria", "pizza restaurant"])
    }

    func testModelKeywordValidationAlwaysIncludesExactSourceAndEnforcesLimit() {
        let keywords = LocalModelService.validatedModelKeywords(
            source: "Civil Engineering",
            keywords: ["Structural Engineers", "Civil Consultants", "Engineering Firm", "Surveyors", "Construction"]
        )

        XCTAssertEqual(keywords.first, "Civil Engineering")
        XCTAssertEqual(keywords.count, KeywordExpansion.maximumKeywordCount)
    }

    func testKeywordPromptsAreGenericAndUseTheRuntimeCategory() {
        let prompts = LocalModelService.keywordExpansionPrompts(for: "Landscape Architecture")

        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts.allSatisfy { $0.contains("Input: Landscape Architecture") })
        XCTAssertFalse(prompts.joined().localizedCaseInsensitiveContains("pizza"))
        XCTAssertFalse(prompts.joined().localizedCaseInsensitiveContains("civil engineering"))
    }

    func testKeywordJSONContractDecodesAndSanitizesCivilEngineeringResponse() {
        let json = #"{"source":"civil engineering","keywords":["civil engineering","structural engineering firm","MapKit","civil engineering consultant"]}"#
        let expansion = LocalModelService.decodeKeywordExpansion(json, expectedSource: "civil engineering")

        XCTAssertEqual(expansion?.keywords, ["civil engineering", "structural engineering firm", "civil engineering consultant"])
        XCTAssertNil(LocalModelService.decodeKeywordExpansion(#"{"source":"wrong","keywords":["firm"]}"#, expectedSource: "civil engineering"))
    }

    func testNoModelImmediatelyUsesOriginalKeyword() async {
        let model = ModelStub(capability: .notInstalled)
        let result = await KeywordExpansionResolver(model: model, timeout: .seconds(1)).resolve("Civil Engineering")
        XCTAssertEqual(result.expansion.keywords, ["Civil Engineering"])
        let expansionCalls = await model.expansionCallCount
        XCTAssertEqual(expansionCalls, 1)
    }

    func testReadyModelUsesGeneratedKeywords() async throws {
        let generated = try KeywordExpansion(source: "Civil Engineering", keywords: ["Structural Engineers", "Civil Consultants"])
        let model = ModelStub(capability: .available, expansion: .value(generated))
        let result = await KeywordExpansionResolver(model: model, timeout: .seconds(1)).resolve("Civil Engineering")
        XCTAssertEqual(result.expansion, generated)
    }

    func testMissingCheckpointIsInvalidAndDoesNotInvokeInstaller() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(LocalModelService.isValidCheckpoint(missing))
        let model = ModelStub(capability: .cacheInvalid)
        let result = await KeywordExpansionResolver(model: model, timeout: .seconds(1)).resolve("Surveyors")
        XCTAssertEqual(result.expansion.keywords, ["Surveyors"])
        let installCalls = await model.installCallCount
        XCTAssertEqual(installCalls, 0)
    }

    func testCheckpointValidationAcceptsGemma3AndRejectsOldGemma2Cache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("model.safetensors"))

        try Data(#"{"model_type":"gemma3_text"}"#.utf8).write(to: root.appendingPathComponent("config.json"))
        XCTAssertTrue(LocalModelService.isValidCheckpoint(root))

        try Data(#"{"model_type":"gemma2"}"#.utf8).write(to: root.appendingPathComponent("config.json"))
        XCTAssertFalse(LocalModelService.isValidCheckpoint(root))
    }

    func testInferenceFailureAndTimeoutFallBackWithoutFreezing() async {
        let failed = ModelStub(capability: .available, expansion: .unavailable(.loadFailed("bad weights")))
        let failedResult = await KeywordExpansionResolver(model: failed).resolve("Architects")
        XCTAssertEqual(failedResult.expansion.keywords, ["Architects"])

        let slow = ModelStub(capability: .available, delay: .seconds(2))
        let clock = ContinuousClock()
        let start = clock.now
        let result = await KeywordExpansionResolver(model: slow, timeout: .milliseconds(20)).resolve("Architects")
        XCTAssertEqual(result.expansion.keywords, ["Architects"])
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testEnrichmentWithoutModelRetainsDiscoveryAndSkipsAI() async throws {
        let link = URL(string: "https://example.com/team")!
        let discovery = DiscoveryStub(result: LinkDiscovery(links: [link], sitemapAvailability: .https, usedHomepage: false))
        let model = ModelStub(capability: .notInstalled)
        let receipt = try await SiteEnrichmentService(model: model, discoveryService: discovery)
            .enrichOnePage(website: URL(string: "https://example.com")!, apiKey: "unused")
        XCTAssertEqual(receipt.discovery.links, [link])
        XCTAssertNil(receipt.selectedURL)
        XCTAssertEqual(receipt.aiEnhancement, .skipped(.notInstalled))
        XCTAssertEqual(receipt.personnel.people, [])
        let selectionCalls = await model.selectionCallCount
        XCTAssertEqual(selectionCalls, 0)
    }

    func testLocalModelExtractsJSONFromChatOutput() {
        XCTAssertEqual(
            LocalModelService.extractJSONObject(from: "Here is the result:\n{\"ready\":true}\nDone"),
            "{\"ready\":true}"
        )
        XCTAssertEqual(LocalModelService.extractJSONObject(from: "plain response"), "plain response")
    }

    func testPersonnelSelectionAcceptsIndexAndNormalizedLegacyURL() {
        let candidates = [
            URL(string: "https://example.com/about")!,
            URL(string: "https://example.com/our-team/")!
        ]

        XCTAssertEqual(LocalModelService.resolvePersonnelURL(from: "{\"best_index\":2}", candidates: candidates), candidates[1])
        XCTAssertEqual(LocalModelService.resolvePersonnelURL(from: "Result: {\"best_url\":\"https://EXAMPLE.com/our-team\"}", candidates: candidates), candidates[1])
        XCTAssertNil(LocalModelService.resolvePersonnelURL(from: "{\"best_index\":9}", candidates: candidates))
    }

    func testSitemapAvailabilityCacheRoundTripsByHost() throws {
        let suite = "SitemapAvailabilityCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let website = URL(string: "https://Example.com/directory")!

        SitemapAvailabilityCache.store(.https, for: website, defaults: defaults)
        let links = [URL(string: "https://example.com/team")!]
        SitemapAvailabilityCache.storeLinks(links, for: website, defaults: defaults)

        XCTAssertEqual(SitemapAvailabilityCache.cached(for: URL(string: "http://example.com/other")!, defaults: defaults), .https)
        XCTAssertEqual(SitemapAvailabilityCache.links(for: website, defaults: defaults), links)
    }

    @MainActor
    func testFirecrawlActivityStoreRoundTripsAndCalculatesObservedCredits() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destination) }
        let activity = FirecrawlActivity(
            website: URL(string: "https://example.com")!,
            selectedPage: URL(string: "https://example.com/team")!,
            usedMapFallback: false,
            creditsBefore: 100,
            creditsAfter: 67,
            outcome: "Complete"
        )

        try FirecrawlActivityStore.append(activity, to: destination)

        XCTAssertEqual(FirecrawlActivityStore.load(from: destination), [activity])
        XCTAssertEqual(activity.creditsUsed, 33)
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

    func testNavigationDiscoveryUsesHeaderNavAndFooterAndRanksPersonnelLinks() {
        let html = """
        <html><body>
          <header><a href="/about">About</a></header>
          <main><a href="/hidden-team">Team link outside navigation</a></main>
          <nav>
            <a href="/services">Services</a>
            <a href="/company">Our Leadership Team</a>
            <a href="https://other.example/people">External People</a>
          </nav>
          <footer><a href="/professionals#top">Our Professionals</a></footer>
        </body></html>
        """

        let links = SiteLinkDiscoveryService.navigationLinks(
            in: Data(html.utf8),
            baseURL: URL(string: "https://example.com")!
        )

        XCTAssertEqual(links.first?.absoluteString, "https://example.com/company")
        XCTAssertTrue(links.contains(URL(string: "https://example.com/professionals")!))
        XCTAssertTrue(links.contains(URL(string: "https://example.com/about")!))
        XCTAssertFalse(links.contains(URL(string: "https://example.com/hidden-team")!))
        XCTAssertFalse(links.contains(URL(string: "https://other.example/people")!))
    }

    func testTeamPageParserFindsProfileLinksAndDecodesObfuscatedMailto() {
        let teamHTML = """
        <html><body>
          <a href="https://g4gr.com/our-team/ronald-enamorado/"><img alt="Ronald"></a>
          <a href="https://g4gr.com/our-team/">Our Team</a>
          <a href="https://g4gr.com/our-team/page/2">Page 2</a>
          <a href="https://g4gr.com/wp-json/oembed/1.0/embed?url=https://g4gr.com/our-team/">embed</a>
          <a href="https://other.example/our-team/someone/">external</a>
        </body></html>
        """
        let teamPage = URL(string: "https://g4gr.com/our-team/")!
        let profiles = TeamPagePersonnelParser.profileURLs(in: teamHTML, teamPage: teamPage)
        XCTAssertEqual(profiles, [URL(string: "https://g4gr.com/our-team/ronald-enamorado/")!])

        let profileHTML = """
        <html><head><meta property="og:title" content="Ronald Enamorado - G4GR"></head>
        <body>
          <h1>Ronald Enamorado</h1>
          <h3>Senior Service Technician</h3>
          <a href="mailto:&#114;on&#097;&#108;&#100;&#046;&#101;na&#109;&#111;r&#097;&#100;o&#064;&#103;&#052;&#103;r.&#099;om">Email</a>
          <a href="tel:832-888-0702">Call</a>
          <footer>
            <a href="tel:817-691-5328">Office</a>
            <a href="tel:817-691-5328">Office</a>
          </footer>
        </body></html>
        """
        let people = TeamPagePersonnelParser.people(
            in: profileHTML,
            pageURL: URL(string: "https://g4gr.com/our-team/ronald-enamorado/")!
        )
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.name, "Ronald Enamorado")
        XCTAssertEqual(people.first?.title, "Senior Service Technician")
        XCTAssertEqual(people.first?.email, "ronald.enamorado@g4gr.com")
        XCTAssertEqual(people.first?.phone, "832-888-0702")
    }

    func testTeamPageParserReadsPeopleListedOnTheSamePage() {
        let html = """
        <html><body>
          <h2>Jane Doe</h2>
          <p>Office Manager</p>
          <a href="mailto:jane@example.com">jane@example.com</a>
          <a href="tel:555-0100">555-0100</a>
        </body></html>
        """
        let people = TeamPagePersonnelParser.people(in: html, pageURL: URL(string: "https://example.com/team")!)
        XCTAssertEqual(people.first?.email, "jane@example.com")
        XCTAssertEqual(people.first?.name, "Jane Doe")
        XCTAssertEqual(people.first?.phone, "555-0100")
    }

    func testSiteEmailPolicyKeepsPersonalCompanyAddresses() {
        XCTAssertTrue(SiteEmailPolicy.isPersonalCompanyEmail("ronald.enamorado@g4gr.com", siteHost: "www.g4gr.com"))
        XCTAssertFalse(SiteEmailPolicy.isPersonalCompanyEmail("info@g4gr.com", siteHost: "g4gr.com"))
        XCTAssertFalse(SiteEmailPolicy.isPersonalCompanyEmail("sales@g4gr.com", siteHost: "g4gr.com"))
        XCTAssertFalse(SiteEmailPolicy.isPersonalCompanyEmail("jane@gmail.com", siteHost: "g4gr.com"))
        XCTAssertTrue(SiteEmailPolicy.hasCompanyContacts([
            PersonnelExtraction.Person(email: "ronald.enamorado@g4gr.com")
        ], siteHost: "g4gr.com"))
        XCTAssertFalse(SiteEmailPolicy.hasCompanyContacts([
            PersonnelExtraction.Person(email: "info@g4gr.com")
        ], siteHost: "g4gr.com"))
    }

    func testHeaderFooterKeepsPersonalCompanyEmailsAndDropsGenericInboxes() {
        let html = """
        <html><body>
          <header><a href="mailto:pat.lee@g4gr.com">Pat</a></header>
          <footer>
            <a href="mailto:info@g4gr.com">Info</a>
            <a href="mailto:sales@g4gr.com">Sales</a>
            Reach us at alex.kim@g4gr.com
          </footer>
          <main><a href="mailto:someone@elsewhere.com">Ignore</a></main>
        </body></html>
        """
        let people = TeamPagePersonnelParser.headerFooterPeople(in: html, siteHost: "g4gr.com")
        let emails = Set(people.compactMap(\.email))
        XCTAssertEqual(emails, ["pat.lee@g4gr.com", "alex.kim@g4gr.com"])
    }

    func testSitemapChildrenAreTheLayerBelowTheTeamPage() {
        let team = URL(string: "https://g4gr.com/our-team/")!
        let children = TeamPagePersonnelParser.childPages(in: [
            team,
            URL(string: "https://g4gr.com/our-team/ronald-enamorado/")!,
            URL(string: "https://g4gr.com/our-story/")!,
            URL(string: "https://g4gr.com/our-team/jeff-ryall/")!
        ], under: team)
        XCTAssertEqual(children.map(\.path), ["/our-team/ronald-enamorado/", "/our-team/jeff-ryall/"])
    }

    func testDeeperLookupDecisionReadsExploreIndexesAndCanSkip() {
        let children = [
            URL(string: "https://g4gr.com/our-team/ronald-enamorado/")!,
            URL(string: "https://g4gr.com/our-team/jeff-ryall/")!
        ]
        let explore = LocalModelService.resolveDeeperLookupDecision(
            from: "{\"explore\":true,\"indexes\":[2]}",
            candidates: children,
            fallback: children
        )
        XCTAssertTrue(explore.shouldExplore)
        XCTAssertEqual(explore.selectedURLs, [children[1]])

        let skip = LocalModelService.resolveDeeperLookupDecision(
            from: "{\"explore\":false}",
            candidates: children,
            fallback: children
        )
        XCTAssertFalse(skip.shouldExplore)
        XCTAssertTrue(skip.selectedURLs.isEmpty)

        XCTAssertFalse(DeeperLookupDecision.heuristic(children: children, hasDomainContacts: true).shouldExplore)
        XCTAssertTrue(DeeperLookupDecision.heuristic(children: children, hasDomainContacts: false).shouldExplore)
        XCTAssertFalse(DeeperLookupDecision.heuristic(children: [], hasDomainContacts: false).shouldExplore)
    }

    func testSitemapSnapshotRoundTripsByHost() throws {
        let suite = "SitemapSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let website = URL(string: "https://g4gr.com/")!
        let snapshot = SitemapSnapshot(
            availability: .https,
            urls: [URL(string: "https://g4gr.com/our-team/")!, URL(string: "https://g4gr.com/our-team/ronald-enamorado/")!],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        SitemapAvailabilityCache.storeSnapshot(snapshot, for: website, defaults: defaults)
        let loaded = SitemapAvailabilityCache.snapshot(for: website, defaults: defaults)
        XCTAssertEqual(loaded?.availability, .https)
        XCTAssertEqual(loaded?.urls, snapshot.urls)
    }

    func testTeamPageParserMergesDuplicatePeopleByEmail() {
        let merged = TeamPagePersonnelParser.merging([
            PersonnelExtraction.Person(name: "Jane Doe", title: nil, email: "jane@example.com", phone: nil),
            PersonnelExtraction.Person(name: "Jane Doe", title: "Manager", email: "jane@example.com", phone: "555-0100")
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.title, "Manager")
        XCTAssertEqual(merged.first?.phone, "555-0100")
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

    private func prospect(
        city: String?,
        state: String?,
        postalCode: String?,
        latitude: Double,
        longitude: Double
    ) -> ProspectCandidate {
        ProspectCandidate(
            id: ProspectID(rawValue: "\(city ?? "x").example"),
            name: city ?? "Business",
            websiteURL: URL(string: "https://\(city ?? "x").example")!,
            phoneNumber: nil,
            address: PostalAddress(street: nil, city: city, state: state, postalCode: postalCode),
            latitude: latitude,
            longitude: longitude,
            provenance: .init(
                source: .mapKit,
                query: "hunting",
                postalCode: PostalCodeID(rawValue: postalCode ?? "00000"),
                discoveredAt: Timestamp(rawValue: .distantPast)
            )
        )
    }
}

private actor ModelStub: LocalModelServing {
    let reportedCapability: LocalModelCapability
    let expansion: LocalModelResult<KeywordExpansion>
    let delay: Duration?
    private(set) var expansionCallCount = 0
    private(set) var selectionCallCount = 0
    private(set) var installCallCount = 0

    init(capability: LocalModelCapability, expansion: LocalModelResult<KeywordExpansion>? = nil, delay: Duration? = nil) {
        self.reportedCapability = capability
        self.expansion = expansion ?? .unavailable(capability)
        self.delay = delay
    }
    func capability() -> LocalModelCapability { reportedCapability }
    func expandIfAvailable(_ category: String) async -> LocalModelResult<KeywordExpansion> {
        expansionCallCount += 1
        if let delay { try? await Task.sleep(for: delay) }
        return expansion
    }
    func selectPersonnelURLIfAvailable(from candidates: [URL]) -> LocalModelResult<URL> {
        selectionCallCount += 1
        return .unavailable(reportedCapability)
    }
    func decideDeeperLookupIfAvailable(teamPage: URL, childPages: [URL], hasDomainContacts: Bool) -> LocalModelResult<DeeperLookupDecision> {
        .unavailable(reportedCapability)
    }
}

private struct DiscoveryStub: SiteLinkDiscovering {
    let result: LinkDiscovery
    var sitemap: SitemapSnapshot = .empty
    func discover(on website: URL) async throws -> LinkDiscovery { result }
    func loadSitemap(for website: URL) async -> SitemapSnapshot { sitemap }
}
