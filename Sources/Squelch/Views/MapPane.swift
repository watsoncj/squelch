import SwiftUI
import MapKit

/// User-selectable map rendering styles. All flat elevation: realistic
/// elevation switches MapKit to a 3D globe at wide zooms, and a band-wide
/// station view is exactly the wide-zoom case.
enum MapStyleChoice: String, CaseIterable, Identifiable {
    case standard = "Map"
    case hybrid = "Hybrid"
    case satellite = "Satellite"

    var id: String { rawValue }

    var style: MapStyle {
        switch self {
        case .standard: return .standard(elevation: .flat)
        case .hybrid: return .hybrid(elevation: .flat)
        case .satellite: return .imagery(elevation: .flat)
        }
    }
}

struct MapPane: View {
    @ObservedObject var store: DecodeStore
    @ObservedObject var location: LocationProvider
    @ObservedObject var stateResolver: StateResolver
    var selectedMessage: DecodedMessage?
    var onSelectStation: ((String) -> Void)? = nil
    /// Points of the map covered by the floating panels on the right —
    /// focus/fit regions shift so targets center in the visible strip.
    var trailingObscuredWidth: CGFloat = 0
    /// Points covered along the bottom (floating waterfall) — the hover
    /// card anchors above it.
    var bottomObscuredHeight: CGFloat = 0
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"
    @AppStorage(SettingsKeys.mapStyle) private var mapStyleRaw = MapStyleChoice.standard.rawValue
    @AppStorage(SettingsKeys.showGridCells) private var showGridCells = true

    @State private var camera: MapCameraPosition = .automatic
    @State private var hasAutoFitted = false
    @State private var hoveredGrid: String?
    /// Snapshot of the rendered squares. Rebuilt only when decodes arrive or
    /// on the aging timer — NEVER derived live in the map content. Rebuilding
    /// MapKit overlays on every view update leaks GPU buffers in VectorKit
    /// until Metal allocation aborts (seen after an overnight session).
    @State private var cells: [GridCell] = []
    @State private var mapWidth: CGFloat = 0

    private static let colorAgingTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        MapReader { proxy in
            mapContent
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        if let coordinate = proxy.convert(point, from: .local),
                           (-90.0...90.0).contains(coordinate.latitude) {
                            // Normalize longitude — a wrapped map can yield values beyond ±180
                            var lon = coordinate.longitude.truncatingRemainder(dividingBy: 360)
                            if lon >= 180 { lon -= 360 }
                            if lon < -180 { lon += 360 }
                            let normalized = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: lon)
                            let key = String(Maidenhead.grid(for: normalized).prefix(4)).uppercased()
                            setHoveredGrid(cellsByGrid[key] != nil ? key : nil)
                        } else {
                            setHoveredGrid(nil)
                        }
                    case .ended:
                        setHoveredGrid(nil)
                    }
                }
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
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { mapWidth = $0 }
        .onAppear { rebuildCellsIfChanged() }
        .onChange(of: store.totalDecodes) { _, _ in rebuildCellsIfChanged() }
        .onReceive(Self.colorAgingTick) { _ in rebuildCellsIfChanged() }
    }

    /// Recenter `region` so its target sits in the middle of the un-obscured
    /// strip, widening the span when fitting so nothing hides behind panels.
    private func adjustedForObscuredEdge(_ region: MKCoordinateRegion, fitAll: Bool) -> MKCoordinateRegion {
        guard mapWidth > 0, trailingObscuredWidth > 0, trailingObscuredWidth < mapWidth else { return region }
        var region = region
        let fraction = trailingObscuredWidth / mapWidth
        if fitAll {
            region.span.longitudeDelta = min(region.span.longitudeDelta / (1 - fraction), 360)
        }
        region.center.longitude += region.span.longitudeDelta * fraction / 2
        return region
    }

    /// Avoid touching @State (and re-diffing map content) on every mouse move.
    private func setHoveredGrid(_ key: String?) {
        if hoveredGrid != key {
            hoveredGrid = key
        }
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
        Map(position: $camera) {
            // Heard stations light up their Maidenhead grid squares
            if showGridCells {
                ForEach(cells) { cell in
                    MapPolygon(coordinates: cell.corners)
                        .foregroundStyle(cell.color.opacity(0.30))
                        .stroke(cell.color.opacity(0.8), lineWidth: 1)
                }

                // Hover highlight: one extra polygon, so pointing at a cell
                // never restyles the whole overlay set
                if let hoveredGrid, let cell = cellsByGrid[hoveredGrid] {
                    MapPolygon(coordinates: cell.corners)
                        .foregroundStyle(cell.color.opacity(0.25))
                        .stroke(.white.opacity(0.9), lineWidth: 2)
                }
            }

            // Selected log row: highlight the stations involved in the
            // contact. Two pins + the path between them for a directed
            // message; one pin + the path from me for a CQ (or when the
            // other side is me / unknown).
            // ForEach keyed by message id so switching selection reliably
            // removes the previous arc (a bare conditional can leave a
            // stale polyline behind in MapKit's content diffing).
            ForEach(selectedArc.map { [$0] } ?? []) { arc in
                MapPolyline(coordinates: arc.coordinates, contourStyle: .geodesic)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            ForEach(selectedContactPoints) { point in
                Annotation(point.id, coordinate: point.coordinate) {
                    SelectedRing(label: point.label)
                }
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
        .overlay(alignment: .bottomLeading) {
            if showGridCells, let key = hoveredGrid, cellsByGrid[key] != nil {
                let rows = hoverRows(forGrid: key)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(key)
                            .font(.caption.bold())
                        Spacer(minLength: 16)
                        Text("\(rows.count) station\(rows.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Grid(horizontalSpacing: 10, verticalSpacing: 2) {
                        ForEach(rows.prefix(8)) { row in
                            GridRow {
                                Text(row.call)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .gridColumnAlignment(.leading)
                                Text(row.ageText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(row.snrText)
                                    .font(.caption.monospaced())
                                    .gridColumnAlignment(.trailing)
                                Text(row.country)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                    if rows.count > 8 {
                        Text("and \(rows.count - 8) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 264, alignment: .leading)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
                .padding(.bottom, bottomObscuredHeight) // clear the waterfall
                .allowsHitTesting(false)
            }
        }
        .onChange(of: selectedMessage?.id) { _, _ in
            focusOnSelection()
        }
    }

    /// The stations involved in the selected message that we can place:
    /// the sender, and — for directed messages — the addressee (from the
    /// station cache). The addressee is skipped when it's me (my blue dot
    /// and the line from it already show that side).
    private struct ContactPoint: Identifiable {
        let id: String
        let coordinate: CLLocationCoordinate2D
        let label: String
    }

    private var selectedContactPoints: [ContactPoint] {
        guard let message = selectedMessage else { return [] }
        var points: [ContactPoint] = []

        let senderCoord = message.coordinate
            ?? message.callsign.flatMap { store.stations[$0]?.coordinate }
        if let senderCoord {
            points.append(ContactPoint(
                id: message.callsign ?? "sender",
                coordinate: senderCoord,
                label: selectedLabel(for: message)
            ))
        }

        if !message.isCQ,
           let addressee = message.addressee,
           addressee != myCallsign.uppercased(),
           let station = store.stations[addressee] {
            points.append(ContactPoint(
                id: addressee,
                coordinate: station.coordinate,
                label: "\(addressee) · \(station.grid)"
            ))
        }
        return points
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

    private func selectedLabel(for message: DecodedMessage) -> String {
        var parts: [String] = []
        if let call = message.callsign { parts.append(call) }
        if let grid = message.grid { parts.append(grid) }
        if let km = message.distanceKm {
            let unit = DistanceUnit.current(UserDefaults.standard.string(forKey: SettingsKeys.distanceUnit) ?? "")
            parts.append(unit.text(fromKm: km))
        }
        return parts.isEmpty ? message.text : parts.joined(separator: " · ")
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
    private struct HoverRow: Identifiable {
        let call: String
        let ageText: String
        let snrText: String
        let country: String
        var id: String { call }
    }

    private func hoverRows(forGrid grid: String) -> [HoverRow] {
        store.stations.values
            .filter {
                String($0.grid.prefix(4)).uppercased() == grid
                    && Self.withinRecencyWindow($0.lastHeard)
            }
            .sorted { $0.lastHeard > $1.lastHeard }
            .map { st in
                var countryText = ""
                if let country = CallsignCountry.lookup(st.callsign) {
                    if FT8MessageParser.isUSCallsign(st.callsign),
                       let state = stateResolver.state(forGrid: st.grid, isUS: true) {
                        countryText = "\(country.flag) \(state), USA"
                    } else {
                        countryText = "\(country.flag) \(country.name)"
                    }
                }
                return HoverRow(
                    call: st.callsign,
                    ageText: Self.ageText(for: st.lastHeard),
                    snrText: String(format: "%+.0f dB", st.lastSNR),
                    country: countryText
                )
            }
    }

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

    /// "now", "12m", "1h" — for the hover roster.
    static func ageText(for lastHeard: Date) -> String {
        let age = Date().timeIntervalSince(lastHeard)
        if age < 60 { return "now" }
        if age < 3600 { return "\(Int(age / 60))m" }
        return "\(Int(age / 3600))h"
    }
}

/// Highlight ring for the station selected in the log.
/// Deliberately STATIC: animated content inside Map makes MapKit clear and
/// rebuild the entire scene (all overlay renderables) every display-link
/// frame — ~6k GPU allocations/s and unbounded memory growth whenever a
/// row was selected.
private struct SelectedRing: View {
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.blue, in: Capsule())
                .foregroundStyle(.white)
            ZStack {
                Circle()
                    .stroke(.blue.opacity(0.45), lineWidth: 5)
                    .frame(width: 30, height: 30)
                Circle()
                    .stroke(.blue, lineWidth: 2.5)
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
            }
        }
    }
}
