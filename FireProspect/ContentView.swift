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
    @State private var selectedDestination: SidebarDestination? = .home
    @State private var searchResults: [ProspectRecord] = []
    @State private var searchHistory = SearchHistoryStore.load()
    @State private var recentSearches = RecentSearchStore.load(fallback: SearchHistoryStore.load())
    @State private var prospectLists = ProspectListStore.load()
    @State private var currentKeywords: [String] = []
    @State private var currentLocations: [String] = []
    @State private var isSearchesExpanded = true
    @State private var isListsExpanded = true
    @State private var showingNewList = false
    @State private var expandedSearchDays: Set<Date> = []

    enum SidebarDestination: Hashable, Identifiable {
        case home
        case search
        case searches
        case prospectList(UUID)
        case settings
        case history(UUID)

        var id: String { identifier }

        var identifier: String {
            switch self {
            case .home: "home"
            case .search: "search"
            case .searches: "searches"
            case .prospectList(let id): "list.\(id.uuidString)"
            case .settings: "settings"
            case .history(let id): "history.\(id.uuidString)"
            }
        }

        var title: String {
            switch self {
            case .home:
                "Home"
            case .search:
                "New Search"
            case .searches:
                "Searches"
            case .prospectList(let id):
                id.uuidString
            case .settings:
                "Settings"
            case .history(let id):
                id.uuidString
            }
        }

        var systemImage: String {
            switch self {
            case .home:
                "house"
            case .search:
                "magnifyingglass"
            case .searches:
                "clock.arrow.circlepath"
            case .prospectList:
                "list.bullet.rectangle"
            case .settings:
                "gearshape"
            case .history:
                "clock"
            }
        }
    }

    private var selectedHistory: SearchHistoryEntry? {
        guard case .history(let id)? = selectedDestination else { return nil }
        return searchHistory.first { $0.id == id }
    }

    private var historyByDay: [(day: Date, entries: [SearchHistoryEntry])] {
        Dictionary(grouping: searchHistory) { Calendar.current.startOfDay(for: $0.searchedAt) }
            .map { (day: $0.key, entries: $0.value.sorted { $0.searchedAt > $1.searchedAt }) }
            .sorted { $0.day > $1.day }
    }

    private var latestHistory: SearchHistoryEntry? { searchHistory.first }

    private var selectedList: ProspectList? {
        guard case .prospectList(let id)? = selectedDestination else { return nil }
        return prospectLists.first { $0.id == id }
    }

    private func recordSearch(_ results: [ProspectRecord], keywords: [String], locations: [String]) {
        let entry = SearchHistoryEntry(results: results, keywords: keywords, locations: locations)
        searchHistory.insert(entry, at: 0)
        recentSearches.insert(entry, at: 0)
        try? RecentSearchStore.save(recentSearches)
        try? SearchHistoryStore.save(searchHistory)
        searchResults = results
        currentKeywords = keywords
        currentLocations = locations
        selectedDestination = .history(entry.id)
        isSearchesExpanded = true
        expandedSearchDays.insert(Calendar.current.startOfDay(for: entry.searchedAt))
    }

    private func clearRecentSearches() {
        recentSearches = []
        try? RecentSearchStore.save([])
    }

    private func deleteList(_ id: UUID) {
        prospectLists.removeAll { $0.id == id }
        try? ProspectListStore.save(prospectLists)
        if selectedDestination == .prospectList(id) { selectedDestination = .home }
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
                        destinationRow(.home)
                        destinationRow(.search)
                        DisclosureGroup(isExpanded: $isSearchesExpanded) {
                            if searchHistory.isEmpty {
                                Text("No search history")
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("sidebar.searches.empty")
                            } else {
                                ForEach(historyByDay, id: \.day) { group in
                                    DisclosureGroup(
                                        isExpanded: Binding(
                                            get: { expandedSearchDays.contains(group.day) },
                                            set: { isExpanded in
                                                if isExpanded {
                                                    expandedSearchDays.insert(group.day)
                                                } else {
                                                    expandedSearchDays.remove(group.day)
                                                }
                                            }
                                        )
                                    ) {
                                        ForEach(group.entries) { entry in
                                            Label(entry.searchedAt.formatted(date: .omitted, time: .shortened), systemImage: "magnifyingglass")
                                                .tag(SidebarDestination.history(entry.id))
                                                .accessibilityLabel("Search at \(entry.searchedAt.formatted(date: .complete, time: .shortened))")
                                                .accessibilityIdentifier("sidebar.history.\(entry.id.uuidString)")
                                        }
                                    } label: {
                                        Text(group.day.formatted(date: .complete, time: .omitted))
                                    }
                                }
                            }
                        } label: {
                            destinationRow(.searches)
                        }
                        DisclosureGroup(isExpanded: $isListsExpanded) {
                            if prospectLists.isEmpty {
                                Text("No lists")
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("sidebar.lists.empty")
                            } else {
                                ForEach(prospectLists) { list in
                                    Label(list.name, systemImage: "building.2")
                                        .tag(SidebarDestination.prospectList(list.id))
                                        .accessibilityIdentifier("sidebar.list.\(list.id.uuidString)")
                                        .contextMenu {
                                            Button("Delete List", role: .destructive) { deleteList(list.id) }
                                        }
                                }
                            }
                        } label: {
                            HStack {
                                Label("Lists", systemImage: "list.bullet.rectangle")
                                Spacer()
                                Button { showingNewList = true } label: {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(.borderless)
                                .help("Create a new list")
                                .accessibilityLabel("Create a new list")
                                .accessibilityIdentifier("sidebar.lists.create")
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Application navigation")
                .accessibilityIdentifier("sidebar.navigation")
                .safeAreaInset(edge: .bottom) {
                    Button {
                        selectedDestination = .settings
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(selectedDestination == .settings ? Color.accentColor.opacity(0.18) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .accessibilityIdentifier("sidebar.destination.settings")
                }
            }
            .navigationTitle("FireProspect")
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            Group {
                switch selectedDestination ?? .home {
                case .home:
                    HomeView(searchHistory: recentSearches) { entry in
                        selectedDestination = .history(entry.id)
                    } openSettings: {
                        selectedDestination = .settings
                    } clearRecentSearches: {
                        clearRecentSearches()
                    }
                case .search:
                    SearchTabView(searchResults: $searchResults, onSearchCompleted: recordSearch)
                case .searches:
                    ProspectsView(
                        searchResults: latestHistory?.results ?? searchResults,
                        keywords: latestHistory?.keywords ?? currentKeywords,
                        locations: latestHistory?.locations ?? currentLocations,
                        lists: $prospectLists
                    )
                case .prospectList:
                    ProspectsView(
                        searchResults: selectedList?.prospects ?? [],
                        lists: $prospectLists,
                        title: selectedList?.name ?? "List",
                        allowsCrawling: false
                    )
                case .settings:
                    SettingsTabView()
                case .history:
                    ProspectsView(
                        searchResults: selectedHistory?.results ?? [],
                        keywords: selectedHistory?.keywords ?? [],
                        locations: selectedHistory?.locations ?? [],
                        lists: $prospectLists
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppBackground())
            .navigationTitle(selectedHistory?.title ?? selectedList?.name ?? (selectedDestination ?? .home).title)
        }
        .sheet(isPresented: $showingNewList) {
            NewListSheet(lists: $prospectLists) { list in
                selectedDestination = .prospectList(list.id)
                isListsExpanded = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHomeDestination)) { _ in
            selectedDestination = .home
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSearchDestination)) { _ in
            selectedDestination = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSearchesDestination)) { _ in
            selectedDestination = .searches
            isSearchesExpanded = true
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

// MARK: - Home

struct HomeView: View {
    let searchHistory: [SearchHistoryEntry]
    let openSearch: (SearchHistoryEntry) -> Void
    let openSettings: () -> Void
    let clearRecentSearches: () -> Void
    @State private var remainingCredits: Int?
    @State private var creditStatus = "Checking monthly usage…"
    @State private var isFirecrawlConnected = false
    @State private var modelAvailability: LocalModelAvailability = .checking
    @State private var modelSetupMessage: String?
    @State private var showingModelSetup = false
    @State private var confirmingClearHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prospector")
                        .font(.largeTitle.weight(.bold))
                    Text("Find the right businesses, uncover the people behind them, and build an actionable outreach list.")
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 16) {
                    statusCard(title: "Firecrawl", image: "flame.fill") {
                        if !isFirecrawlConnected {
                            Text("Firecrawl not connected").font(.headline)
                            Text("Connect an API key to see how many website lookups you have left this month.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Connect Firecrawl", action: openSettings)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Text(remainingCredits.map { String($0) } ?? "—")
                                .font(.system(size: 34, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text(remainingCredits == nil ? creditStatus : "website lookups remaining this month")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    statusCard(title: "On-device AI", image: "cpu") {
                        Label(modelAvailability == .ready ? "Active" : "Not active", systemImage: modelAvailability == .ready ? "checkmark.circle.fill" : "pause.circle")
                            .font(.headline)
                            .foregroundStyle(modelAvailability == .ready ? Color.green : Color.secondary)
                        Text(LocalModelService.manifest.modelName)
                            .font(.title3.weight(.semibold))
                        Text(modelAvailability.label)
                            .font(.callout).foregroundStyle(.secondary)
                        if modelAvailability != .ready {
                            Button("Install on-device AI") { showingModelSetup = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(isInstallingModel)
                            .accessibilityIdentifier("home.setup-local-model")
                        }
                        if let modelSetupMessage {
                            Text(modelSetupMessage)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent searches").font(.title2.weight(.semibold))
                        Spacer()
                        if !searchHistory.isEmpty {
                            Button("Clear", role: .destructive) { confirmingClearHistory = true }
                                .accessibilityIdentifier("home.clear-search-history")
                        }
                    }
                    if searchHistory.isEmpty {
                        ContentUnavailableView("No Recent Searches", systemImage: "clock", description: Text("Completed searches will appear here."))
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ForEach(searchHistory.prefix(8)) { entry in
                            Button { openSearch(entry) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text((entry.keywords ?? []).first ?? "Prospect search").font(.headline)
                                        Text(entry.searchedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(entry.results.count) prospects").foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .accessibilityIdentifier("detail.home")
        .task { await refreshStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: .firecrawlConfigurationChanged)) { _ in
            Task { await refreshFirecrawlStatus() }
        }
        .sheet(isPresented: $showingModelSetup) {
            LocalModelSetupWizard { Task { await refreshStatuses() } }
        }
        .confirmationDialog("Clear all recent searches?", isPresented: $confirmingClearHistory) {
            Button("Clear Recent Searches", role: .destructive, action: clearRecentSearches)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only clears the Home page. Your complete search history remains available under Searches.")
        }
    }

    private func statusCard<Content: View>(title: String, image: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: image).font(.title3.weight(.semibold))
            content()
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
    }

    private var isInstallingModel: Bool {
        if case .installing = modelAvailability { return true }
        return false
    }

    @MainActor
    private func refreshStatuses() async {
        modelAvailability = await LocalModelService.shared.availability()
        await refreshFirecrawlStatus()
    }

    @MainActor
    private func refreshFirecrawlStatus() async {
        let key = KeychainHelper.getKey()
        isFirecrawlConnected = !key.isEmpty
        remainingCredits = nil
        guard isFirecrawlConnected else {
            creditStatus = "Firecrawl not connected"
            return
        }
        creditStatus = "Checking monthly usage…"
        do {
            remainingCredits = try await FirecrawlService.shared.remainingCredits(apiKey: key)
            creditStatus = "website lookups remaining this month"
        } catch {
            remainingCredits = nil
            creditStatus = "Monthly usage is currently unavailable."
        }
    }
}

// MARK: - Firecrawl Logs

struct FirecrawlLogsView: View {
    @State private var activities: [FirecrawlActivity] = []
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Website lookups").font(.title2.weight(.semibold))
                    Text("A history of company pages you looked up, and how many credits each one used.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Logs", role: .destructive) { confirmingClear = true }
                    .disabled(activities.isEmpty)
            }

            if activities.isEmpty {
                ContentUnavailableView("No lookups yet", systemImage: "doc.text.magnifyingglass", description: Text("Look up people on a business to see activity here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(activities) { activity in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(activity.website.host() ?? activity.website.absoluteString).font(.headline)
                            Spacer()
                            Text(activity.occurredAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let selectedPage = activity.selectedPage {
                            LabeledContent("Page opened") {
                                Link(selectedPage.absoluteString, destination: selectedPage).lineLimit(1)
                            }
                        } else {
                            LabeledContent("Page opened", value: "None")
                        }
                        LabeledContent("How we found it", value: activity.usedMapFallback ? "Backup website search" : "Company website menu")
                        LabeledContent("Credits used", value: activity.creditsUsed.map(String.init) ?? "Unavailable")
                        Text(activity.outcome).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .accessibilityIdentifier("detail.logs")
        .task { activities = FirecrawlActivityStore.load() }
        .confirmationDialog("Clear lookup history?", isPresented: $confirmingClear) {
            Button("Clear Logs", role: .destructive) {
                try? FirecrawlActivityStore.clear()
                activities = []
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Search Tab View

struct SearchTabView: View {
    @Binding var searchResults: [ProspectRecord]
    let onSearchCompleted: ([ProspectRecord], [String], [String]) -> Void
    @State private var category: String = "Civil Engineering"
    
    // Unified State & City selection state
    @State private var selectedStates: Set<StateID> = []
    @State private var stateSearch = ""
    @FocusState private var isStateDropdownFocused: Bool
    @FocusState private var isCityDropdownFocused: Bool
    @State private var isStateInputHovered = false
    @State private var isCityInputHovered = false
    
    @State private var selectedCityIDs: Set<CityID> = []
    @State private var selectedCityRecords: [CityID: City] = [:]
    @State private var selectAllCities = false
    @State private var allStates: [StateRecord] = []
    @State private var citySuggestions: [City] = []
    @State private var targetZips: [PostalCodeRecord] = []
    @State private var geographyError: String?
    @State private var citySearch = ""
    
    // Execution and results state
    @State private var isSearching = false
    @State private var logOutput = "Choose a state and city, then start a search."
    @State private var progressText = ""
    @State private var expansionStatus = "Related search terms are off. We’ll search the category you enter."
    @State private var acceptedCount = 0
    @State private var excludedCount = 0
    @State private var warnings: [String] = []
    @State private var usesAIKeywordGeneration = false
    @State private var keywordGenerationProgress = 0.0
    @State private var isGeneratingKeywords = false
    
    private var filteredStateSuggestions: [StateRecord] {
        allStates.filter { state in
            !selectedStates.contains(state.id) &&
            (stateSearch.isEmpty || state.name.localizedCaseInsensitiveContains(stateSearch) ||
             state.id.rawValue.localizedCaseInsensitiveContains(stateSearch))
        }
    }

    private var filteredCities: [City] {
        citySuggestions.filter { !selectedCityIDs.contains($0.id) }
    }

    private var shouldShowStateSuggestions: Bool {
        isStateDropdownFocused && !stateSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowCitySuggestions: Bool {
        isCityDropdownFocused && !citySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
            Text("Choose one or more states, then select individual cities or include every city in those states.")
                .font(.callout)
                .foregroundStyle(.secondary)
            
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
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !selectedStates.isEmpty {
                    Button("Clear") { clearStates() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
                Text("\(selectedStates.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 0) {
                TextField("Search states", text: $stateSearch)
                .textFieldStyle(.plain)
                .focused($isStateDropdownFocused)
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    Color(nsColor: .textBackgroundColor)
                        .overlay(Color.accentColor.opacity(isStateDropdownFocused ? 0.08 : (isStateInputHovered ? 0.04 : 0)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isStateDropdownFocused ? Color.accentColor : Color.primary.opacity(isStateInputHovered ? 0.3 : 0.15), lineWidth: isStateDropdownFocused ? 2 : 1)
                )
                .onHover { isStateInputHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isStateDropdownFocused)
                .animation(.easeOut(duration: 0.15), value: isStateInputHovered)
                .onSubmit {
                    if let first = filteredStateSuggestions.first { addState(first.id) }
                }
                
                if shouldShowStateSuggestions {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredStateSuggestions) { state in
                                PickerSuggestionRow(label: state.name, systemImage: nil) {
                                    addState(state.id)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 160)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }
    
    private var targetCitiesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cities")
                    .font(.subheadline.weight(.semibold))
                
                Spacer()
                
                Toggle("All cities", isOn: $selectAllCities)
                    .toggleStyle(.checkbox)
                    .font(.caption.weight(.semibold))
                    .disabled(selectedStates.isEmpty)
            }
            
            TextField(selectedStates.isEmpty ? "Select a state first" : "Search cities", text: $citySearch)
                .textFieldStyle(.plain)
                .focused($isCityDropdownFocused)
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    Color(nsColor: .textBackgroundColor)
                        .overlay(Color.accentColor.opacity(isCityDropdownFocused ? 0.08 : (isCityInputHovered ? 0.04 : 0)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isCityDropdownFocused ? Color.accentColor : Color.primary.opacity(isCityInputHovered ? 0.3 : 0.15), lineWidth: isCityDropdownFocused ? 2 : 1)
                )
                .onHover { isCityInputHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isCityDropdownFocused)
                .animation(.easeOut(duration: 0.15), value: isCityInputHovered)
                .disabled(selectAllCities || selectedStates.isEmpty)
                .opacity((selectAllCities || selectedStates.isEmpty) ? 0.4 : 1.0)
                .onSubmit {
                    if let first = filteredCities.first { addCityToSelection(first) }
                }
            
            // Filtered City List
            if shouldShowCitySuggestions {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if filteredCities.isEmpty {
                            Text("No cities matching filter.")
                                .font(.system(size: 10, design: .default))
                                .italic()
                                .foregroundStyle(.tertiary)
                                .padding(8)
                        } else {
                            ForEach(filteredCities) { city in
                                PickerSuggestionRow(label: city.displayName, systemImage: "plus.circle") {
                                    addCityToSelection(city)
                                }
                            }
                        }
                    }
                }
                .frame(height: 160)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }
    
    // Unified "City, State" Pill Section
    private var unifiedLocationPillsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Selected locations")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !selectedCityIDs.isEmpty {
                    Button("Clear cities") {
                        selectedCityIDs.removeAll()
                        selectedCityRecords.removeAll()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                if selectAllCities {
                    Text("All cities selected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(selectedCityIDs.count) selected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            
            if selectAllCities && selectedCityIDs.isEmpty {
                Text("Every city in the selected states will be searched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else if selectedCityIDs.isEmpty {
                Text("No cities selected yet. Choose a city above or turn on All cities.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                if selectAllCities {
                    Text("Saved city selection (paused while All cities is on)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(selectedCities.sorted(by: { $0.displayName < $1.displayName })) { location in
                            RemovablePill(label: location.displayName) {
                                removeCity(location.id)
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
                         "We’ll search this category across the area you selected.")
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
            HStack {
                Label("Search options", systemImage: "sparkles").font(.headline)
                Spacer()
                Toggle("Suggest related search terms", isOn: $usesAIKeywordGeneration)
                    .toggleStyle(.switch)
                    .disabled(isSearching)
                    .accessibilityIdentifier("search.ai-keyword-generation")
            }
            Text("When this is on, the app can add related business types to your search. Leave it off to search only what you typed.")
                .foregroundStyle(.secondary)
            Text(expansionStatus)
            if isGeneratingKeywords {
                ProgressView(value: keywordGenerationProgress, total: 1) {
                    Text("Finding related search terms…")
                } currentValueLabel: {
                    Text("\(Int(keywordGenerationProgress * 100))%").monospacedDigit()
                }
                .progressViewStyle(.linear)
                .accessibilityIdentifier("search.keyword-generation-progress")
            }
            HStack {
                Label("\(acceptedCount) found", systemImage: "checkmark.circle")
                Label("\(excludedCount) skipped", systemImage: "minus.circle")
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
            selectedCityRecords[id] ?? citySuggestions.first(where: { $0.id == id }) ?? City(
                id: id,
                name: id.normalizedName.capitalized,
                stateName: allStates.first(where: { $0.id == id.stateID })?.name ?? id.stateID.rawValue
            )
        }
    }

    private func addCityToSelection(_ city: City) {
        selectedCityIDs.insert(city.id)
        selectedCityRecords[city.id] = city
        citySearch = ""
        isCityDropdownFocused = false
    }

    private func addState(_ stateID: StateID) {
        selectedStates.insert(stateID)
        stateSearch = ""
        isStateDropdownFocused = false
    }

    private func removeCity(_ cityID: CityID) {
        selectedCityIDs.remove(cityID)
        selectedCityRecords.removeValue(forKey: cityID)
    }

    private func clearStates() {
        selectedStates.removeAll()
        selectedCityIDs.removeAll()
        selectedCityRecords.removeAll()
        selectAllCities = false
        stateSearch = ""
        citySearch = ""
    }

    private func removeState(_ stateID: StateID) {
        selectedStates.remove(stateID)
        selectedCityIDs = selectedCityIDs.filter { $0.stateID != stateID }
        selectedCityRecords = selectedCityRecords.filter { $0.key.stateID != stateID }
        if selectedStates.isEmpty { selectAllCities = false }
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
        logOutput = "Starting search across \(targetZips.count) ZIP codes…"
        progressText = ""
        expansionStatus = usesAIKeywordGeneration
            ? "Preparing related search terms…"
            : "Using your category as entered."
        keywordGenerationProgress = 0
        isGeneratingKeywords = usesAIKeywordGeneration
        acceptedCount = 0
        excludedCount = 0
        warnings = []
        searchResults.removeAll()
        
        let apiKey = KeychainHelper.getKey()
        let zipsToSearch = targetZips
        let cat = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldGenerateKeywords = usesAIKeywordGeneration
        let searchedLocations = selectAllCities
            ? selectedStates.sorted().map { stateID in
                "All cities in \(allStates.first(where: { $0.id == stateID })?.name ?? stateID.rawValue)"
            }
            : selectedCities.sorted { $0.displayName < $1.displayName }.map(\.displayName)
        let searchArea = SearchArea(
            postalCodes: zipsToSearch,
            selectedCityIDs: selectedCityIDs,
            selectedStates: selectedStates,
            includesEveryCityInSelectedStates: selectAllCities
        )
        
        Task {
            defer {
                Task { @MainActor in
                    self.progressText = ""
                    self.isSearching = false
                }
            }
            let service = MapKitSearchService()
            var allResults: [ProspectID: ProspectCandidate] = [:]
            var processed = 0
            var excluded = 0
            var nonfatalWarnings: [String] = []
            let progressTask = shouldGenerateKeywords ? Task { @MainActor in
                while !Task.isCancelled && keywordGenerationProgress < 0.9 {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled else { return }
                    keywordGenerationProgress = min(keywordGenerationProgress + 0.06, 0.9)
                }
            } : nil
            let expansionResult: KeywordExpansionResolution
            if shouldGenerateKeywords {
                expansionResult = await KeywordExpansionResolver(model: LocalModelService.shared).resolve(cat)
            } else {
                expansionResult = KeywordExpansionResolution(expansion: .fallback(for: cat), status: nil)
            }
            progressTask?.cancel()
            let expansion = expansionResult.expansion
            if let status = expansionResult.status { nonfatalWarnings.append(status) }

            await MainActor.run {
                self.keywordGenerationProgress = shouldGenerateKeywords ? 1 : 0
                self.isGeneratingKeywords = false
                self.expansionStatus = !shouldGenerateKeywords
                    ? "Using your category as entered: \(cat)"
                    : expansion.keywords.count == 1 && expansion.keywords[0] == cat
                    ? "Using your category as entered: \(cat)"
                    : "Also searching: \(expansion.keywords.joined(separator: " • "))"
            }
            
            for zip in zipsToSearch {
                for keyword in expansion.keywords {
                    do {
                        let results = try await service.searchZipCode(category: keyword, zip: zip)
                        for result in results {
                            if SemanticProspectPolicy.accepts(result), searchArea.contains(result) {
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
                    self.logOutput = "Searching ZIP \(current) of \(total).\nFound \(foundCount) businesses so far."
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
            var logBuffer = "Search complete. Found \(items.count) businesses across \(zipsToSearch.count) ZIP codes.\n\n"
            if apiKey.isEmpty {
                logBuffer += "Add a Firecrawl API key in Settings to look up people on company websites."
            } else {
                logBuffer += "Firecrawl is connected. You can look up people on company websites."
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
                self.onSearchCompleted(items, expansion.keywords, searchedLocations)
            }
        }
    }
    

}

// MARK: - List Creation

struct NewListSheet: View {
    @Binding var lists: [ProspectList]
    let onCreated: (ProspectList) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create a New List").font(.title2.weight(.semibold))
            Text("Give this list a name.").foregroundStyle(.secondary)
            TextField("List name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("lists.create.confirm")
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        let list = ProspectList(name: trimmedName)
        lists.append(list)
        try? ProspectListStore.save(lists)
        onCreated(list)
        dismiss()
    }
}

struct SitemapReviewSheet: View {
    let prospect: ProspectRecord
    let currentTeamPage: URL?
    let onUsePage: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: SitemapSnapshot?
    @State private var isLoading = true

    private var nodes: [SitemapHierarchyNode] {
        SitemapHierarchyNode.tree(from: snapshot?.urls ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sitemap for \(prospect.name)")
                        .font(.title2.weight(.semibold))
                    Text("The site’s published page map. Open a page or use it if Find Page missed the right one.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if isLoading {
                ProgressView("Loading sitemap…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot?.urls.isEmpty ?? true {
                ContentUnavailableView(
                    "No sitemap found",
                    systemImage: "map",
                    description: Text("This site did not publish a sitemap we could read.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    OutlineGroup(nodes, children: \.children) { node in
                        HStack(spacing: 10) {
                            if let url = node.url {
                                Link(node.name, destination: url)
                                    .lineLimit(1)
                                if urlsMatch(url, currentTeamPage) {
                                    Text("Selected")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Use page") { onUsePage(url) }
                                    .controlSize(.small)
                                    .disabled(urlsMatch(url, currentTeamPage))
                            } else {
                                Text(node.name)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("Sitemap page \(node.path)")
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .frame(width: 640, height: 520)
        .accessibilityIdentifier("prospects.sitemap-review")
        .task { await loadSitemap() }
    }

    private func urlsMatch(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else { return false }
        return lhs.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == rhs.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    @MainActor
    private func loadSitemap() async {
        isLoading = true
        snapshot = await SiteLinkDiscoveryService.shared.loadSitemap(for: prospect.websiteURL)
        isLoading = false
    }
}

struct ContactsReviewSheet: View {
    let prospect: ProspectRecord
    let people: [PersonnelExtraction.Person]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Contacts for \(prospect.name)")
                        .font(.title2.weight(.semibold))
                    Text("Each person is on its own row. Select any field to copy it.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if people.isEmpty {
                ContentUnavailableView(
                    "No contacts yet",
                    systemImage: "person.crop.rectangle",
                    description: Text("Look up people on this company to see names, emails, and phone numbers here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(people) {
                    TableColumn("Name") { Text($0.name ?? "—").textSelection(.enabled) }
                    TableColumn("Title") { Text($0.title ?? "—").textSelection(.enabled) }
                    TableColumn("Email") { Text($0.email ?? "—").textSelection(.enabled) }
                    TableColumn("Phone") { Text($0.phone ?? "—").textSelection(.enabled) }
                }
            }
        }
        .padding(24)
        .frame(width: 720, height: 480)
        .accessibilityIdentifier("prospects.contacts-review")
    }
}

// MARK: - Prospects

struct ProspectsView: View {
    let searchResults: [ProspectRecord]
    var keywords: [String] = []
    var locations: [String] = []
    @Binding var lists: [ProspectList]
    let title: String
    let allowsCrawling: Bool
    @State private var exportState: ExportState = .idle
    @State private var enrichmentMessage: String?
    @State private var isEnriching = false
    @State private var enrichmentProgress = 0.0
    @State private var selectedProspectID: ProspectID?
    @State private var pendingProspect: ProspectRecord?
    @State private var confirmingCrawlAll = false
    @State private var enrichmentReceipts: [ProspectID: EnrichmentReceipt] = [:]
    @State private var checkedPersonnelPageIDs = Set<ProspectID>()
    @State private var isFindingPersonnelPages = false
    @State private var checkedPersonnelPageCount = 0
    @State private var remainingCredits: Int?
    @State private var creditMessage: String?
    @State private var hoveredProspectID: ProspectID?
    @State private var presentedListMenuID: ProspectID?
    @State private var enrichingProspectID: ProspectID?
    @State private var findingPersonnelPageID: ProspectID?
    @State private var prospectForNewList: ProspectID?
    @State private var sitemapReviewProspect: ProspectRecord?
    @State private var contactsReviewProspect: ProspectRecord?

    init(searchResults: [ProspectRecord], keywords: [String] = [], locations: [String] = [], lists: Binding<[ProspectList]> = .constant([]), title: String = "Prospects", allowsCrawling: Bool = true) {
        self.searchResults = searchResults
        self.keywords = keywords
        self.locations = locations
        _lists = lists
        self.title = title
        self.allowsCrawling = allowsCrawling
    }

    private var rows: [NumberedProspectRow] {
        searchResults.enumerated().map { offset, record in
            NumberedProspectRow(number: offset + 1, prospect: ProspectRowModel(record: record))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !keywords.isEmpty || !locations.isEmpty {
                searchSummary
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text("\(searchResults.count) saved result\(searchResults.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if allowsCrawling {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(remainingCredits.map { "Website lookups left: \($0)" } ?? "Website lookups left: —")
                            .font(.callout.monospacedDigit())
                        if let creditMessage {
                            Text(creditMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("prospects.firecrawl-credits")
                }

                Button("Export CSV", systemImage: "square.and.arrow.down") {
                    Task { await exportResultsToCSV() }
                }
                .disabled(searchResults.isEmpty || exportState.isBusy)

                Button(isFindingPersonnelPages ? "Finding Team Pages…" : "Find Team Pages", systemImage: "person.crop.rectangle.stack") {
                    Task { await findPersonnelPages(force: true) }
                }
                .disabled(searchResults.isEmpty || isFindingPersonnelPages)
                .help("Looks at each company website for a team or staff page. This does not use lookup credits.")

                if allowsCrawling {
                    Button("Look Up All People", systemImage: "person.text.rectangle") {
                        confirmingCrawlAll = true
                    }
                    .disabled(searchResults.isEmpty || isEnriching || KeychainHelper.getKey().isEmpty)
                    .help(KeychainHelper.getKey().isEmpty ? "Add a Firecrawl API key in Settings." : "Looks up people on the best team page for every business.")
                }
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

            if isEnriching {
                ProgressView(value: enrichmentProgress, total: 1) {
                    Text("Looking up people on company websites…")
                } currentValueLabel: {
                    Text("\(Int(enrichmentProgress * 100))%")
                        .monospacedDigit()
                }
                    .progressViewStyle(.linear)
                    .animation(.linear(duration: 0.25), value: enrichmentProgress)
                    .accessibilityIdentifier("prospects.enrichment-progress")
            } else if isFindingPersonnelPages && findingPersonnelPageID == nil {
                ProgressView(value: Double(checkedPersonnelPageCount), total: Double(max(searchResults.count, 1))) {
                    Text("Finding team pages \(checkedPersonnelPageCount) of \(searchResults.count)")
                }
                .progressViewStyle(.linear)
                .accessibilityIdentifier("prospects.personnel-page-progress")
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    "No Prospects",
                    systemImage: "person.2",
                    description: Text("Run a search to see businesses here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                frozenProspectsTable
            }

            if let receipt = selectedProspectID.flatMap({ enrichmentReceipts[$0] }), let selectedURL = receipt.selectedURL, !receipt.personnel.people.isEmpty {
                GroupBox("People from \(selectedURL.host() ?? selectedURL.absoluteString)") {
                    Table(receipt.personnel.people) {
                        TableColumn("Name") { Text($0.name ?? "—") }
                        TableColumn("Title") { Text($0.title ?? "—") }
                        TableColumn("Email") { Text($0.email ?? "—").textSelection(.enabled) }
                        TableColumn("Phone") { Text($0.phone ?? "—").textSelection(.enabled) }
                    }
                    .frame(minHeight: 120)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("detail.prospects")
        .alert("Look up people on this website?", isPresented: Binding(
            get: { pendingProspect != nil },
            set: { if !$0 { pendingProspect = nil } }
        ), presenting: pendingProspect) { prospect in
            Button("Cancel", role: .cancel) { pendingProspect = nil }
            Button("Look Up People") {
                pendingProspect = nil
                Task { await enrich(prospect) }
            }
        } message: { prospect in
            Text("We’ll find a team or staff page for \(prospect.name) and look up the people listed there. This may use some of your website lookup credits.")
        }
        .confirmationDialog("Look up people for every business?", isPresented: $confirmingCrawlAll) {
            Button("Look Up \(searchResults.count) Businesses") { Task { await enrichAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We’ll look up people for each result. This may use website lookup credits.")
        }
        .task {
            if allowsCrawling { await refreshCredits() }
        }
        .sheet(isPresented: Binding(
            get: { prospectForNewList != nil },
            set: { if !$0 { prospectForNewList = nil } }
        )) {
            NewListSheet(lists: $lists) { list in
                if let id = prospectForNewList { add(id, to: list.id) }
                prospectForNewList = nil
            }
        }
        .sheet(item: $sitemapReviewProspect) { prospect in
            SitemapReviewSheet(
                prospect: prospect,
                currentTeamPage: enrichmentReceipts[prospect.id]?.selectedURL
            ) { url in
                useSitemapPage(url, for: prospect)
            }
        }
        .sheet(item: $contactsReviewProspect) { prospect in
            ContactsReviewSheet(
                prospect: prospect,
                people: enrichmentReceipts[prospect.id]?.personnel.people ?? []
            )
        }
    }

    private var searchSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Search summary", systemImage: "line.3.horizontal.decrease.circle")
                .font(.headline)
            if !keywords.isEmpty {
                summaryLine(title: "Keywords", values: keywords)
            }
            if !locations.isEmpty {
                summaryLine(title: "Cities", values: locations)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.25)))
        .accessibilityIdentifier("prospects.search-summary")
    }

    private func summaryLine(title: String, values: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(values.joined(separator: " • "))
                .font(.callout)
                .lineLimit(2)
        }
    }

    private var frozenProspectsTable: some View {
        GeometryReader { geometry in
            let detailWidth = max(120, (geometry.size.width - 354) / CGFloat(max(tableHeaders.count, 1)))
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        frozenRow(number: "#", business: "Business", isHeader: true)
                        ForEach(rows) { row in
                            frozenRow(number: "\(row.number)", business: row.prospect.name, id: row.id)
                        }
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                    .zIndex(1)

                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            detailRow(values: tableHeaders, width: detailWidth, isHeader: true)
                            ForEach(rows) { row in
                                detailProspectRow(row, width: detailWidth)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .background(Color.primary.opacity(0.018))
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.14)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("prospects.results-table")
    }

    private var tableHeaders: [String] {
        ["Address", "Phone", "Website", "Team Page", "Contacts", "Personnel Page", "Sitemap"] + (allowsCrawling ? ["Crawl"] : []) + ["List"]
    }

    private func rowBackground(_ id: ProspectID?) -> Color {
        guard let id else { return Color.primary.opacity(0.055) }
        if selectedProspectID == id { return Color.accentColor.opacity(0.18) }
        if hoveredProspectID == id { return Color.accentColor.opacity(0.09) }
        return Color.clear
    }

    private func frozenRow(number: String, business: String, id: ProspectID? = nil, isHeader: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(number).monospacedDigit().frame(width: 44, alignment: .leading)
            Text(business).lineLimit(1).frame(width: 210, alignment: .leading)
        }
        .font(isHeader ? .caption.weight(.semibold) : .callout)
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(rowBackground(id))
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { if let id { selectedProspectID = id } }
        .onHover { hovering in if let id { hoveredProspectID = hovering ? id : nil } }
        .animation(.easeOut(duration: 0.12), value: hoveredProspectID)
    }

    private func detailRow(values: [String], width: CGFloat, id: ProspectID? = nil, isHeader: Bool = false) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value).lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
        .font(isHeader ? .caption.weight(.semibold) : .callout)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(rowBackground(id))
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { if let id { selectedProspectID = id } }
        .onHover { hovering in if let id { hoveredProspectID = hovering ? id : nil } }
        .animation(.easeOut(duration: 0.12), value: hoveredProspectID)
    }

    private func detailProspectRow(_ row: NumberedProspectRow, width: CGFloat) -> some View {
        HStack(spacing: 12) {
            detailCell(row.prospect.address, width: width)
            detailCell(row.prospect.phone, width: width)
            Link(row.prospect.websiteURL.host() ?? row.prospect.websiteURL.absoluteString, destination: row.prospect.websiteURL)
                .lineLimit(1).frame(width: width, alignment: .leading)
            teamPageCell(for: row, width: width)
            contactsCell(for: row, width: width)
            personnelPageCell(for: row, width: width)
            Button("Review") {
                sitemapReviewProspect = searchResults.first { $0.id == row.id }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: width, alignment: .leading)
            .help("Open this company’s sitemap to check for a team, leadership, or people page.")
            .accessibilityLabel("Review sitemap for \(row.prospect.name)")
            if allowsCrawling {
                Button(enrichingProspectID == row.id ? "Crawling…" : "Crawl") {
                    if let prospect = searchResults.first(where: { $0.id == row.id }) { pendingProspect = prospect }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isEnriching || KeychainHelper.getKey().isEmpty)
                .frame(width: width, alignment: .leading)
                .accessibilityLabel("Crawl \(row.prospect.name)")
            }
            Button("Add to List") { presentedListMenuID = row.id }
                .buttonStyle(.borderless)
                .popover(isPresented: Binding(
                    get: { presentedListMenuID == row.id },
                    set: { if !$0 { presentedListMenuID = nil } }
                ), arrowEdge: .bottom) {
                    addToListPopover(for: row)
                }
                .frame(width: width, alignment: .leading)
                .accessibilityLabel("Add \(row.prospect.name) to list")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(rowBackground(row.id))
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { selectedProspectID = row.id }
        .onHover { hoveredProspectID = $0 ? row.id : nil }
        .animation(.easeOut(duration: 0.12), value: hoveredProspectID)
    }

    private func detailCell(_ value: String, width: CGFloat) -> some View {
        Text(value).lineLimit(1).frame(width: width, alignment: .leading)
    }

    private func useSitemapPage(_ url: URL, for prospect: ProspectRecord) {
        let existing = enrichmentReceipts[prospect.id]
        enrichmentReceipts[prospect.id] = EnrichmentReceipt(
            selectedURL: url,
            discovery: existing?.discovery ?? LinkDiscovery(links: [url], sitemapAvailability: .unavailable, usedHomepage: false),
            usedFirecrawlMap: false,
            personnel: existing?.personnel ?? PersonnelExtraction(people: []),
            aiEnhancement: .completed
        )
        checkedPersonnelPageIDs.insert(prospect.id)
        sitemapReviewProspect = nil
    }

    private func add(_ prospectID: ProspectID, to listID: UUID) {
        guard let prospect = searchResults.first(where: { $0.id == prospectID }) else { return }
        lists = ProspectListStore.adding(prospect, to: listID, in: lists)
        try? ProspectListStore.save(lists)
        presentedListMenuID = nil
    }

    private func addToListPopover(for row: NumberedProspectRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to List")
                .font(.headline)
            Button("New List…", systemImage: "plus") {
                presentedListMenuID = nil
                prospectForNewList = row.id
            }
            Divider()
            if lists.isEmpty {
                Text("No lists yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lists) { list in
                    Button(list.name) { add(row.id, to: list.id) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .frame(width: 220, alignment: .leading)
    }

    @ViewBuilder
    private func teamPageCell(for row: NumberedProspectRow, width: CGFloat) -> some View {
        Group {
            if isPersonnelPageInProgress(for: row.id) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .accessibilityLabel("Finding team page for \(row.prospect.name)")
                    .accessibilityIdentifier("prospects.team-page-progress.\(row.id.rawValue)")
            } else if let url = enrichmentReceipts[row.id]?.selectedURL {
                Link(url.absoluteString, destination: url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.absoluteString)
                    .accessibilityLabel("Open team page for \(row.prospect.name)")
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func personnelPageCell(for row: NumberedProspectRow, width: CGFloat) -> some View {
        Group {
            if isPersonnelPageInProgress(for: row.id) {
                Text("Finding…")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Finding team page for \(row.prospect.name)")
            } else if let url = enrichmentReceipts[row.id]?.selectedURL {
                Link("Found", destination: url)
                    .help(url.absoluteString)
                    .accessibilityLabel("Open team page for \(row.prospect.name)")
            } else if checkedPersonnelPageIDs.contains(row.id) {
                Text("Not found")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Team page not found for \(row.prospect.name)")
            } else {
                Button("Find Page") {
                    if let prospect = searchResults.first(where: { $0.id == row.id }) {
                        Task { await findPersonnelPage(for: prospect) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isFindingPersonnelPages)
                .help("Looks at the company website for a team or staff page. This does not use lookup credits.")
                .accessibilityLabel("Find team page for \(row.prospect.name)")
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func isPersonnelPageInProgress(for id: ProspectID) -> Bool {
        if findingPersonnelPageID == id { return true }
        return isFindingPersonnelPages && findingPersonnelPageID == nil && !checkedPersonnelPageIDs.contains(id)
    }

    private var selectedProspect: ProspectRecord? {
        searchResults.first { $0.id == selectedProspectID }
    }

    @ViewBuilder
    private func contactsCell(for row: NumberedProspectRow, width: CGFloat) -> some View {
        let count = contactCount(for: row.id)
        Group {
            if count == 0 {
                Text("—").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 0) {
                    Text("(\(count) ")
                    Button("contact\(count == 1 ? "" : "s")") {
                        contactsReviewProspect = searchResults.first { $0.id == row.id }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    Text(")")
                }
                .help("Show every contact found for \(row.prospect.name).")
                .accessibilityLabel("\(count) contacts for \(row.prospect.name)")
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func contactCount(for id: ProspectID) -> Int {
        enrichmentReceipts[id]?.personnel.people.count ?? 0
    }

    @MainActor
    private func findPersonnelPage(for prospect: ProspectRecord) async {
        guard !isFindingPersonnelPages else { return }
        isFindingPersonnelPages = true
        findingPersonnelPageID = prospect.id
        enrichmentMessage = "Looking for a team or staff page for \(prospect.name)…"

        let receipt = try? await SiteEnrichmentService.shared.findPersonnelPage(website: prospect.websiteURL)
        if let receipt {
            enrichmentReceipts[prospect.id] = receipt
        }
        checkedPersonnelPageIDs.insert(prospect.id)

        isFindingPersonnelPages = false
        findingPersonnelPageID = nil
        let found = receipt?.selectedURL != nil
        enrichmentMessage = found
            ? "Found a team page for \(prospect.name)."
            : "Couldn’t find a team page for \(prospect.name)."
    }

    @MainActor
    private func findPersonnelPages(force: Bool) async {
        guard !searchResults.isEmpty else { return }
        let prospectsToCheck = force ? searchResults : searchResults.filter { !checkedPersonnelPageIDs.contains($0.id) }
        guard !prospectsToCheck.isEmpty else { return }
        if force {
            checkedPersonnelPageIDs.removeAll()
            enrichmentReceipts = enrichmentReceipts.filter { receipt in !prospectsToCheck.contains { $0.id == receipt.key } }
        }
        isFindingPersonnelPages = true
        checkedPersonnelPageCount = 0
        enrichmentMessage = "Looking for team or staff pages. This does not use lookup credits…"

        await withTaskGroup(of: (ProspectRecord, EnrichmentReceipt?).self) { group in
            for prospect in prospectsToCheck {
                group.addTask {
                    let receipt = try? await SiteEnrichmentService.shared.findPersonnelPage(website: prospect.websiteURL)
                    return (prospect, receipt)
                }
            }
            for await (prospect, receipt) in group {
                if let receipt {
                    enrichmentReceipts[prospect.id] = receipt
                }
                checkedPersonnelPageIDs.insert(prospect.id)
                checkedPersonnelPageCount += 1
            }
        }

        isFindingPersonnelPages = false
        let found = enrichmentReceipts.values.filter { $0.selectedURL != nil }.count
        enrichmentMessage = "Finished checking team pages. Found \(found) of \(searchResults.count)."
    }

    @MainActor
    private func refreshCredits() async {
        let key = KeychainHelper.getKey()
        guard !key.isEmpty else {
            remainingCredits = nil
            creditMessage = "Add an API key in Settings"
            return
        }
        do {
            remainingCredits = try await FirecrawlService.shared.remainingCredits(apiKey: key)
            creditMessage = nil
        } catch {
            remainingCredits = nil
            creditMessage = "Lookup balance unavailable"
        }
    }

    @MainActor
    private func enrich(_ prospect: ProspectRecord) async {
        let creditsBefore = remainingCredits
        isEnriching = true
        enrichingProspectID = prospect.id
        enrichmentProgress = 0
        let progressTask = Task { @MainActor in
            while !Task.isCancelled && enrichmentProgress < 0.95 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                enrichmentProgress = min(enrichmentProgress + 0.015, 0.95)
            }
        }
        let knownTeamPage = enrichmentReceipts[prospect.id]?.selectedURL
        enrichmentMessage = knownTeamPage == nil
            ? "Looking at the website for a team or staff page…"
            : "Looking up people on the saved team page…"
        do {
            let receipt = try await SiteEnrichmentService.shared.enrichOnePage(
                website: prospect.websiteURL,
                apiKey: KeychainHelper.getKey(),
                knownTeamPage: knownTeamPage
            )
            let enhancementStatus: String
            switch receipt.aiEnhancement {
            case .completed: enhancementStatus = "Read the team page and matched names to emails and phone numbers."
            case .skipped(let reason): enhancementStatus = "Couldn’t use on-device AI for this lookup. \(reason.unavailableDescription)"
            }
            let peopleCount = receipt.personnel.people.count
            enrichmentMessage = """
            \(enhancementStatus)
            Website links checked: \(receipt.discovery.links.count)
            Page used: \(receipt.selectedURL?.absoluteString ?? "None")
            People found: \(peopleCount)
            """
            enrichmentReceipts[prospect.id] = receipt
            await refreshCredits()
            try? FirecrawlActivityStore.append(FirecrawlActivity(
                website: prospect.websiteURL,
                selectedPage: receipt.selectedURL,
                usedMapFallback: receipt.usedFirecrawlMap,
                creditsBefore: creditsBefore,
                creditsAfter: remainingCredits,
                outcome: enhancementStatus
            ))
        } catch {
            enrichmentMessage = "Couldn’t look up people. \(error.localizedDescription)"
            await refreshCredits()
            try? FirecrawlActivityStore.append(FirecrawlActivity(
                website: prospect.websiteURL,
                selectedPage: nil,
                usedMapFallback: false,
                creditsBefore: creditsBefore,
                creditsAfter: remainingCredits,
                outcome: "Failed: \(error.localizedDescription)"
            ))
        }
        progressTask.cancel()
        enrichmentProgress = 1
        try? await Task.sleep(for: .milliseconds(350))
        isEnriching = false
        enrichingProspectID = nil
    }

    @MainActor
    private func enrichAll() async {
        guard !searchResults.isEmpty else { return }
        let total = searchResults.count
        for (index, prospect) in searchResults.enumerated() {
            enrichmentMessage = "Looking up people for \(prospect.name) (\(index + 1) of \(total))"
            await enrich(prospect)
        }
        enrichmentMessage = "Finished looking up people for \(total) business\(total == 1 ? "" : "es")."
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

// MARK: - Interactive Picker Row

private struct PickerSuggestionRow: View {
    let label: String
    let systemImage: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                Spacer(minLength: 8)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
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
    @State private var isFirecrawlKeyVisible = false
    @State private var firecrawlMessage: String = ""
    @State private var localModelMessage: String = ""
    @State private var localModelAvailability: LocalModelAvailability = .checking
    @State private var showingModelSetup = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Firecrawl", systemImage: "key")
                        .font(.title3.weight(.semibold))
                    
                    Text("Connect Firecrawl to look up people listed on company websites.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                HStack(spacing: 8) {
                    Group {
                        if isFirecrawlKeyVisible {
                            TextField("API key", text: $firecrawlKey)
                        } else {
                            SecureField("API key", text: $firecrawlKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        isFirecrawlKeyVisible.toggle()
                    } label: {
                        Image(systemName: isFirecrawlKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(isFirecrawlKeyVisible ? "Hide API key" : "Show API key")
                    .accessibilityLabel(isFirecrawlKeyVisible ? "Hide API key" : "Show API key")
                    .accessibilityIdentifier("settings.firecrawl-key-visibility")
                }
                
                HStack(spacing: 16) {
                    Button(action: {
                        let normalizedKey = firecrawlKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalizedKey.isEmpty else {
                            firecrawlMessage = "Enter your Firecrawl API key to save it."
                            return
                        }
                        if KeychainHelper.saveKey(normalizedKey), KeychainHelper.getKey() == normalizedKey {
                            firecrawlKey = normalizedKey
                            firecrawlMessage = "Saved. Your key is stored securely on this Mac."
                            NotificationCenter.default.post(name: .firecrawlConfigurationChanged, object: nil)
                        } else {
                            firecrawlMessage = "The key could not be saved. Please try again."
                        }
                    }) {
                        Text("Save API Key")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(firecrawlKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove", role: .destructive) {
                        _ = KeychainHelper.deleteKey()
                        firecrawlKey = ""
                        firecrawlMessage = "Key removed."
                        NotificationCenter.default.post(name: .firecrawlConfigurationChanged, object: nil)
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
                Text("Install a small model on this Mac to suggest related search terms. It stays private and does not need an account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalModelService.manifest.displayName).font(.headline)
                    Text(LocalModelService.manifest.detail).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check Again") { Task { await refreshLocalModel() } }
                    Button("Install on-device AI") { showingModelSetup = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(localModelAvailability == .ready || isInstallingModel)
                        .accessibilityIdentifier("settings.install-local-model")
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
            firecrawlMessage = firecrawlKey.isEmpty ? "Add your Firecrawl API key to look up people on company websites." : "Your key is saved securely on this Mac."
            Task { await refreshLocalModel() }
        }
        .sheet(isPresented: $showingModelSetup) {
            LocalModelSetupWizard { Task { await refreshLocalModel() } }
        }
    }

    private var isInstallingModel: Bool {
        if case .installing = localModelAvailability { return true }
        return false
    }

    @MainActor
    private func refreshLocalModel() async {
        localModelAvailability = .checking
        localModelAvailability = await LocalModelService.shared.availability()
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
