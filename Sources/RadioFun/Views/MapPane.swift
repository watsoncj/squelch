import SwiftUI
import MapKit

struct MapPane: View {
    @ObservedObject var store: DecodeStore
    @ObservedObject var location: LocationProvider
    var selectedMessage: DecodedMessage?
    @AppStorage(SettingsKeys.myCallsign) private var myCallsign = "W0CJW"

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            ForEach(sortedStations) { station in
                Annotation(station.callsign, coordinate: station.coordinate) {
                    StationPin(station: station)
                }
                .annotationTitles(.automatic)
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
        .mapStyle(.standard(elevation: .flat))
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
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

    private var sortedStations: [Station] {
        store.stations.values.sorted { $0.lastHeard < $1.lastHeard }
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

private struct StationPin: View {
    let station: Station

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .shadow(radius: 1)
            .help(helpText)
    }

    /// Recently heard stations glow hot; older ones fade out.
    private var color: Color {
        let age = Date().timeIntervalSince(station.lastHeard)
        if age < 120 { return .red }
        if age < 600 { return .orange }
        return .gray
    }

    private var helpText: String {
        var parts = ["\(station.callsign) — \(station.grid)"]
        if let d = station.distanceKm {
            parts.append(String(format: "%.0f mi", d * 0.621371))
        }
        parts.append("heard \(station.heardCount)×, last SNR \(String(format: "%+.0f", station.lastSNR)) dB")
        return parts.joined(separator: "\n")
    }
}
