import Foundation
import Accelerate
import CoreGraphics

/// Rolling spectrogram of the 200–3000 Hz passband. Consumes the decoder's
/// 12 kHz sample stream, produces a CGImage (newest row on top) at ~3 fps.
/// Plain SwiftUI rendering — deliberately nowhere near MapKit overlays.
final class WaterfallProcessor: ObservableObject {
    static let minHz: Double = 200
    static let maxHz: Double = 3000

    /// The rendered spectrogram plus the absolute pooled-row index of its
    /// top (newest) edge — the pane uses the index delta between frames to
    /// hold a scrolled-back view stationary while new rows arrive — and
    /// one wall-clock date per pooled row (oldest first), which maps a
    /// decode's slot time onto image rows even across decoding gaps.
    struct Frame {
        let image: CGImage
        let newestRow: Int
        let rowDates: [Date]
    }

    @Published private(set) var frame: Frame?

    var image: CGImage? { frame?.image }

    private let sampleRate = Double(FT8Decoder.sampleRate)
    private let fftSize = 2048
    private let log2n = vDSP_Length(11)
    private let hop = 1800 // 150 ms per row
    private let historyRows = 2400 // ~6 min of history, scrollable in the pane

    private let queue = DispatchQueue(label: "squelch.waterfall", qos: .utility)
    private var fftSetup: FFTSetup?
    private var window = [Float]()
    private var pending = [Float]()
    private var rows: [[UInt8]] = [] // palette indices, oldest first
    private var rowDates: [Date] = [] // wall-clock arrival, parallel to rows
    private var totalRows = 0 // monotonic count of rows ever appended
    private var rowsSinceImage = 0
    private var palette = WaterfallProcessor.palettes[.standard]!

    private var binLo: Int { Int((Self.minHz / sampleRate * Double(fftSize)).rounded()) }
    private var binHi: Int { Int((Self.maxHz / sampleRate * Double(fftSize)).rounded()) }
    private var binCount: Int { binHi - binLo }

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    /// Safe to call from the audio thread.
    func ingest(_ samples: [Float]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.append(contentsOf: samples)
            self.drain()
        }
    }

    /// Recolor to match the basemap and appearance; history recolors
    /// immediately since rows store intensity, not color. Dark mode
    /// paints toward white over the dark pane material; light mode
    /// darkens toward deep tones over the light material — the alpha
    /// ramp (silence transparent, signal solid) is shared.
    func setStyle(_ style: MapStyleChoice, dark: Bool) {
        queue.async { [weak self] in
            guard let self,
                  let palette = (dark ? Self.palettes : Self.palettesLight)[style] else { return }
            self.palette = palette
            self.rebuildImage()
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.removeAll()
            self.rows.removeAll()
            self.rowDates.removeAll()
            self.totalRows = 0
            DispatchQueue.main.async { self.frame = nil }
        }
    }

    // MARK: - Frequency ↔ x mapping (used by the view; unit-tested)

    static func frequency(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return minHz }
        let f = minHz + (maxHz - minHz) * Double(x / width)
        return min(max(f, minHz), maxHz)
    }

    static func x(forFrequency f: Double, width: CGFloat) -> CGFloat {
        width * CGFloat((f - minHz) / (maxHz - minHz))
    }

    // MARK: - DSP

    private func drain() {
        while pending.count >= fftSize {
            addRow(Array(pending[0..<fftSize]))
            pending.removeFirst(hop)
        }
        if rowsSinceImage >= 2 {
            rowsSinceImage = 0
            rebuildImage()
        }
    }

    private func addRow(_ frame: [Float]) {
        guard let fftSetup else { return }
        let half = fftSize / 2

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Digital silence has zero-magnitude bins; log10(0) = -inf, and
        // -inf − -inf = NaN, which traps in the UInt8 conversion. Nudge all
        // magnitudes off zero so silence is merely "very quiet".
        var epsilon: Float = 1e-20
        vDSP_vsadd(magnitudes, 1, &epsilon, &magnitudes, 1, vDSP_Length(half))

        var db = [Float](repeating: 0, count: half)
        var reference: Float = 1
        vDSP_vdbcon(magnitudes, 1, &reference, &db, 1, vDSP_Length(half), 0)

        let band = Array(db[binLo..<binHi])
        // Normalize each row against its own median: flattens slot-to-slot
        // band-level swings (which read as horizontal banding) while
        // signals — well above the median — stay bright.
        let median = band.sorted()[band.count / 2]
        let floor = median.isFinite ? median - 2 : -180
        let span: Float = 38
        let row = band.map { value -> UInt8 in
            let t = (value - floor) / span
            guard t.isFinite else { return 0 } // belt and braces vs NaN/inf
            return UInt8(min(max(t, 0), 1) * 255)
        }
        rows.append(row)
        rowDates.append(Date())
        totalRows += 1
        if rows.count > historyRows {
            rowDates.removeFirst(rows.count - historyRows)
            rows.removeFirst(rows.count - historyRows)
        }
        rowsSinceImage += 1
    }

    private func rebuildImage() {
        guard !rows.isEmpty else { return }
        let width = binCount

        // Max-pool pairs of rows to a FIXED time scale — 300 ms per image
        // row — so the pane shows a window onto history at constant zoom
        // and scrolls through the rest. 1:1-ish pixel mapping keeps 12.6 s
        // signals as SOLID vertical streaks (plain scaling drops rows and
        // chops them into dashes). Pairing is anchored to each row's
        // ABSOLUTE index, so appends and history-cap trims never rejigger
        // existing pairs — pooled rows are stable, and the pane can track
        // positions across frames by pooled-row index.
        let firstAbsolute = totalRows - rows.count
        var pooled: [[UInt8]] = []
        var pooledDates: [Date] = []
        pooled.reserveCapacity(rows.count / 2 + 1)
        pooledDates.reserveCapacity(rows.count / 2 + 1)
        var index = 0
        while index < rows.count {
            let span = (firstAbsolute + index).isMultiple(of: 2) ? 2 : 1
            let upper = min(index + span, rows.count)
            let group = rows[index..<upper]
            var merged = group.first!
            for row in group.dropFirst() {
                for x in 0..<width {
                    merged[x] = max(merged[x], row[x])
                }
            }
            pooled.append(merged)
            pooledDates.append(rowDates[upper - 1])
            index += span
        }

        let height = pooled.count
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (rowIndex, row) in pooled.enumerated() {
            // Newest row at the top of the image
            let y = height - 1 - rowIndex
            let base = y * width * 4
            for x in 0..<width {
                let idx = Int(row[x])
                let color = palette[idx]
                // Liquid-glass waterfall: alpha IS intensity — silence
                // draws nothing (the panel material is the background,
                // identical to the other panels) and signal traces paint
                // toward solid. Premultiplied per bitmapInfo.
                let alpha = idx
                let p = base + x * 4
                pixels[p] = UInt8(Int(color.0) * alpha / 255)
                pixels[p + 1] = UInt8(Int(color.1) * alpha / 255)
                pixels[p + 2] = UInt8(Int(color.2) * alpha / 255)
                pixels[p + 3] = UInt8(alpha)
            }
        }
        let cgImage = pixels.withUnsafeBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: raw.baseAddress),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        if let cgImage {
            let newestRow = (totalRows - 1) / 2
            DispatchQueue.main.async { [weak self] in
                self?.frame = Frame(image: cgImage, newestRow: newestRow, rowDates: pooledDates)
            }
        }
    }

    /// One palette per basemap for DARK appearance, sampled from each
    /// style's dominant tones; traces brighten toward white.
    static let palettes: [MapStyleChoice: [(UInt8, UInt8, UInt8)]] = [
        // Standard dark map: navy water → blue → cyan → warm label yellow
        .standard: makePalette([
            (0.00, (6, 10, 32)),
            (0.35, (14, 48, 128)),
            (0.60, (36, 150, 200)),
            (0.82, (240, 218, 70)),
            (1.00, (255, 255, 255)),
        ]),
        // Hybrid: deep ocean → vegetation greens → sunlit highlight
        .hybrid: makePalette([
            (0.00, (4, 12, 24)),
            (0.38, (18, 58, 42)),
            (0.62, (62, 138, 72)),
            (0.84, (198, 220, 122)),
            (1.00, (255, 255, 255)),
        ]),
        // Satellite: ocean → earth/scrub → desert sand → white
        .satellite: makePalette([
            (0.00, (6, 12, 26)),
            (0.40, (58, 68, 44)),
            (0.66, (138, 118, 70)),
            (0.86, (222, 192, 124)),
            (1.00, (255, 255, 255)),
        ]),
        // Offline: neutral grays matching the coastline rendering
        .offline: makePalette([
            (0.00, (12, 12, 16)),
            (0.40, (70, 74, 84)),
            (0.68, (140, 148, 160)),
            (0.86, (220, 210, 150)),
            (1.00, (255, 255, 255)),
        ]),
    ]

    /// LIGHT-appearance counterparts: the pane material is near-white,
    /// so traces deepen toward dark saturated tones instead of white —
    /// same hue family as each basemap, lightness ramp inverted.
    static let palettesLight: [MapStyleChoice: [(UInt8, UInt8, UInt8)]] = [
        // Standard light map: cool paper grays → blue → deep navy
        .standard: makePalette([
            (0.00, (160, 170, 185)),
            (0.40, (90, 115, 180)),
            (0.70, (35, 70, 150)),
            (1.00, (10, 15, 50)),
        ]),
        // Hybrid: soft sage → vegetation green → forest floor
        .hybrid: makePalette([
            (0.00, (150, 165, 150)),
            (0.40, (90, 130, 90)),
            (0.70, (40, 90, 45)),
            (1.00, (8, 30, 12)),
        ]),
        // Satellite: pale sand → scrub → dark earth
        .satellite: makePalette([
            (0.00, (170, 160, 140)),
            (0.40, (130, 110, 75)),
            (0.70, (90, 65, 30)),
            (1.00, (30, 18, 5)),
        ]),
        // Offline: light grays → charcoal
        .offline: makePalette([
            (0.00, (165, 165, 170)),
            (0.40, (110, 112, 120)),
            (0.70, (60, 62, 70)),
            (1.00, (5, 5, 8)),
        ]),
    ]

    static func makePalette(_ stops: [(Double, (Double, Double, Double))]) -> [(UInt8, UInt8, UInt8)] {
        (0..<256).map { i in
            let t = Double(i) / 255
            var lower = stops[0], upper = stops[stops.count - 1]
            for pair in zip(stops, stops.dropFirst()) where t >= pair.0.0 && t <= pair.1.0 {
                lower = pair.0
                upper = pair.1
                break
            }
            let range = upper.0 - lower.0
            let local = range > 0 ? (t - lower.0) / range : 0
            func lerp(_ a: Double, _ b: Double) -> UInt8 { UInt8(a + (b - a) * local) }
            return (lerp(lower.1.0, upper.1.0), lerp(lower.1.1, upper.1.1), lerp(lower.1.2, upper.1.2))
        }
    }
}
