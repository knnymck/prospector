import Foundation
import MapKit

actor MapKitSearchService {
    
    struct ProspectResult: Identifiable, Sendable {
        let id: String
        let name: String
        let domainURL: String
        let zipCode: String
        let coordinate: CLLocationCoordinate2D
    }
    
    func searchZipCode(category: String, zip: ZipCodeModel) async throws -> [ProspectResult] {
        print("🔍 Starting grid search for '\(category)' in Zip: \(zip.id)...")
        
        let latOffset = 0.015
        let lonOffset = 0.015
        
        let gridCenters: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: zip.coordinate.latitude + (latOffset * 0.8), longitude: zip.coordinate.longitude - (lonOffset * 0.8)),
            CLLocationCoordinate2D(latitude: zip.coordinate.latitude + (latOffset * 0.8), longitude: zip.coordinate.longitude + (lonOffset * 0.8)),
            CLLocationCoordinate2D(latitude: zip.coordinate.latitude - (latOffset * 0.8), longitude: zip.coordinate.longitude - (lonOffset * 0.8)),
            CLLocationCoordinate2D(latitude: zip.coordinate.latitude - (latOffset * 0.8), longitude: zip.coordinate.longitude + (lonOffset * 0.8))
        ]
        
        var allFoundItems: [MKMapItem] = []
        
        try await withThrowingTaskGroup(of: [MKMapItem].self) { group in
            for centerPoint in gridCenters {
                group.addTask {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = category
                    
                    let region = MKCoordinateRegion(
                        center: centerPoint,
                        latitudinalMeters: 2000,
                        longitudinalMeters: 2000
                    )
                    request.region = region
                    
                    let search = MKLocalSearch(request: request)
                    let response = try await search.start()
                    return response.mapItems
                }
            }
            
            for try await items in group {
                allFoundItems.append(contentsOf: items)
            }
        }
        
        var uniqueProspects: [String: ProspectResult] = [:]
        
        for item in allFoundItems {
            guard let url = item.url?.absoluteString.lowercased(), !url.isEmpty else { continue }
            
            if url.contains("facebook.com") || url.contains("yelp.com") || url.contains("yellowpages.com") || url.contains("instagram.com") {
                continue
            }
            
            if let host = item.url?.host {
                let domainKey = "https://" + host
                if uniqueProspects[domainKey] == nil {
                    uniqueProspects[domainKey] = ProspectResult(
                        id: domainKey,
                        name: item.name ?? "Unknown Business",
                        domainURL: domainKey,
                        zipCode: zip.id,
                        coordinate: item.placemark.coordinate
                    )
                }
            }
        }
        
        return Array(uniqueProspects.values)
    }
}
