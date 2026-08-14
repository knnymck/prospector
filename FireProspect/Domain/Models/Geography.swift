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

/// The cities, states, and ZIP codes the user asked to search. MapKit results
/// outside this area are discarded so the device location cannot leak in.
struct SearchArea: Sendable {
    static let maximumDistanceMeters: Double = 65_000

    let postalCodes: Set<String>
    let cities: Set<CityID>
    let states: Set<StateID>
    let includesEveryCityInSelectedStates: Bool
    let zipCoordinates: [(latitude: Double, longitude: Double)]

    init(
        postalCodes: [PostalCodeRecord],
        selectedCityIDs: Set<CityID>,
        selectedStates: Set<StateID>,
        includesEveryCityInSelectedStates: Bool
    ) {
        self.postalCodes = Set(postalCodes.map { Self.normalizedPostalCode($0.id.rawValue) }.filter { !$0.isEmpty })
        self.cities = includesEveryCityInSelectedStates ? [] : selectedCityIDs
        self.states = selectedStates
        self.includesEveryCityInSelectedStates = includesEveryCityInSelectedStates
        self.zipCoordinates = postalCodes.map { ($0.latitude, $0.longitude) }
    }

    func contains(_ candidate: ProspectCandidate) -> Bool {
        if let postalCode = candidate.address.postalCode.flatMap({ Self.normalizedPostalCode($0) }),
           !postalCode.isEmpty,
           postalCodes.contains(postalCode) {
            return true
        }

        if let cityID = cityID(from: candidate.address) {
            if includesEveryCityInSelectedStates, states.contains(cityID.stateID) { return true }
            if cities.contains(cityID) { return true }
        }

        if let state = stateID(from: candidate.address.state), !states.contains(state) {
            return false
        }

        return isNearSelectedZIP(latitude: candidate.latitude, longitude: candidate.longitude)
    }

    static func normalizedPostalCode(_ value: String) -> String {
        let digits = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.count >= 5, digits.prefix(5).allSatisfy(\.isNumber) {
            return String(digits.prefix(5))
        }
        return digits
    }

    private func cityID(from address: PostalAddress) -> CityID? {
        guard let city = address.city, let state = stateID(from: address.state) else { return nil }
        return CityID(stateID: state, normalizedName: city)
    }

    private func stateID(from value: String?) -> StateID? {
        StateID(addressValue: value)
    }

    private func isNearSelectedZIP(latitude: Double, longitude: Double) -> Bool {
        guard latitude != 0 || longitude != 0 else { return false }
        let here = CLLocation(latitude: latitude, longitude: longitude)
        return zipCoordinates.contains { coordinate in
            let zip = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return here.distance(from: zip) <= Self.maximumDistanceMeters
        }
    }
}

extension StateID {
    init?(addressValue: String?) {
        guard let raw = addressValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.count == 2 {
            self.init(rawValue: raw)
            return
        }
        if let match = BundledGeographyRepository.fullStateNames.first(where: { $0.value.caseInsensitiveCompare(raw) == .orderedSame }) {
            self.init(rawValue: match.key)
            return
        }
        return nil
    }
}

struct StateRecord: Identifiable, Hashable, Comparable, Sendable {
    let id: StateID
    let name: String
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.name < rhs.name }
}

typealias ZipCodeModel = PostalCodeRecord
