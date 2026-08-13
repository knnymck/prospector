import Foundation

actor BundledGeographyRepository {
    enum LoadError: Error, Equatable {
        case resourceNotFound(String)
        case unreadableResource(String)
        case invalidData(String)
    }

    static let shared = BundledGeographyRepository()

    private struct Indexes: Sendable {
        let states: [StateRecord]
        let citiesByState: [StateID: [City]]
        let recordsByCity: [CityID: [PostalCodeRecord]]
        let recordsByZIP: [PostalCodeID: PostalCodeRecord]
    }

    private let bundle: Bundle
    private var loadTask: Task<Indexes, Error>?

    init(bundle: Bundle = .main) { self.bundle = bundle }

    func states() async throws -> [StateRecord] { try await indexes().states }

    func cities(matching query: String = "", in states: Set<StateID>) async throws -> [City] {
        guard !states.isEmpty else { return [] }
        let indexes = try await indexes()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return states.flatMap { indexes.citiesByState[$0, default: []] }
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) }
            .sorted { $0.displayName < $1.displayName }
    }

    func postalCodes(for scope: SearchScope) async throws -> [PostalCodeRecord] {
        switch scope {
        case .selectedCities(let cityIDs) where cityIDs.isEmpty: return []
        case .allCities(let stateIDs) where stateIDs.isEmpty: return []
        default: break
        }
        let indexes = try await indexes()
        let records: [PostalCodeRecord]
        switch scope {
        case .selectedCities(let cityIDs):
            records = cityIDs.flatMap { indexes.recordsByCity[$0, default: []] }
        case .allCities(let stateIDs):
            records = stateIDs
                .flatMap { indexes.citiesByState[$0, default: []] }
                .flatMap { indexes.recordsByCity[$0.id, default: []] }
        }
        return records.sorted { $0.id < $1.id }
    }

    func postalCode(id: PostalCodeID) async throws -> PostalCodeRecord? {
        try await indexes().recordsByZIP[id]
    }

    private func indexes() async throws -> Indexes {
        if let loadTask { return try await loadTask.value }
        let bundle = bundle
        let task = Task.detached(priority: .userInitiated) { () throws -> Indexes in
            guard let url = bundle.url(forResource: "uszips", withExtension: "json") else {
                throw LoadError.resourceNotFound("uszips.json")
            }
            let data: Data
            do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
            catch { throw LoadError.unreadableResource(error.localizedDescription) }
            let records: [PostalCodeRecord]
            do { records = try JSONDecoder().decode([PostalCodeRecord].self, from: data) }
            catch { throw LoadError.invalidData(error.localizedDescription) }

            let byZIP = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            var byCity = Dictionary(grouping: records, by: \.cityID)
            byCity = byCity.mapValues { $0.sorted { $0.id < $1.id } }
            let cities = Dictionary(grouping: byCity.keys.map { id in
                let record = byCity[id]!.first!
                return City(id: id, name: record.cityName, stateName: record.stateName)
            }, by: { $0.id.stateID }).mapValues { $0.sorted { $0.name < $1.name } }
            let states = Dictionary(grouping: records, by: \.stateID).map { id, values in
                StateRecord(id: id, name: values.first?.stateName ?? id.rawValue)
            }.sorted()
            return Indexes(states: states, citiesByState: cities, recordsByCity: byCity, recordsByZIP: byZIP)
        }
        loadTask = task
        return try await task.value
    }
}
