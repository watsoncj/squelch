import SwiftUI
import MapKit

/// User-selectable map rendering styles. All flat elevation: realistic
/// elevation switches MapKit to a 3D globe at wide zooms, and a band-wide
/// station view is exactly the wide-zoom case.
enum MapStyleChoice: String, CaseIterable, Identifiable {
    case standard = "Map"
    case hybrid = "Hybrid"
    case satellite = "Satellite"
    /// No-network field mode: bundled Natural Earth coastlines render as
    /// polygons over the (blank) basemap — nothing streams from Apple.
    case offline = "Offline"

    var id: String { rawValue }

    var style: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .flat)
        case .hybrid: return .hybrid(elevation: .flat)
        case .satellite: return .imagery(elevation: .flat)
        case .offline: return .standard(elevation: .flat, pointsOfInterest: .excludingAll)
        }
    }
}

/// Bundled world landmass (Natural Earth 110m, public domain) for the
/// offline map mode. 127 polygons, loaded once on first use.
enum OfflineBasemap {
    struct LandPolygon: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
    }

    static let landPolygons: [LandPolygon] = {
        guard let url = Bundle.module.url(forResource: "ne_110m_land", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let features = try? MKGeoJSONDecoder().decode(data) else { return [] }
        var polygons: [LandPolygon] = []
        for case let feature as MKGeoJSONFeature in features {
            for case let polygon as MKPolygon in feature.geometry {
                var coords = [CLLocationCoordinate2D](
                    repeating: CLLocationCoordinate2D(), count: polygon.pointCount)
                polygon.getCoordinates(&coords, range: NSRange(location: 0, length: polygon.pointCount))
                polygons.append(LandPolygon(id: polygons.count, coordinates: coords))
            }
        }
        return polygons
    }()
}

extension View {
    /// Liquid Glass capsule that adapts to the backdrop's luminance the way
    /// native map controls do (a plain material follows the system scheme
    /// and stays dark over a light map). Fallback for pre-macOS 26.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
                .clipShape(Capsule())
        }
    }
}

struct MapPane: View {
    @ObservedObject var store: DecodeStore
    @ObservedObject var location: LocationProvider
    @ObservedObject var stateResolver: StateResolver
    var selectedMessage: DecodedMessage?
    var onSelectStation: ((String) -> Void)? = nil
    /// Points of the map covered by the floating panels on the left —
    /// focus/fit regions shift so targets center in the visible strip.
    var leadingObscuredWidth: CGFloat = 0
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"
    @AppStorage(SettingsKeys.mapStyle) private var mapStyleRaw = MapStyleChoice.standard.rawValue
    @AppStorage(SettingsKeys.showGridCells) private var showGridCells = true
    @State private var showMapModes = false
    @Namespace private var mapScope

    @State private var camera: MapCameraPosition = .automatic
    @State private var hasAutoFitted = false
    /// Snapshot of the rendered squares. Rebuilt only when decodes arrive or
    /// on the aging timer — NEVER derived live in the map content. Rebuilding
    /// MapKit overlays on every view update leaks GPU buffers in VectorKit
    /// until Metal allocation aborts (seen after an overnight session).
    @State private var cells: [GridCell] = []
    @State private var mapWidth: CGFloat = 0
    /// Latest settled viewport, for the zoom buttons (updated on gesture
    /// end only — per-frame updates would re-diff map content while panning)
    @State private var visibleRegion: MKCoordinateRegion?

    private static let colorAgingTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        MapReader { proxy in
            mapContent
                .onTapGesture { point in
                    // Click a lit grid square → open the detail card for its
                    // most recently heard station
                    guard showGridCells,
                          let coordinate = proxy.convert(point, from: .local),
                          (-90.0...90.0).contains(coordinate.latitude) else { return }
                    var lon = coordinate.longitude.truncatingRemainder(dividingBy: 360)
                    if lon >= 180 { lon -= 360 }
                    if lon < -180 { lon += 360 }
                    let normalized = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: lon)
                    let key = String(Maidenhead.grid(for: normalized).prefix(4)).uppercased()
                    guard cellsByGrid[key] != nil else { return }
                    let best = store.stations.values
                        .filter {
                            String($0.grid.prefix(4)).uppercased() == key
                                && Self.withinRecencyWindow($0.lastHeard)
                        }
                        .max { $0.lastHeard < $1.lastHeard }
                    if let best {
                        onSelectStation?(best.callsign)
                    }
                }
        }
        .overlay(alignment: .topTrailing) {
            sideControls
                .padding(.top, 62) // below the toolbar's radio actions
                .padding(.trailing, 10)
        }
        .mapScope(mapScope)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { mapWidth = $0 }
        .onAppear { rebuildCellsIfChanged() }
        .onChange(of: store.totalDecodes) { _, _ in rebuildCellsIfChanged() }
        .onReceive(Self.colorAgingTick) { _ in rebuildCellsIfChanged() }
    }

    /// Apple Maps-style right-edge stack: view controls capsule, native
    /// zoom stepper, compass (reset-north) at the bottom.
    private var sideControls: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                Button {
                    showMapModes.toggle()
                } label: {
                    Image(systemName: "globe.americas.fill")
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
                .help("Map appearance")
                .popover(isPresented: $showMapModes, arrowEdge: .leading) {
                    MapModeFlyout(mapStyleRaw: $mapStyleRaw)
                }

                Button {
                    zoomToMyStation()
                } label: {
                    Image(systemName: "location")
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
                .help("Center the map on your station")

                sideToggle("square.grid.3x3", isOn: $showGridCells,
                           help: "Show heard stations as highlighted grid squares")
            }
            .padding(.vertical, 8) // inset the end icons from the capsule's round ends
            .buttonStyle(.borderless)
            .glassCapsule()

            // Our own zoom capsule: the native MapZoomStepper's glass has a
            // different base tint than glassCapsule and can't be restyled
            VStack(spacing: 0) {
                Button {
                    zoom(by: 0.5)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
                .help("Zoom in")
                Button {
                    zoom(by: 2)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
                .help("Zoom out")
            }
            .padding(.vertical, 8)
            .buttonStyle(.borderless)
            .glassCapsule()

            MapCompass(scope: mapScope)
        }
    }

    private func sideToggle(_ systemImage: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .help(help)
    }

    private func zoom(by factor: Double) {
        guard let region = visibleRegion ?? camera.region else { return }
        var r = region
        r.span.latitudeDelta = min(max(r.span.latitudeDelta * factor, 0.02), 170)
        r.span.longitudeDelta = min(max(r.span.longitudeDelta * factor, 0.04), 340)
        withAnimation(.easeInOut(duration: 0.3)) {
            camera = .region(r)
        }
    }

    private func zoomToMyStation() {
        guard let me = location.effectiveCoordinate() else { return }
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(adjustedForObscuredEdge(
                MKCoordinateRegion(
                    center: me,
                    span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 8)
                ),
                fitAll: false
            ))
        }
    }

    /// Recenter `region` so its target sits in the middle of the un-obscured
    /// strip, widening the span when fitting so nothing hides behind panels.
    private func adjustedForObscuredEdge(_ region: MKCoordinateRegion, fitAll: Bool) -> MKCoordinateRegion {
        guard mapWidth > 0, leadingObscuredWidth > 0, leadingObscuredWidth < mapWidth else { return region }
        var region = region
        let fraction = leadingObscuredWidth / mapWidth
        if fitAll {
            region.span.longitudeDelta = min(region.span.longitudeDelta / (1 - fraction), 360)
        }
        // Panels cover the west side: pull the camera center west so the
        // target lands mid-strip on the visible east side
        region.center.longitude -= region.span.longitudeDelta * fraction / 2
        return region
    }

    /// Recompute the snapshot; assign only when something actually changed
    /// so MapKit sees no overlay update at all on quiet ticks.
    private func rebuildCellsIfChanged() {
        let fresh = computeGridCells()
        if fresh != cells {
            cells = fresh
        }
        // Pin the camera to an explicit region once content exists:
        // .automatic re-fits (and animates) on EVERY content change, which
        // reads as the UI locking up after each decode cycle
        if !hasAutoFitted, !cells.isEmpty {
            hasAutoFitted = true
            camera = fitAllRegion()
        }
    }

    /// Explicit region covering all cells and my position — used instead of
    /// .automatic so the camera only moves when asked.
    private func fitAllRegion() -> MapCameraPosition {
        var coords = cells.flatMap(\.corners)
        if let me = location.effectiveCoordinate() {
            coords.append(me)
        }
        guard let first = coords.first else { return .automatic }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords.dropFirst() {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.15, 4),
            longitudeDelta: max((maxLon - minLon) * 1.15, 4)
        )
        return .region(adjustedForObscuredEdge(
            MKCoordinateRegion(center: center, span: span), fitAll: true))
    }

    private var mapContent: some View {
        Map(position: $camera, scope: mapScope) {
            // Offline mode: bundled coastlines stand in for streamed tiles.
            // Static constant collection — identity never changes, so
            // MapKit encodes these polygons exactly once.
            if mapStyleRaw == MapStyleChoice.offline.rawValue {
                ForEach(OfflineBasemap.landPolygons) { land in
                    MapPolygon(coordinates: land.coordinates)
                        .foregroundStyle(Color.gray.opacity(0.35))
                        .stroke(Color.gray.opacity(0.7), lineWidth: 0.5)
                }
            }

            // Heard stations light up their Maidenhead grid squares
            if showGridCells {
                ForEach(cells) { cell in
                    MapPolygon(coordinates: cell.corners)
                        .foregroundStyle(cell.color.opacity(0.30))
                        .stroke(cell.color.opacity(0.8), lineWidth: 1)
                }
            }

            // Selected log row: highlight the involved stations' GRID
            // SQUARES (a point marker at the grid center reads as a precise
            // position and routinely lands in the ocean). Rendered even when
            // the station has aged off the recency window.
            // ForEach keyed by message id so switching selection reliably
            // removes the previous arc (a bare conditional can leave a
            // stale polyline behind in MapKit's content diffing).
            ForEach(selectedArc.map { [$0] } ?? []) { arc in
                MapPolyline(coordinates: arc.coordinates, contourStyle: .geodesic)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            ForEach(selectedCellHighlights) { cell in
                MapPolygon(coordinates: cell.corners)
                    .foregroundStyle(.blue.opacity(0.18))
                    .stroke(.blue.opacity(0.9), lineWidth: 2)
            }

            if let me = location.effectiveCoordinate() {
                Annotation("\(myCallsign) (me)", coordinate: me) {
                    ZStack {
                        Circle().fill(.blue.opacity(0.25)).frame(width: 26, height: 26)
                        Circle().fill(.blue).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
        }
        .mapStyle((MapStyleChoice(rawValue: mapStyleRaw) ?? .standard).style)
        .mapControls { } // defaults off — the side stack provides them
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        .onChange(of: selectedMessage?.id) { _, _ in
            focusOnSelection()
        }
    }

    /// The stations involved in the selected message that we can place:
    /// the sender, and — for directed messages — the addressee (from the
    /// station cache). Used for the arc and camera framing; the visible
    /// highlight is the grid square, not a point.
    private struct ContactPoint: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
    }

    private var selectedContactPoints: [ContactPoint] {
        guard let message = selectedMessage else { return [] }
        var points: [ContactPoint] = []

        let senderCoord = message.coordinate
            ?? message.callsign.flatMap { store.stations[$0]?.coordinate }
        if let senderCoord {
            points.append(ContactPoint(
                id: message.callsign ?? "sender",
                coordinate: senderCoord
            ))
        }

        if !message.isCQ,
           let addressee = message.addressee,
           addressee != myCallsign.uppercased(),
           let station = store.stations[addressee] {
            points.append(ContactPoint(
                id: addressee,
                coordinate: station.coordinate
            ))
        }
        return points
    }

    /// Blue-highlighted grid squares for the selected contact's stations.
    private struct SelectedCell: Identifiable {
        let id: String // call + grid
        let corners: [CLLocationCoordinate2D]
    }

    private var selectedCellHighlights: [SelectedCell] {
        guard let message = selectedMessage else { return [] }
        var cells: [SelectedCell] = []

        func append(call: String, grid: String?) {
            let grid4 = grid ?? store.stations[call]?.grid
            guard let grid4,
                  let center = Maidenhead.coordinate(forGrid: String(grid4.prefix(4))) else { return }
            cells.append(SelectedCell(
                id: "\(call)-\(grid4.prefix(4))",
                corners: [
                    CLLocationCoordinate2D(latitude: center.latitude - 0.5, longitude: center.longitude - 1.0),
                    CLLocationCoordinate2D(latitude: center.latitude - 0.5, longitude: center.longitude + 1.0),
                    CLLocationCoordinate2D(latitude: center.latitude + 0.5, longitude: center.longitude + 1.0),
                    CLLocationCoordinate2D(latitude: center.latitude + 0.5, longitude: center.longitude - 1.0),
                ]
            ))
        }

        if let call = message.callsign {
            append(call: call, grid: message.grid)
        }
        if !message.isCQ,
           let addressee = message.addressee,
           addressee != myCallsign.uppercased(),
           store.stations[addressee] != nil {
            append(call: addressee, grid: nil)
        }
        return cells
    }

    private struct SelectedArc: Identifiable {
        let id: UUID // the selected message's id
        let coordinates: [CLLocationCoordinate2D]
    }

    /// Arc for the selected contact. CQs get no arc — a CQ has one node.
    /// Directed messages: between both stations when the addressee is
    /// placeable, from my node when the message is addressed to me,
    /// otherwise none.
    private var selectedArc: SelectedArc? {
        guard let message = selectedMessage, !message.isCQ else { return nil }
        let points = selectedContactPoints
        if points.count == 2 {
            return SelectedArc(id: message.id, coordinates: points.map(\.coordinate))
        }
        if let only = points.first,
           message.addressee == myCallsign.uppercased(),
           let me = location.effectiveCoordinate() {
            return SelectedArc(id: message.id, coordinates: [me, only.coordinate])
        }
        return nil
    }

    /// Move the camera to frame the selection: the arc's endpoints when
    /// there is an arc, otherwise just the station node.
    private func focusOnSelection() {
        let coords = selectedArc?.coordinates ?? selectedContactPoints.map(\.coordinate)
        guard let first = coords.first else { return }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for coord in coords.dropFirst() {
            minLat = min(minLat, coord.latitude); maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude); maxLon = max(maxLon, coord.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.6, 4),
            longitudeDelta: max((maxLon - minLon) * 1.6, 4)
        )
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(adjustedForObscuredEdge(
                MKCoordinateRegion(center: center, span: span), fitAll: false))
        }
    }

    /// One highlighted region per occupied 4-character grid square.
    /// Identity is deliberately just grid + color: including per-station
    /// hover data made cells "change" on nearly every decode, forcing
    /// MapKit to re-encode ~400 polygons each slot (main-thread stall) and
    /// steadily leak VectorKit GPU buffers. The hover roster is computed
    /// live from the station cache instead.
    private struct GridCell: Identifiable, Equatable {
        let id: String // the 4-char grid
        let corners: [CLLocationCoordinate2D]
        let center: CLLocationCoordinate2D
        let color: Color

        static func == (lhs: GridCell, rhs: GridCell) -> Bool {
            lhs.id == rhs.id && lhs.color == rhs.color
        }
    }

    private var cellsByGrid: [String: GridCell] {
        Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) })
    }

    private func computeGridCells() -> [GridCell] {
        var byGrid: [String: [Station]] = [:]
        for station in store.stations.values where Self.withinRecencyWindow(station.lastHeard) {
            byGrid[String(station.grid.prefix(4)).uppercased(), default: []].append(station)
        }
        // Sorted so repeated computations compare equal (dictionary order
        // is nondeterministic, which would defeat the change check)
        return byGrid.compactMap { grid, stations in
            guard let center = Maidenhead.coordinate(forGrid: grid) else { return nil }
            let corners = [
                CLLocationCoordinate2D(latitude: center.latitude - 0.5, longitude: center.longitude - 1.0),
                CLLocationCoordinate2D(latitude: center.latitude - 0.5, longitude: center.longitude + 1.0),
                CLLocationCoordinate2D(latitude: center.latitude + 0.5, longitude: center.longitude + 1.0),
                CLLocationCoordinate2D(latitude: center.latitude + 0.5, longitude: center.longitude - 1.0),
            ]
            let newest = stations.map(\.lastHeard).max() ?? .distantPast
            return GridCell(
                id: grid,
                corners: corners,
                center: center,
                color: Self.recencyColor(for: newest)
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// Hover roster, computed only for the cell under the cursor.
    /// The map shows current propagation, not the archive: stations age off
    /// entirely after this. (The log keeps full history.)
    static let recencyWindowSeconds: TimeInterval = 3600

    /// Red → orange → gray, with gray fading in coarse steps toward the
    /// window edge. Steps (not a continuous ramp) so quiet 30 s ticks
    /// usually change nothing and the overlay set stays untouched.
    static func recencyColor(for lastHeard: Date) -> Color {
        let age = Date().timeIntervalSince(lastHeard)
        if age < 120 { return .red }
        if age < 600 { return .orange }
        if age < 1500 { return .gray }
        if age < 2400 { return .gray.opacity(0.7) }
        return .gray.opacity(0.45)
    }

    static func withinRecencyWindow(_ lastHeard: Date) -> Bool {
        Date().timeIntervalSince(lastHeard) < recencyWindowSeconds
    }

}

/// Apple Maps-style "Map Modes" flyout: one tile per style.
struct MapModeFlyout: View {
    @Binding var mapStyleRaw: String

    private func icon(for choice: MapStyleChoice) -> String {
        switch choice {
        case .standard: return "map"
        case .hybrid: return "square.3.layers.3d.top.filled"
        case .satellite: return "globe.americas.fill"
        case .offline: return "wifi.slash"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Map Mode")
                .font(.headline)
            HStack(spacing: 14) {
                ForEach(MapStyleChoice.allCases) { choice in
                    let selected = mapStyleRaw == choice.rawValue
                    Button {
                        mapStyleRaw = choice.rawValue
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: icon(for: choice))
                                .font(.title2)
                                .frame(width: 58, height: 42)
                                .background(
                                    selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9)
                                        .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
                                )
                            Text(choice.rawValue)
                                .font(.caption)
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
    }
}

