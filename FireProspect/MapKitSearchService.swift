import Foundation
import MapKit

actor MapKitSearchService {

    func searchZipCode(category: String, zip: ZipCodeModel) async throws -> [ProspectCandidate] {
        print("🔍 Starting grid search for '\(category)' in Zip: \(zip.id.rawValue)...")
        
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
        
        var uniqueProspects: [ProspectID: ProspectCandidate] = [:]
        
        for item in allFoundItems {
            guard let url = item.url?.absoluteString.lowercased(), !url.isEmpty else { continue }
            
            if url.contains("facebook.com") || url.contains("yelp.com") || url.contains("yellowpages.com") || url.contains("instagram.com") {
                continue
            }
            
            if let candidate = MapKitProspectAdapter.candidate(
                from: item,
                query: category,
                postalCode: zip.id
            ), uniqueProspects[candidate.id] == nil {
                uniqueProspects[candidate.id] = candidate
            }
        }
        
        return Array(uniqueProspects.values)
    }
}
