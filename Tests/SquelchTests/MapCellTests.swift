import XCTest
import CoreLocation
import MapKit
@testable import Squelch

/// Focus recentering around the floating panels: the sidebar covers a
/// west strip, the waterfall a south strip; the target must land centered
/// in what's actually visible.
final class ObscuredEdgeRegionTests: XCTestCase {
    private let denver = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.7, longitude: -105.0),
        span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 8)
    )

    func testSidebarPullsCenterWest() {
        let adjusted = MapPane.regionAdjustedForObscuredEdges(
            denver, fitAll: false, leadingFraction: 0.25, bottomFraction: 0)
        XCTAssertEqual(adjusted.center.longitude, -105.0 - 8 * 0.25 / 2, accuracy: 1e-9)
        XCTAssertEqual(adjusted.center.latitude, 39.7, accuracy: 1e-9)
        XCTAssertEqual(adjusted.span.longitudeDelta, 8, accuracy: 1e-9)
    }

    func testWaterfallPullsCenterSouth() {
        let adjusted = MapPane.regionAdjustedForObscuredEdges(
            denver, fitAll: false, leadingFraction: 0, bottomFraction: 0.2)
        XCTAssertEqual(adjusted.center.latitude, 39.7 - 4 * 0.2 / 2, accuracy: 1e-9,
                       "target must land mid-strip ABOVE the waterfall")
        XCTAssertEqual(adjusted.center.longitude, -105.0, accuracy: 1e-9)
        XCTAssertEqual(adjusted.span.latitudeDelta, 4, accuracy: 1e-9)
    }

    func testBothPanelsCompose() {
        let adjusted = MapPane.regionAdjustedForObscuredEdges(
            denver, fitAll: false, leadingFraction: 0.25, bottomFraction: 0.2)
        XCTAssertEqual(adjusted.center.longitude, -106.0, accuracy: 1e-9)
        XCTAssertEqual(adjusted.center.latitude, 39.3, accuracy: 1e-9)
    }

    func testFitAllWidensBothSpans() {
        let adjusted = MapPane.regionAdjustedForObscuredEdges(
            denver, fitAll: true, leadingFraction: 0.25, bottomFraction: 0.2)
        XCTAssertEqual(adjusted.span.longitudeDelta, 8 / 0.75, accuracy: 1e-9)
        XCTAssertEqual(adjusted.span.latitudeDelta, 4 / 0.8, accuracy: 1e-9)
    }

    func testNoPanelsNoChange() {
        let adjusted = MapPane.regionAdjustedForObscuredEdges(
            denver, fitAll: true, leadingFraction: 0, bottomFraction: 0)
        XCTAssertEqual(adjusted.center.latitude, 39.7, accuracy: 1e-9)
        XCTAssertEqual(adjusted.center.longitude, -105.0, accuracy: 1e-9)
        XCTAssertEqual(adjusted.span.latitudeDelta, 4, accuracy: 1e-9)
    }
}

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
