import CoreLocation
import Foundation

struct StateID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}

struct CityID: Codable, Hashable, Comparable, Sendable {
    let stateID: StateID
    let normalizedName: String

    init(stateID: StateID, normalizedName: String) {
        self.stateID = stateID
        self.normalizedName = normalizedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.stateID, lhs.normalizedName) < (rhs.stateID, rhs.normalizedName)
    }
}

struct PostalCodeID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}

struct City: Identifiable, Codable, Hashable, Sendable {
    let id: CityID
    let name: String
    let stateName: String

    var displayName: String { "\(name), \(stateName)" }
}

struct PostalCodeRecord: Identifiable, Hashable, Codable, Sendable {
    let id: PostalCodeID
    let cityName: String
    let stateID: StateID
    let stateName: String
    let countyName: String
    let latitude: Double
    let longitude: Double

    var cityID: CityID { CityID(stateID: stateID, normalizedName: cityName) }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    enum CodingKeys: String, CodingKey {
        case id = "zip", cityName = "city", stateID = "state_id"
        case stateName = "state_name", countyName = "county_name"
        case latitude = "lat", longitude = "lng"
    }
}

enum SearchScope: Hashable, Sendable {
    case selectedCities(Set<CityID>)
    case allCities(in: Set<StateID>)
}

struct StateRecord: Identifiable, Hashable, Comparable, Sendable {
    let id: StateID
    let name: String
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.name < rhs.name }
}

typealias ZipCodeModel = PostalCodeRecord
