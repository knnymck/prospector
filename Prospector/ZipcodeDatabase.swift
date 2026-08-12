import Foundation
import CoreLocation

// MARK: - ZipCodeModel
struct ZipCodeModel: Identifiable, Hashable, Codable, Sendable {
    let id: String          // Maps to "zip" in JSON
    let cityName: String    // Maps to "city" in JSON
    let stateID: String     // Maps to "state_id" in JSON
    let stateName: String   // Maps to "state_name" in JSON
    let countyName: String  // Maps to "county_name" in JSON
    let latitude: Double    // Maps to "lat" in JSON
    let longitude: Double   // Maps to "lng" in JSON

    enum CodingKeys: String, CodingKey {
        case id = "zip"
        case cityName = "city"
        case stateID = "state_id"
        case stateName = "state_name"
        case countyName = "county_name"
        case latitude = "lat"
        case longitude = "lng"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - StateModel
struct StateModel: Identifiable, Hashable, Comparable {
    var id: String { stateID }
    let stateID: String
    let stateName: String

    static func < (lhs: StateModel, rhs: StateModel) -> Bool {
        lhs.stateName < rhs.stateName
    }
}

// MARK: - ZipCodeDatabase
enum ZipCodeDatabase {
    private static var records: [ZipCodeModel] = []
    private static var isLoaded = false

    private static let stateNames: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
        "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
        "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
        "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri",
        "MT": "Montana", "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey",
        "NM": "New Mexico", "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio",
        "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina",
        "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont",
        "VA": "Virginia", "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
        "DC": "District of Columbia"
    ]

    /// Loads uszips.json from the app bundle
    static func loadDatabase() -> [ZipCodeModel] {
        if isLoaded { return records }

        guard let url = Bundle.main.url(forResource: "uszips", withExtension: "json") else {
            print("❌ uszips.json not found in the app bundle")
            return fallbackRecords
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([ZipCodeModel].self, from: data)
            records = decoded
            isLoaded = true
            print("✅ Loaded \(decoded.count) ZIP codes from uszips.json")
            return decoded
        } catch {
            print("❌ Failed to decode uszips.json: \(error)")
            return fallbackRecords
        }
    }

    /// Helper for single ZIP lookups
    static func getSampleZip(id: String) -> ZipCodeModel {
        let db = loadDatabase()
        if let found = db.first(where: { $0.id == id }) {
            return found
        }
        return ZipCodeModel(
            id: id,
            cityName: "Unknown",
            stateID: "XX",
            stateName: "Unknown",
            countyName: "Unknown",
            latitude: 0,
            longitude: 0
        )
    }

    /// Get all unique states sorted alphabetically
    static func getAllStates() -> [StateModel] {
        let all = loadDatabase()
        var uniqueStates: [String: String] = [:]
        for r in all {
            let name = stateNames[r.stateID] ?? r.stateName
            uniqueStates[r.stateID] = name
        }
        return uniqueStates.map { StateModel(stateID: $0.key, stateName: $0.value) }.sorted()
    }

    /// Autocomplete city search filtered by selected state IDs
    static func searchCities(query: String, inStates stateIDs: Set<String>) -> [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let all = loadDatabase()
        let cleanQuery = query.lowercased().trimmingCharacters(in: .whitespaces)

        let filtered = all.filter { record in
            (stateIDs.isEmpty || stateIDs.contains(record.stateID)) &&
            record.cityName.lowercased().hasPrefix(cleanQuery)
        }

        return Array(Set(filtered.map { $0.cityName })).sorted().prefix(15).map { $0 }
    }

    /// Pull target ZIP codes for selected States and Cities (or All Cities)
    static func getZipCodes(
        selectedStates: Set<String>,
        selectedCities: Set<String>,
        selectAllCities: Bool
    ) -> [ZipCodeModel] {
        let all = loadDatabase()
        return all.filter { record in
            guard selectedStates.isEmpty || selectedStates.contains(record.stateID) else { return false }
            if selectAllCities { return true }
            return selectedCities.contains(record.cityName)
        }
    }

    private static let fallbackRecords: [ZipCodeModel] = [
        ZipCodeModel(
            id: "95814",
            cityName: "Sacramento",
            stateID: "CA",
            stateName: "California",
            countyName: "Sacramento",
            latitude: 38.5815,
            longitude: -121.4944
        ),
        ZipCodeModel(
            id: "95816",
            cityName: "Sacramento",
            stateID: "CA",
            stateName: "California",
            countyName: "Sacramento",
            latitude: 38.5721,
            longitude: -121.4682
        ),
        ZipCodeModel(
            id: "77001",
            cityName: "Houston",
            stateID: "TX",
            stateName: "Texas",
            countyName: "Harris",
            latitude: 29.7604,
            longitude: -95.3698
        )
    ]
}
