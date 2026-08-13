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
    @State private var activeTab: AppTab = .search
    
    enum AppTab: String, CaseIterable {
        case search = "GRID SEARCH"
        case settings = "SETTINGS"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header / Navigation Bar
            HStack(alignment: .center, spacing: 32) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FIREPROSPECT")
                        .font(.system(size: 14, weight: .black, design: .default))
                        .tracking(1.2)
                    
                    Text("SYS.VER 2.4 // REGIONAL DOMAIN ENGINE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                activeTab = tab
                            }
                        }) {
                            Text(tab.rawValue)
                                .font(.system(size: 10, weight: activeTab == tab ? .bold : .medium, design: .monospaced))
                                .tracking(0.8)
                                .foregroundStyle(activeTab == tab ? Color.primary : Color.secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(activeTab == tab ? Color.primary.opacity(0.12) : Color.primary.opacity(0.03))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(activeTab == tab ? Color.primary.opacity(0.25) : Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
            
            Group {
                switch activeTab {
                case .search:
                    SearchTabView()
                case .settings:
                    SettingsTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Search Tab View

struct SearchTabView: View {
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
    @State private var searchResults: [ProspectRecord] = []
    @State private var exportState: ExportState = .idle
    @State private var exportHistory: [CSVExporter.Receipt] = []
    
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
                resultsTableSection
                systemLogSection
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await loadGeography() }
        .task(id: selectedStates) { await refreshCitiesAndZIPs() }
        .task(id: citySearch) { await refreshCities() }
        .task(id: searchScope) { await refreshZIPs() }
    }
    
    // MARK: - Subviews
    
    private var categoryInputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("01 // SEARCH VECTOR / CATEGORY")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            
            TextField("E.G. CIVIL ENGINEERING, HEAVY CONTRACTING…", text: $category)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .regular, design: .default))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
        }
    }
    
    private var geographyConnectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("02 // TARGET GEOGRAPHY (STATE & CITY CONNECTOR)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            
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
                Text("STEP A: SELECT STATE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selectedStates.count) ACTIVE")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 0) {
                TextField("TYPE STATE NAME OR ABBREVIATION…", text: $stateSearch, onEditingChanged: { focused in
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
                                        Spacer()
                                        Text(state.id.rawValue)
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.secondary)
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
                        RemovablePill(label: "\(name) (\(stateID.rawValue))") {
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
                Text("STEP B: SELECT CITY")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Toggle("ALL CITIES IN STATE", isOn: $selectAllCities)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .disabled(selectedStates.isEmpty)
            }
            
            TextField(selectedStates.isEmpty ? "SELECT A STATE FIRST TO LOAD CITIES…" : "FILTER CITIES…", text: $citySearch)
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
                Text("ACTIVE UNIFIED LOCATIONS:")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if selectAllCities {
                    Text("[ ALL CITIES ACTIVE FOR SELECTED STATES ]")
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
                    Text("SCOPE RESOLUTION MATRIX")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(targetZips.count)")
                            .font(.system(size: 20, weight: .black, design: .monospaced))
                        
                        Text("ZIP CODES IDENTIFIED")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    
                    Text(targetZips.isEmpty ?
                         "⚠️ Select state(s) and city location(s) to calculate search targets." :
                         "Metric displays total unique geographic ZIP code zones compiled from selected unified locations.")
                        .font(.system(size: 10, design: .default))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button(action: runMultiZipSearch) {
                    HStack(spacing: 10) {
                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isSearching ? "EXECUTING GRID SEARCH…" : "EXECUTE SEARCH CYCLE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(0.8)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(canSearch ? Color.primary : Color.primary.opacity(0.08))
                    )
                    .foregroundStyle(canSearch ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(canSearch ? Color.primary.opacity(0.2) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
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
    
    // MARK: - Prospect Results Table Component (Responsive Responsive Grid)
    
    private var resultsTableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("03 // DISCOVERED PROSPECTS (\(searchResults.count))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                
                Spacer()
                
                // CSV Export Button
                Button { Task { await exportResultsToCSV() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 9, weight: .bold))
                        Text("EXPORT CSV")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(searchResults.isEmpty ? Color.primary.opacity(0.04) : Color.primary.opacity(0.1))
                    )
                    .foregroundStyle(searchResults.isEmpty ? Color.secondary.opacity(0.5) : Color.primary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(searchResults.isEmpty ? Color.clear : Color.primary.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(searchResults.isEmpty || exportState.isBusy)
            }

            if let exportMessage = exportState.message {
                Text(exportMessage)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(exportState.isFailure ? Color.red : Color.secondary)
            }
            
            if searchResults.isEmpty {
                VStack(spacing: 6) {
                    Text("NO ACTIVE PROSPECT RESULTS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("Execute a search cycle to populate prospect business details, phone numbers, and addresses.")
                        .font(.system(size: 10, design: .default))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            } else {
                VStack(spacing: 0) {
                    // Fully Responsive Table Header Row
                    HStack(spacing: 12) {
                        Text("#")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .leading)
                        
                        Text("BUSINESS NAME")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                        
                        Text("ADDRESS")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                        
                        Text("PHONE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        
                        Text("WEBSITE URL")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                        
                        Text("ACTIONS")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06))
                    
                    Divider()
                    
                    // Fully Responsive Table Content Rows
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(resultRows.enumerated()), id: \.element.id) { index, item in
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32, alignment: .leading)
                                    
                                    Text(item.name.isEmpty ? "N/A" : item.name)
                                        .font(.system(size: 11, weight: .semibold, design: .default))
                                        .lineLimit(1)
                                        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                                    
                                    Text(item.address)
                                        .font(.system(size: 10, design: .default))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                                    
                                    Text(item.phone.isEmpty ? "N/A" : item.phone)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(width: 110, alignment: .leading)
                                    
                                    Group {
                                        Link(destination: item.websiteURL) {
                                            HStack(spacing: 4) {
                                                Text(item.websiteURL.absoluteString)
                                                    .lineLimit(1)
                                                    .underline()
                                                Image(systemName: "arrow.up.right.square")
                                                    .font(.system(size: 8))
                                            }
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                                    
                                    HStack(spacing: 8) {
                                        Button(action: {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(item.phone, forType: .string)
                                        }) {
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Copy Phone Number")
                                        .disabled(item.phone.isEmpty || item.phone == "N/A")
                                    }
                                    .frame(width: 60, alignment: .trailing)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(index % 2 == 0 ? Color.clear : Color.primary.opacity(0.02))
                                
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private var systemLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("04 // SYSTEM EXECUTION LOG")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                
                Spacer()
                
                if !progressText.isEmpty {
                    Text(progressText)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            
            TextEditor(text: .constant(logOutput))
                .font(.system(size: 10, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 100)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
    }
    
    // MARK: - Actions & Logic
    
    private var selectedCities: [City] {
        selectedCityIDs.compactMap { id in
            citySuggestions.first(where: { $0.id == id }) ?? City(id: id, name: id.normalizedName.capitalized, stateName: id.stateID.rawValue)
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
        searchResults.removeAll()
        
        let apiKey = KeychainHelper.getKey()
        let zipsToSearch = targetZips
        let cat = category
        
        Task {
            let service = MapKitSearchService()
            var allResults: [ProspectID: ProspectCandidate] = [:]
            var processed = 0
            
            for zip in zipsToSearch {
                do {
                    let results = try await service.searchZipCode(category: cat, zip: zip)
                    for r in results {
                        allResults[r.id] = r
                    }
                } catch {
                    // Continue processing on individual ZIP errors
                }
                
                processed += 1
                let current = processed
                let total = zipsToSearch.count
                let foundCount = allResults.count
                
                await MainActor.run {
                    self.progressText = "[\(current)/\(total)]"
                    self.logOutput = "PROCESSING // \(current) of \(total) ZIPs resolved.\nDISCOVERED // \(foundCount) unique domain vectors."
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
            
            // Safely pass immutable `let` values to MainActor.run
            await MainActor.run {
                self.searchResults = items
                self.logOutput = finalLog
                self.progressText = ""
                self.isSearching = false
            }
        }
    }
    
    private var resultRows: [ProspectRowModel] {
        searchResults.map(ProspectRowModel.init(record:))
    }

    @MainActor
    private func exportResultsToCSV() async {
        guard !searchResults.isEmpty else { return }
        exportState = .choosingDestination

        let panel = NSSavePanel()
        panel.title = "Export Prospects to CSV"
        panel.nameFieldStringValue = CSVExporter.safeFilename(stem: category)
        panel.allowedContentTypes = [.commaSeparatedText]
        let response = await panel.beginResponse()
        guard response == .OK, let destination = panel.url else {
            exportState = .cancelled
            logOutput = "EXPORT CANCELLED // Current search results remain available."
            return
        }

        exportState = .exporting
        let records = searchResults
        do {
            let receipt = try await Task.detached {
                try CSVExporter().exportProspects(records, to: destination)
            }.value
            exportHistory.append(receipt)
            exportState = .succeeded(receipt)
            logOutput = "EXPORT COMPLETE // Saved \(records.count) prospects to \(destination.lastPathComponent)."
        } catch {
            exportState = .failed(error.localizedDescription)
            logOutput = "EXPORT FAILED // \(error.localizedDescription) Current search results remain available."
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
            case .choosingDestination: "EXPORT // Waiting for a save destination…"
            case .exporting: "EXPORT // Writing UTF-8 CSV…"
            case .succeeded(let receipt): "EXPORT // Saved \(receipt.rowCount) rows to \(receipt.destination.lastPathComponent)"
            case .cancelled: "EXPORT // Save cancelled; results were retained."
            case .failed(let reason): "EXPORT ERROR // \(reason) Results were retained."
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
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
    @State private var saveMessage: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("01 // FIRECRAWL API AUTHENTICATION")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                    
                    Text("Required credential for automated site crawling and structured domain parsing.")
                        .font(.system(size: 11, design: .default))
                        .foregroundStyle(.secondary)
                }
                
                SecureField("FC-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX", text: $firecrawlKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                
                HStack(spacing: 16) {
                    Button(action: {
                        KeychainHelper.saveKey(firecrawlKey)
                        saveMessage = "CREDENTIALS STORED TO SYSTEM KEYCHAIN"
                        
                        Task {
                            try? await Task.sleep(for: .seconds(2.5))
                            await MainActor.run { saveMessage = "" }
                        }
                    }) {
                        Text("SAVE CREDENTIALS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(0.8)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary)
                            )
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    }
                    .buttonStyle(.plain)
                    
                    if !saveMessage.isEmpty {
                        Text(saveMessage)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color.primary.opacity(0.02))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            firecrawlKey = KeychainHelper.getKey()
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
