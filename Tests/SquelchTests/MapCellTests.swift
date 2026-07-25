import XCTest
import CoreLocation
@testable import Squelch

final class MapCellTests: XCTestCase {

    func testCellPerimeterCoversTheCellWithShortSegments() {
        let center = CLLocationCoordinate2D(latitude: 48.5, longitude: -89.0) // EN58
        let points = MapPane.cellPerimeter(center: center)

        // 2×(8 + 4) vertices for a 1°×2° cell at 0.25° steps
        XCTAssertEqual(points.count, 24)

        for p in points {
            XCTAssertGreaterThanOrEqual(p.latitude, 48.0 - 1e-9)
            XCTAssertLessThanOrEqual(p.latitude, 49.0 + 1e-9)
            XCTAssertGreaterThanOrEqual(p.longitude, -90.0 - 1e-9)
            XCTAssertLessThanOrEqual(p.longitude, -88.0 + 1e-9)
        }

        // No segment longer than the densification step (the artifact this
        // guards against is VectorKit culling long segments)
        for (a, b) in zip(points, points.dropFirst() + [points[0]]) {
            let d = max(abs(a.latitude - b.latitude), abs(a.longitude - b.longitude))
            XCTAssertLessThanOrEqual(d, 0.25 + 1e-9)
        }

        // All four corners present
        func contains(_ lat: Double, _ lon: Double) -> Bool {
            points.contains { abs($0.latitude - lat) < 1e-9 && abs($0.longitude - lon) < 1e-9 }
        }
        XCTAssertTrue(contains(48.0, -90.0))
        XCTAssertTrue(contains(48.0, -88.0))
        XCTAssertTrue(contains(49.0, -88.0))
        XCTAssertTrue(contains(49.0, -90.0))
    }
}
