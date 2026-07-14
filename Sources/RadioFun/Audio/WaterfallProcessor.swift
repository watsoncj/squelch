import Foundation
import Accelerate
import CoreGraphics

/// Rolling spectrogram of the 200–3000 Hz passband. Consumes the decoder's
/// 12 kHz sample stream, produces a CGImage (newest row on top) at ~3 fps.
/// Plain SwiftUI rendering — deliberately nowhere near MapKit overlays.
final class WaterfallProcessor: ObservableObject {
    static let minHz: Double = 200
    static let maxHz: Double = 3000

    @Published private(set) var image: CGImage?

    private let sampleRate = Double(FT8Decoder.sampleRate)
    private let fftSize = 2048
    private let log2n = vDSP_Length(11)
    private let hop = 1800 // 150 ms per row
    private let historyRows = 360 // ~54 s of history

    private let queue = DispatchQueue(label: "radiofun.waterfall", qos: .utility)
    private var fftSetup: FFTSetup?
    private var window = [Float]()
    private var pending = [Float]()
    private var rows: [[UInt8]] = [] // palette indices, oldest first
    private var rowsSinceImage = 0

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

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.removeAll()
            self.rows.removeAll()
            DispatchQueue.main.async { self.image = nil }
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

        var db = [Float](repeating: 0, count: half)
        var reference: Float = 1
        vDSP_vdbcon(magnitudes, 1, &reference, &db, 1, vDSP_Length(half), 0)

        let band = Array(db[binLo..<binHi])
        // Normalize each row against its own median: flattens slot-to-slot
        // band-level swings (which read as horizontal banding) while
        // signals — well above the median — stay bright.
        let median = band.sorted()[band.count / 2]
        let floor = median - 2
        let span: Float = 38
        let row = band.map { value -> UInt8 in
            let t = (value - floor) / span
            return UInt8(min(max(t, 0), 1) * 255)
        }
        rows.append(row)
        if rows.count > historyRows {
            rows.removeFirst(rows.count - historyRows)
        }
        rowsSinceImage += 1
    }

    private func rebuildImage() {
        guard !rows.isEmpty else { return }
        let width = binCount

        // Max-pool time rows down to roughly display resolution so a
        // 1:1-ish pixel mapping keeps 12.6 s signals as SOLID vertical
        // streaks (plain scaling drops rows and chops them into dashes).
        let targetHeight = 132
        let factor = max(1, Int((Double(rows.count) / Double(targetHeight)).rounded(.up)))
        var pooled: [[UInt8]] = []
        pooled.reserveCapacity(rows.count / factor + 1)
        var index = 0
        while index < rows.count {
            let group = rows[index..<min(index + factor, rows.count)]
            var merged = group.first!
            for row in group.dropFirst() {
                for x in 0..<width {
                    merged[x] = max(merged[x], row[x])
                }
            }
            pooled.append(merged)
            index += factor
        }

        let height = pooled.count
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (rowIndex, row) in pooled.enumerated() {
            // Newest row at the top of the image
            let y = height - 1 - rowIndex
            let base = y * width * 4
            for x in 0..<width {
                let color = Self.palette[Int(row[x])]
                let p = base + x * 4
                pixels[p] = color.0
                pixels[p + 1] = color.1
                pixels[p + 2] = color.2
                pixels[p + 3] = 255
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
            DispatchQueue.main.async { [weak self] in
                self?.image = cgImage
            }
        }
    }

    /// Dark navy → blue → cyan → yellow → white.
    static let palette: [(UInt8, UInt8, UInt8)] = {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (6, 10, 32)),
            (0.35, (14, 48, 128)),
            (0.60, (36, 150, 200)),
            (0.82, (240, 218, 70)),
            (1.00, (255, 255, 255)),
        ]
        return (0..<256).map { i in
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
    }()
}
