import Foundation
import MapKit

enum MapKitProspectAdapter {
    static func candidate(
        from item: MKMapItem,
        query: String,
        postalCode: PostalCodeID,
        discoveredAt: Date = Date()
    ) -> ProspectCandidate? {
        guard let websiteURL = item.url,
              let id = ProspectID(websiteURL: websiteURL) else { return nil }

        let address = PostalAddress(
            street: [item.placemark.subThoroughfare, item.placemark.thoroughfare]
                .compactMap { $0 }.joined(separator: " ").nilIfEmpty,
            city: item.placemark.locality,
            state: item.placemark.administrativeArea,
            postalCode: item.placemark.postalCode
        )
        return ProspectCandidate(
            id: id,
            name: item.name ?? id.rawValue,
            websiteURL: websiteURL,
            phoneNumber: item.phoneNumber,
            address: address,
            latitude: item.placemark.coordinate.latitude,
            longitude: item.placemark.coordinate.longitude,
            provenance: .init(
                source: .mapKit,
                query: query,
                postalCode: postalCode,
                discoveredAt: .init(rawValue: discoveredAt)
            )
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
