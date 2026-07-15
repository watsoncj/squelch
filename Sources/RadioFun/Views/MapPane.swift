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
    @AppStorage(SettingsKeys.usDisplay) private var usDisplayRaw = USDisplay.country.rawValue
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"
    @AppStorage(SettingsKeys.mapStyle) private var mapStyleRaw = MapStyleChoice.standard.rawValue

    @State private var camera: MapCameraPosition = .automatic
    @State private var hoveredGrid: String?
    /// Snapshot of the rendered squares. Rebuilt only when decodes arrive or
    /// on the aging timer — NEVER derived live in the map content. Rebuilding
    /// MapKit overlays on every view update leaks GPU buffers in VectorKit
    /// until Metal allocation aborts (seen after an overnight session).
    @State private var cells: [GridCell] = []

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
        }
        .onAppear { rebuildCellsIfChanged() }
        .onChange(of: store.totalDecodes) { _, _ in rebuildCellsIfChanged() }
        .onReceive(Self.colorAgingTick) { _ in rebuildCellsIfChanged() }
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
    }

    private var mapContent: some View {
        Map(position: $camera) {
            // Heard stations light up their Maidenhead grid squares
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
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
                Picker("Map style", selection: $mapStyleRaw) {
                    ForEach(MapStyleChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))

                Button {
                    camera = .automatic
                } label: {
                    Label("Fit All", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))

                Text("\(store.stations.count) stations heard")
                    .font(.caption)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(10)
        }
        .overlay(alignment: .bottomLeading) {
            if let key = hoveredGrid, let cell = cellsByGrid[key] {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(cell.id)
                            .font(.caption.bold())
                        Spacer(minLength: 16)
                        Text("\(cell.rows.count) station\(cell.rows.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Grid(horizontalSpacing: 10, verticalSpacing: 2) {
                        ForEach(cell.rows.prefix(8)) { row in
                            GridRow {
                                Text(row.call)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .gridColumnAlignment(.leading)
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
                    if cell.rows.count > 8 {
                        Text("and \(cell.rows.count - 8) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 240, alignment: .leading)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
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
            camera = .region(MKCoordinateRegion(center: center, span: span))
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
    private struct GridCell: Identifiable, Equatable {
        struct Row: Identifiable, Equatable {
            let call: String
            let snrText: String
            let country: String // "🇯🇵 Japan", empty when unknown
            var id: String { call }
        }

        let id: String // the 4-char grid
        let corners: [CLLocationCoordinate2D]
        let center: CLLocationCoordinate2D
        let color: Color
        let rows: [Row]

        // Corners/center derive from the grid id, so identity + style +
        // roster fully describe the cell.
        static func == (lhs: GridCell, rhs: GridCell) -> Bool {
            lhs.id == rhs.id && lhs.color == rhs.color && lhs.rows == rhs.rows
        }
    }

    private var cellsByGrid: [String: GridCell] {
        Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) })
    }

    private func computeGridCells() -> [GridCell] {
        var byGrid: [String: [Station]] = [:]
        for station in store.stations.values {
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
            let wantState = USDisplay.current(usDisplayRaw) == .state
            let rows = stations
                .sorted { $0.lastHeard > $1.lastHeard }
                .map { st -> GridCell.Row in
                    var countryText = ""
                    if let country = CallsignCountry.lookup(st.callsign) {
                        if wantState, FT8MessageParser.isUSCallsign(st.callsign),
                           let state = stateResolver.state(forGrid: st.grid, isUS: true) {
                            countryText = "\(country.flag) \(state)"
                        } else {
                            countryText = "\(country.flag) \(country.name)"
                        }
                    }
                    return GridCell.Row(
                        call: st.callsign,
                        snrText: String(format: "%+.0f dB", st.lastSNR),
                        country: countryText
                    )
                }
            return GridCell(
                id: grid,
                corners: corners,
                center: center,
                color: Self.recencyColor(for: newest),
                rows: rows
            )
        }
        .sorted { $0.id < $1.id }
    }

    static func recencyColor(for lastHeard: Date) -> Color {
        let age = Date().timeIntervalSince(lastHeard)
        if age < 120 { return .red }
        if age < 600 { return .orange }
        return .gray
    }
}

/// Pulsing highlight ring for the station selected in the log.
private struct SelectedRing: View {
    let label: String
    @State private var pulsing = false

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
                    .stroke(.blue, lineWidth: 2.5)
                    .frame(width: 26, height: 26)
                    .scaleEffect(pulsing ? 1.25 : 0.95)
                    .opacity(pulsing ? 0.4 : 1)
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
            }
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
        }
        .onAppear { pulsing = true }
    }
}
