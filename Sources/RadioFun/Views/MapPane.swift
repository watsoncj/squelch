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
    var selectedMessage: DecodedMessage?
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"
    @AppStorage(SettingsKeys.mapStyle) private var mapStyleRaw = MapStyleChoice.standard.rawValue

    @State private var camera: MapCameraPosition = .automatic
    @State private var hoveredGrid: String?

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
                            hoveredGrid = cellsByGrid[key] != nil ? key : nil
                        } else {
                            hoveredGrid = nil
                        }
                    case .ended:
                        hoveredGrid = nil
                    }
                }
        }
    }

    private var mapContent: some View {
        Map(position: $camera) {
            // Heard stations light up their Maidenhead grid squares
            ForEach(gridCells) { cell in
                MapPolygon(coordinates: cell.corners)
                    .foregroundStyle(cell.color.opacity(cell.id == hoveredGrid ? 0.5 : 0.30))
                    .stroke(cell.color.opacity(0.8), lineWidth: cell.id == hoveredGrid ? 2 : 1)
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
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(cell.id) — \(cell.stationLines.count) station\(cell.stationLines.count == 1 ? "" : "s")")
                        .font(.caption.bold())
                    ForEach(cell.stationLines.prefix(8), id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                    }
                    if cell.stationLines.count > 8 {
                        Text("… and \(cell.stationLines.count - 8) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
        if let km = message.distanceKm { parts.append(String(format: "%.0f mi", km * 0.621371)) }
        return parts.isEmpty ? message.text : parts.joined(separator: " · ")
    }

    /// One highlighted region per occupied 4-character grid square.
    private struct GridCell: Identifiable {
        let id: String // the 4-char grid
        let corners: [CLLocationCoordinate2D]
        let center: CLLocationCoordinate2D
        let color: Color
        let stationLines: [String]
    }

    private var cellsByGrid: [String: GridCell] {
        Dictionary(uniqueKeysWithValues: gridCells.map { ($0.id, $0) })
    }

    private var gridCells: [GridCell] {
        var byGrid: [String: [Station]] = [:]
        for station in store.stations.values {
            byGrid[String(station.grid.prefix(4)).uppercased(), default: []].append(station)
        }
        return byGrid.compactMap { grid, stations in
            guard let center = Maidenhead.coordinate(forGrid: grid) else { return nil }
            let corners = [
                CLLocationCoordinate2D(latitude: center.latitude - 0.5, longitude: center.longitude - 1.0),
                CLLocationCoordinate2D(latitude: center.latitude - 0.5, longitude: center.longitude + 1.0),
                CLLocationCoordinate2D(latitude: center.latitude + 0.5, longitude: center.longitude + 1.0),
                CLLocationCoordinate2D(latitude: center.latitude + 0.5, longitude: center.longitude - 1.0),
            ]
            let newest = stations.map(\.lastHeard).max() ?? .distantPast
            let calls = stations
                .sorted { $0.lastHeard > $1.lastHeard }
                .map { st in
                    var line = "\(st.callsign) — \(String(format: "%+.0f", st.lastSNR)) dB"
                    if let country = CallsignCountry.lookup(st.callsign) {
                        line += " \(country.flag)"
                    }
                    return line
                }
            return GridCell(
                id: grid,
                corners: corners,
                center: center,
                color: Self.recencyColor(for: newest),
                stationLines: calls
            )
        }
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
