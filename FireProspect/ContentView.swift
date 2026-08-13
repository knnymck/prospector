import SwiftUI
import UniformTypeIdentifiers

// MARK: - Flow Layout for Tag/Pill Wrapping

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            x += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
        height = y + maxHeightInRow
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var maxHeightInRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + width, x > bounds.minX {
                x = bounds.minX
                y += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            maxHeightInRow = max(maxHeightInRow, size.height)
        }
    }
}

// MARK: - Root Application Window

struct ContentView: View {
    @State private var selectedDestination: SidebarDestination? = .search
    @State private var searchResults: [ProspectRecord] = []
    @State private var searchHistory = SearchHistoryStore.load()

    enum SidebarDestination: Hashable, Identifiable {
        case search
        case prospects
        case history(UUID)

        var id: String { identifier }

        var identifier: String {
            switch self {
            case .search: "search"
            case .prospects: "prospects"
            case .history(let id): "history.\(id.uuidString)"
            }
        }

        var title: String {
            switch self {
            case .search:
                "Search"
            case .prospects:
                "Prospects"
            case .history(let id):
                id.uuidString
            }
        }

        var systemImage: String {
            switch self {
            case .search:
                "magnifyingglass"
            case .prospects:
                "person.2"
            case .history:
                "clock"
            }
        }
    }

    private var historyByDay: [(date: Date, entries: [SearchHistoryEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: searchHistory) { calendar.startOfDay(for: $0.searchedAt) }
        return groups.keys.sorted(by: >).map { date in
            (date, groups[date, default: []].sorted { $0.searchedAt > $1.searchedAt })
        }
    }

    private var selectedHistory: SearchHistoryEntry? {
        guard case .history(let id)? = selectedDestination else { return nil }
        return searchHistory.first { $0.id == id }
    }

    private func recordSearch(_ results: [ProspectRecord]) {
        let entry = SearchHistoryEntry(results: results)
        searchHistory.insert(entry, at: 0)
        try? SearchHistoryStore.save(searchHistory)
        searchResults = results
        selectedDestination = .history(entry.id)
    }

    @ViewBuilder
    private func destinationRow(_ destination: SidebarDestination) -> some View {
        Label(destination.title, systemImage: destination.systemImage)
            .tag(destination)
            .accessibilityLabel(destination.title)
            .accessibilityIdentifier("sidebar.destination.\(destination.identifier)")
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedDestination) {
                    Section {
                        destinationRow(.search)
                        DisclosureGroup {
                            if searchHistory.isEmpty {
                                Text("No saved searches")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else {
                                ForEach(historyByDay, id: \.date) { group in
                                    DisclosureGroup(group.date.formatted(date: .abbreviated, time: .omitted)) {
                                        ForEach(group.entries) { entry in
                                            Label(entry.searchedAt.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                                                .badge(entry.results.count)
                                                .tag(SidebarDestination.history(entry.id))
                                                .accessibilityLabel("Search from \(entry.title), \(entry.results.count) prospects")
                                        }
                                    }
                                }
                            }
                        } label: {
                            destinationRow(.prospects)
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Application navigation")
                .accessibilityIdentifier("sidebar.navigation")
            }
            .navigationTitle("FireProspect")
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            Group {
                switch selectedDestination ?? .search {
                case .search:
                    SearchTabView(searchResults: $searchResults, onSearchCompleted: recordSearch)
                case .prospects:
                    ProspectsView(searchResults: searchResults)
                case .history:
                    ProspectsView(searchResults: selectedHistory?.results ?? [])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppBackground())
            .navigationTitle(selectedHistory?.title ?? (selectedDestination ?? .search).title)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSearchDestination)) { _ in
            selectedDestination = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .showProspectsDestination)) { _ in
            selectedDestination = .prospects
        }
        .frame(minWidth: 900, minHeight: 720)
        .background(AppBackground())
    }
}

private struct AppBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

// MARK: - Search Tab View

struct SearchTabView: View {
    @Binding var searchResults: [ProspectRecord]
    let onSearchCompleted: ([ProspectRecord]) -> Void
    @State private var category: String = "Civil Engineering"
    
    // Unified State & City selection state
    @State private var selectedStates: Set<StateID> = []
    @State private var stateSearch = ""
    @State private var isStateDropdownFocused = false
    
    @State private var selectedCityIDs: Set<CityID> = []
    @State private var selectAllCities = false
    @State private var allStates: [StateRecord] = []
    @State private var citySuggestions: [City] = []
    @State private var targetZips: [PostalCodeRecord] = []
    @State private var geographyError: String?
    @State private var citySearch = ""
    
    // Execution and results state
    @State private var isSearching = false
    @State private var logOutput = "READY // Select target state and city vectors to initiate search cycle."
    @State private var progressText = ""
    @State private var expansionStatus = "Keyword expansion has not run."
    @State private var acceptedCount = 0
    @State private var excludedCount = 0
    @State private var warnings: [String] = []
    
    private var filteredStateSuggestions: [StateRecord] {
        allStates.filter { state in
            !selectedStates.contains(state.id) &&
            (stateSearch.isEmpty || state.name.localizedCaseInsensitiveContains(stateSearch) ||
             state.id.rawValue.localizedCaseInsensitiveContains(stateSearch))
        }
    }

    private var filteredCities: [City] { citySuggestions }

    private var searchScope: SearchScope {
        selectAllCities ? .allCities(in: selectedStates) : .selectedCities(selectedCityIDs)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                categoryInputSection
                geographyConnectorSection
                metricsSection
                searchStatusSection
                systemLogSection
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("detail.search")
        .task { await loadGeography() }
        .task(id: selectedStates) { await refreshCitiesAndZIPs() }
        .task(id: citySearch) { await refreshCities() }
        .task(id: searchScope) { await refreshZIPs() }
    }
    
    // MARK: - Subviews
    
    private var categoryInputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Business category", systemImage: "building.2")
                .font(.headline)
            
            TextField("Civil Engineering", text: $category)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
        }
    }
    
    private var geographyConnectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Search area", systemImage: "map")
                .font(.headline)
            
            HStack(alignment: .top, spacing: 20) {
                targetStatesColumn
                targetCitiesColumn
            }
            
            unifiedLocationPillsView
        }
    }
    
    private var targetStatesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("States")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selectedStates.count) ACTIVE")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 0) {
                TextField("Search states", text: $stateSearch, onEditingChanged: { focused in
                    isStateDropdownFocused = focused
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .default))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
                
                if isStateDropdownFocused || !stateSearch.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredStateSuggestions) { state in
                                Button(action: {
                                    selectedStates.insert(state.id)
                                    stateSearch = ""
                                }) {
                                    HStack {
                                        Text(state.name)
                                            .font(.system(size: 11, design: .default))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color.primary.opacity(0.03))
                            }
                        }
                    }
                    .frame(maxHeight: 100)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        Rectangle()
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                }
            }
            
            // Active States List
            if !selectedStates.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(Array(selectedStates).sorted(), id: \.self) { stateID in
                        let name = allStates.first(where: { $0.id == stateID })?.name ?? stateID.rawValue
                        RemovablePill(label: name) {
                            removeState(stateID)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private var targetCitiesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cities")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Toggle("All cities", isOn: $selectAllCities)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .disabled(selectedStates.isEmpty)
            }
            
            TextField(selectedStates.isEmpty ? "Select a state first" : "Search cities", text: $citySearch)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .default))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .disabled(selectAllCities || selectedStates.isEmpty)
                .opacity((selectAllCities || selectedStates.isEmpty) ? 0.4 : 1.0)
            
            // Filtered City List
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if selectedStates.isEmpty {
                        Text("No state selected. Select a state to populate cities.")
                            .font(.system(size: 10, design: .default))
                            .italic()
                            .foregroundStyle(.tertiary)
                            .padding(8)
                    } else if filteredCities.isEmpty {
                        Text("No cities matching filter.")
                            .font(.system(size: 10, design: .default))
                            .italic()
                            .foregroundStyle(.tertiary)
                            .padding(8)
                    } else {
                        ForEach(filteredCities) { city in
                            Button(action: {
                                addCityToSelection(city)
                            }) {
                                HStack {
                                    Text(city.displayName)
                                        .font(.system(size: 11, design: .default))
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(height: 90)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .disabled(selectAllCities || selectedStates.isEmpty)
            .opacity((selectAllCities || selectedStates.isEmpty) ? 0.4 : 1.0)
        }
        .frame(maxWidth: .infinity)
    }
    
    // Unified "City, State" Pill Section
    private var unifiedLocationPillsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Selected locations")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if selectAllCities {
                    Text("All cities in selected states")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            
            if selectAllCities && selectedCityIDs.isEmpty {
                Text("All cities within selected state(s) are active. Explicit city draft is empty.")
                    .font(.system(size: 10, design: .default))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else if selectedCityIDs.isEmpty {
                Text("No locations selected. Pick a state and select cities to form unified target pills (e.g., 'Abilene, TX').")
                    .font(.system(size: 10, design: .default))
                    .italic()
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                if selectAllCities {
                    Text("Saved explicit-city draft (not active in All Cities mode):")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(selectedCities.sorted(by: { $0.displayName < $1.displayName })) { location in
                            RemovablePill(label: location.displayName) {
                                selectedCityIDs.remove(location.id)
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(minHeight: 36, maxHeight: 80)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.02))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
    
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to search")
                        .font(.headline)
                    
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(targetZips.count)")
                            .font(.system(size: 20, weight: .black, design: .monospaced))
                        
                        Text("ZIP codes")
                            .foregroundStyle(.secondary)
                    }
                    
                    Text(targetZips.isEmpty ?
                         "Choose at least one state and city to define the search area." :
                         "FireProspect will search the selected category across this area.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(action: runMultiZipSearch) {
                    Label(isSearching ? "Searching…" : "Search Prospects", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSearch)
            }
        }
        .padding(18)
        .background(Color.primary.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
    
    private var systemLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity")
                    .font(.headline)
                
                Spacer()
                
                if !progressText.isEmpty {
                    Text(progressText)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            
            Text(logOutput)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var searchStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Search intelligence", systemImage: "sparkles")
                .font(.headline)
            Text(expansionStatus)
            HStack {
                Label("\(acceptedCount) accepted", systemImage: "checkmark.circle")
                Label("\(excludedCount) excluded", systemImage: "minus.circle")
            }
            .foregroundStyle(.secondary)
            if !warnings.isEmpty {
                DisclosureGroup("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityIdentifier("search.expansion-status")
    }
    
    // MARK: - Actions & Logic
    
    private var selectedCities: [City] {
        selectedCityIDs.compactMap { id in
            citySuggestions.first(where: { $0.id == id }) ?? City(
                id: id,
                name: id.normalizedName.capitalized,
                stateName: allStates.first(where: { $0.id == id.stateID })?.name ?? id.stateID.rawValue
            )
        }
    }

    private func addCityToSelection(_ city: City) {
        selectedCityIDs.insert(city.id)
    }

    private func removeState(_ stateID: StateID) {
        selectedStates.remove(stateID)
        selectedCityIDs = selectedCityIDs.filter { $0.stateID != stateID }
    }

    @MainActor
    private func loadGeography() async {
        do {
            allStates = try await BundledGeographyRepository.shared.states()
            geographyError = nil
        } catch {
            geographyError = String(describing: error)
            logOutput = "GEOGRAPHY LOAD FAILED // \(error)"
        }
    }

    @MainActor
    private func refreshCities() async {
        do {
            citySuggestions = try await BundledGeographyRepository.shared.cities(matching: citySearch, in: selectedStates)
        } catch {
            geographyError = String(describing: error)
            citySuggestions = []
        }
    }

    @MainActor
    private func refreshZIPs() async {
        do {
            targetZips = try await BundledGeographyRepository.shared.postalCodes(for: searchScope)
            geographyError = nil
        } catch {
            geographyError = String(describing: error)
            targetZips = []
        }
    }

    @MainActor
    private func refreshCitiesAndZIPs() async {
        await refreshCities()
        await refreshZIPs()
    }

    private var canSearch: Bool {
        !isSearching &&
        !category.trimmingCharacters(in: .whitespaces).isEmpty &&
        !selectedStates.isEmpty &&
        (selectAllCities || !selectedCityIDs.isEmpty) &&
        !targetZips.isEmpty
    }
    
    private func runMultiZipSearch() {
        isSearching = true
        logOutput = "INITIATING CYCLE // Targets: \(targetZips.count) ZIP codes…\n"
        progressText = ""
        expansionStatus = "Checking and loading Gemma 4 2B…"
        acceptedCount = 0
        excludedCount = 0
        warnings = []
        searchResults.removeAll()
        
        let apiKey = KeychainHelper.getKey()
        let zipsToSearch = targetZips
        let cat = category.trimmingCharacters(in: .whitespacesAndNewlines)
        
        Task {
            let service = MapKitSearchService()
            var allResults: [ProspectID: ProspectCandidate] = [:]
            var processed = 0
            var excluded = 0
            var nonfatalWarnings: [String] = []
            let expansion: KeywordExpansion
            do {
                expansion = try await LocalModelService.shared.expand(cat)
            } catch {
                expansion = .fallback(for: cat)
                nonfatalWarnings.append("Keyword expansion unavailable; using the original category. \(error.localizedDescription)")
            }

            await MainActor.run {
                self.expansionStatus = expansion.keywords.count == 1 && expansion.keywords[0] == cat
                    ? "FALLBACK // \(cat)"
                    : "EXPANDED // \(expansion.keywords.joined(separator: " • "))"
            }
            
            for zip in zipsToSearch {
                for keyword in expansion.keywords {
                    do {
                        let results = try await service.searchZipCode(category: keyword, zip: zip)
                        for result in results {
                            if SemanticProspectPolicy.accepts(result) {
                                allResults[result.id] = result
                            } else {
                                excluded += 1
                            }
                        }
                    } catch {
                        nonfatalWarnings.append("\(zip.id.rawValue) / \(keyword): \(error.localizedDescription)")
                    }
                }
                
                processed += 1
                let current = processed
                let total = zipsToSearch.count
                let foundCount = allResults.count
                let excludedSoFar = excluded
                
                await MainActor.run {
                    self.progressText = "[\(current)/\(total)]"
                    self.logOutput = "PROCESSING // \(current) of \(total) ZIPs resolved.\nDISCOVERED // \(foundCount) unique domain vectors."
                    self.acceptedCount = foundCount
                    self.excludedCount = excludedSoFar
                }
                
                try? await Task.sleep(for: .milliseconds(300))
            }
            
            // Transform results directly into an immutable `let` array
            let items = allResults.values
                .sorted(by: { $0.name < $1.name })
                .map { $0.persisted() }
            
            // Build the log string in a mutable buffer, then lock it into a `let` constant
            var logBuffer = "CYCLE COMPLETE // Discovered \(items.count) unique domain(s) across \(zipsToSearch.count) ZIP(s).\n\n"
            if apiKey.isEmpty {
                logBuffer += "STATUS // Notice: No Firecrawl API key configured in Settings."
            } else {
                logBuffer += "STATUS // Firecrawl key validated. Ready for extraction sequence."
            }
            let finalLog = logBuffer
            let displayedWarnings = Array(nonfatalWarnings.prefix(5))
            let finalExcluded = excluded
            
            // Safely pass immutable `let` values to MainActor.run
            await MainActor.run {
                self.searchResults = items
                self.logOutput = finalLog
                self.progressText = ""
                self.acceptedCount = items.count
                self.excludedCount = finalExcluded
                self.warnings = displayedWarnings
                self.isSearching = false
                self.onSearchCompleted(items)
            }
        }
    }
    

}

// MARK: - Prospects

struct ProspectsView: View {
    let searchResults: [ProspectRecord]
    @State private var exportState: ExportState = .idle
    @State private var enrichmentMessage: String?
    @State private var isEnriching = false
    @State private var selectedProspectID: ProspectID?
    @State private var pendingProspect: ProspectRecord?
    @State private var enrichmentReceipts: [ProspectID: EnrichmentReceipt] = [:]
    @State private var remainingCredits: Int?
    @State private var creditMessage: String?

    private var rows: [NumberedProspectRow] {
        searchResults.enumerated().map { offset, record in
            NumberedProspectRow(number: offset + 1, prospect: ProspectRowModel(record: record))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prospects")
                        .font(.title2.weight(.semibold))
                    Text("\(searchResults.count) saved result\(searchResults.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(remainingCredits.map { "Firecrawl credits: \($0)" } ?? "Firecrawl credits: —")
                        .font(.callout.monospacedDigit())
                    if let creditMessage {
                        Text(creditMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("prospects.firecrawl-credits")

                Button("Export CSV", systemImage: "square.and.arrow.down") {
                    Task { await exportResultsToCSV() }
                }
                .disabled(searchResults.isEmpty || exportState.isBusy)

                Button("Test Enrichment (1 Page)", systemImage: "person.text.rectangle") {
                    pendingProspect = selectedProspect
                }
                .disabled(selectedProspect == nil || isEnriching || KeychainHelper.getKey().isEmpty)
                .help(KeychainHelper.getKey().isEmpty ? "Add a Firecrawl API key in Settings." : "Uses Firecrawl credit for exactly one selected page.")
            }

            if let message = exportState.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(exportState.isFailure ? Color.red : Color.secondary)
            }

            if let enrichmentMessage {
                Text(enrichmentMessage)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("prospects.enrichment-status")
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    "No Prospects",
                    systemImage: "person.2",
                    description: Text("Run a search to populate this workspace.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $selectedProspectID) {
                    TableColumn("#") { Text("\($0.number)").monospacedDigit() }.width(36)
                    TableColumn("Business") { Text($0.prospect.name) }
                    TableColumn("Address") { Text($0.prospect.address) }
                    TableColumn("Phone") { Text($0.prospect.phone) }
                    TableColumn("Website") { row in
                        Link(row.prospect.websiteURL.host() ?? row.prospect.websiteURL.absoluteString, destination: row.prospect.websiteURL)
                    }
                    TableColumn("Team Page") { row in
                        if let url = enrichmentReceipts[row.id]?.selectedURL {
                            Link("Open", destination: url)
                        } else { Text("—").foregroundStyle(.secondary) }
                    }
                    TableColumn("Found Emails") { row in
                        Text(foundEmails(for: row.id)).textSelection(.enabled)
                    }
                    TableColumn("Sitemap") { row in
                        Text(sitemapStatus(for: row.id))
                    }
                }
            }

            if let receipt = selectedProspectID.flatMap({ enrichmentReceipts[$0] }), !receipt.personnel.people.isEmpty {
                GroupBox("Personnel from \(receipt.selectedURL.host() ?? receipt.selectedURL.absoluteString)") {
                    Table(receipt.personnel.people) {
                        TableColumn("Name") { Text($0.name ?? "—") }
                        TableColumn("Title") { Text($0.title ?? "—") }
                        TableColumn("Email") { Text($0.email ?? "—").textSelection(.enabled) }
                    }
                    .frame(minHeight: 120)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("detail.prospects")
        .alert("Use one Firecrawl extraction credit?", isPresented: Binding(
            get: { pendingProspect != nil },
            set: { if !$0 { pendingProspect = nil } }
        ), presenting: pendingProspect) { prospect in
            Button("Cancel", role: .cancel) { pendingProspect = nil }
            Button("Extract One Page") {
                pendingProspect = nil
                Task { await enrich(prospect) }
            }
        } message: { prospect in
            Text("Gemma will choose one personnel page for \(prospect.name). Only that page will be submitted to Firecrawl.")
        }
        .task { await refreshCredits() }
    }

    private var selectedProspect: ProspectRecord? {
        searchResults.first { $0.id == selectedProspectID }
    }

    private func foundEmails(for id: ProspectID) -> String {
        let emails = enrichmentReceipts[id]?.personnel.people.compactMap(\.email)
            .filter { !$0.isEmpty } ?? []
        return emails.isEmpty ? "—" : Array(Set(emails)).sorted().joined(separator: ", ")
    }

    private func sitemapStatus(for id: ProspectID) -> String {
        guard let availability = enrichmentReceipts[id]?.discovery.sitemapAvailability else { return "Not checked" }
        switch availability {
        case .https: return "Found (HTTPS)"
        case .httpOnly: return "Found (HTTP only)"
        case .unavailable: return "Not found"
        }
    }

    @MainActor
    private func refreshCredits() async {
        let key = KeychainHelper.getKey()
        guard !key.isEmpty else {
            remainingCredits = nil
            creditMessage = "API key not configured"
            return
        }
        do {
            remainingCredits = try await FirecrawlService.shared.remainingCredits(apiKey: key)
            creditMessage = nil
        } catch {
            remainingCredits = nil
            creditMessage = "Balance unavailable"
        }
    }

    @MainActor
    private func enrich(_ prospect: ProspectRecord) async {
        isEnriching = true
        enrichmentMessage = "FREE DISCOVERY // Checking HTTPS and HTTP sitemap availability…"
        do {
            let receipt = try await SiteEnrichmentService.shared.enrichOnePage(
                website: prospect.websiteURL,
                apiKey: KeychainHelper.getKey()
            )
            enrichmentMessage = """
            COMPLETE // Exactly 1 page submitted to Firecrawl extract
            SITEMAP // \(receipt.discovery.sitemapAvailability.rawValue)
            DISCOVERY // \(receipt.usedFirecrawlMap ? "Firecrawl map fallback" : "Native Swift")
            SELECTED // \(receipt.selectedURL.absoluteString)
            PEOPLE // \(receipt.personnel.people.count)
            """
            enrichmentReceipts[prospect.id] = receipt
            await refreshCredits()
        } catch {
            enrichmentMessage = "NONFATAL FAILURE // \(error.localizedDescription)"
        }
        isEnriching = false
    }

    @MainActor
    private func exportResultsToCSV() async {
        guard !searchResults.isEmpty else { return }
        exportState = .choosingDestination

        let panel = NSSavePanel()
        panel.title = "Export Prospects to CSV"
        panel.nameFieldStringValue = CSVExporter.safeFilename(stem: "current-search")
        panel.allowedContentTypes = [.commaSeparatedText]
        let response = await panel.beginResponse()
        guard response == .OK, let destination = panel.url else {
            exportState = .cancelled
            return
        }

        exportState = .exporting
        let records = searchResults
        do {
            let receipt = try await Task.detached {
                try CSVExporter().exportProspects(records, to: destination)
            }.value
            exportState = .succeeded(receipt)
        } catch {
            exportState = .failed(error.localizedDescription)
        }
    }

    private enum ExportState {
        case idle
        case choosingDestination
        case exporting
        case succeeded(CSVExporter.Receipt)
        case cancelled
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .choosingDestination, .exporting: true
            default: false
            }
        }

        var message: String? {
            switch self {
            case .idle: nil
            case .choosingDestination: "Waiting for a save destination…"
            case .exporting: "Exporting prospects…"
            case .succeeded(let receipt): "Saved \(receipt.rowCount) prospects to \(receipt.destination.lastPathComponent)."
            case .cancelled: "Export cancelled."
            case .failed(let reason): "Export failed: \(reason)"
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }
}

private struct NumberedProspectRow: Identifiable {
    let number: Int
    let prospect: ProspectRowModel
    var id: ProspectID { prospect.id }
}

// MARK: - Reusable Removable Pill Component

struct RemovablePill: View {
    let label: String
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .default))
            
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Settings Tab View

struct SettingsTabView: View {
    @State private var firecrawlKey: String = ""
    @State private var firecrawlMessage: String = ""
    @State private var localModelMessage: String = ""
    @State private var modelIdentifier = LocalModelService.configuredModel
    @State private var localModelAvailability: LocalModelAvailability = .checking
    
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Firecrawl", systemImage: "key")
                        .font(.title3.weight(.semibold))
                    
                    Text("Required credential for automated site crawling and structured domain parsing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                SecureField("API key", text: $firecrawlKey)
                    .textFieldStyle(.roundedBorder)
                
                HStack(spacing: 16) {
                    Button(action: {
                        KeychainHelper.saveKey(firecrawlKey)
                        firecrawlMessage = "Configured — credential stored in Keychain."
                    }) {
                        Text("Save API Key")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Remove", role: .destructive) {
                        _ = KeychainHelper.deleteKey()
                        firecrawlKey = ""
                        firecrawlMessage = "Credential removed."
                    }
                    .disabled(firecrawlKey.isEmpty)
                }
                if !firecrawlMessage.isEmpty {
                    Text(firecrawlMessage).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.firecrawl-message")
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color.primary.opacity(0.02))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 12) {
                Label("Local AI model", systemImage: "cpu")
                    .font(.title3.weight(.semibold))
                Label(localModelAvailability.label, systemImage: localModelAvailability == .ready ? "checkmark.circle.fill" : "cpu")
                    .foregroundStyle(localModelAvailability == .ready ? Color.green : Color.secondary)
                    .accessibilityIdentifier("settings.local-model-status")
                Text("Keyword generation requires Gemma 4 2B through the local Ollama runtime. Model installation is optional; searches safely fall back to the original category.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Ollama model tag", text: $modelIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveModelIdentifier() }
                if localModelAvailability == .runtimeUnavailable {
                    Text("Install and launch Ollama on this Mac, then choose Check Again. FireProspect cannot install the Ollama application itself.")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Button("Check Again") { Task { await refreshLocalModel() } }
                    Button("Save Model Tag") { saveModelIdentifier() }
                    Button("Install Model") { Task { await installLocalModel() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(localModelAvailability == .ready || localModelAvailability == .runtimeUnavailable || isInstallingModel)
                }
                if !localModelMessage.isEmpty {
                    Text(localModelMessage).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.local-model-message")
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color.primary.opacity(0.02))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("detail.settings")
        .onAppear {
            firecrawlKey = KeychainHelper.getKey()
            firecrawlMessage = firecrawlKey.isEmpty ? "Not configured." : "Configured in Keychain."
            Task { await refreshLocalModel() }
        }
    }

    private var isInstallingModel: Bool {
        if case .installing = localModelAvailability { return true }
        return false
    }

    private func saveModelIdentifier() {
        LocalModelService.configure(model: modelIdentifier)
        localModelMessage = "Model tag saved. Check availability before installing."
        Task { await refreshLocalModel() }
    }

    @MainActor
    private func refreshLocalModel() async {
        localModelAvailability = .checking
        localModelAvailability = await LocalModelService.shared.availability()
    }

    @MainActor
    private func installLocalModel() async {
        localModelAvailability = .installing(nil)
        do {
            try await LocalModelService.shared.ensureInstalled { progress in
                await MainActor.run { self.localModelAvailability = .installing(progress) }
            }
            localModelAvailability = .ready
        } catch {
            localModelAvailability = await LocalModelService.shared.availability()
            localModelMessage = error.localizedDescription
        }
    }
}

private extension NSSavePanel {
    @MainActor
    func beginResponse() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            begin { continuation.resume(returning: $0) }
        }
    }
}
