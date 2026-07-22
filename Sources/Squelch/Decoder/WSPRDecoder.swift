import Foundation

/// Clean-room WSPR decoder.
///
/// Pipeline: mix the 12 kHz capture to complex baseband around 1500 Hz,
/// decimate to 375 Hz (256 samples per symbol), build a bank of
/// short-time FFTs, find spectral-peak candidates, align each against the
/// sync vector over a time/frequency/drift grid, demodulate soft bits,
/// and decode the K=32 rate-1/2 convolutional code with a stack
/// (ZJ) sequential decoder — all standard, textbook techniques
/// implemented from the public WSPR specification and coding literature.
/// No WSJT-X/wsprd code was used.
enum WSPRDecoder {
    struct Result: Equatable {
        let call: String
        let grid: String
        let dBm: Int
        let audioFrequencyHz: Double
        let dtSeconds: Double
        let snrDB: Double
    }

    // Baseband parameters
    private static let inRate = 12000.0
    private static let decimation = 32
    private static let basebandRate = 375.0           // 12000 / 32
    private static let symbolSamples = 256            // 0.6827 s at 375 Hz
    private static let fftSize = 512                  // 0.7324 Hz/bin (half tone spacing)
    private static let hop = 32                       // sync time resolution: 85 ms
    private static let mixHz = 1500.0                 // center of the WSPR audio band

    // MARK: - Entry point

    static func decode(_ samples: [Float]) -> [Result] {
        guard samples.count > Int(inRate) * 60 else { return [] }
        let baseband = downconvert(samples)
        let bank = spectraBank(baseband)
        guard !bank.powers.isEmpty else { return [] }

        var results: [Result] = []
        var claimed = Set<String>()
        for candidateBin in candidates(bank) {
            guard let aligned = align(bank, centerBin: candidateBin) else { continue }
            guard aligned.syncQuality > 1.12 else { continue } // sync gate
            let soft = softBits(bank, aligned)
            guard let bits = StackDecoder.decode(soft) else { continue }
            guard let msg = unpackAndVerify(bits: bits, soft: soft) else { continue }
            let key = "\(msg.call) \(msg.grid) \(msg.dBm)"
            guard !claimed.contains(key) else { continue }
            claimed.insert(key)
            results.append(Result(
                call: msg.call, grid: msg.grid, dBm: msg.dBm,
                audioFrequencyHz: mixHz + aligned.freqHz,
                dtSeconds: Double(aligned.startHop * hop) / basebandRate - 1.0,
                snrDB: aligned.snrDB
            ))
        }
        return results
    }

    // MARK: - Downconversion (mix, low-pass FIR, decimate 32×)

    private static let firTaps: [Float] = {
        // Windowed-sinc low-pass, cutoff ~140 Hz at 12 kHz, 255 taps —
        // passes the ±110 Hz WSPR band, rejects above the 187.5 Hz
        // post-decimation Nyquist.
        let n = 255
        let fc = 140.0 / inRate
        var taps = [Float](repeating: 0, count: n)
        let mid = Double(n - 1) / 2
        var sum = 0.0
        for i in 0..<n {
            let x = Double(i) - mid
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let window = 0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(n - 1)) // Hamming
            let v = sinc * window
            taps[i] = Float(v)
            sum += v
        }
        return taps.map { $0 / Float(sum) }
    }()

    private struct Baseband {
        var i: [Float]
        var q: [Float]
    }

    private static func downconvert(_ samples: [Float]) -> Baseband {
        // Mix to baseband
        let n = samples.count
        var mi = [Float](repeating: 0, count: n)
        var mq = [Float](repeating: 0, count: n)
        let w = 2.0 * Double.pi * mixHz / inRate
        // Phase recurrence to avoid n trig calls with drift-free accuracy
        for t in 0..<n {
            let ph = w * Double(t)
            mi[t] = samples[t] * Float(cos(ph))
            mq[t] = samples[t] * -Float(sin(ph))
        }
        // FIR + decimate
        let taps = firTaps
        let outCount = (n - taps.count) / decimation
        var bi = [Float](repeating: 0, count: outCount)
        var bq = [Float](repeating: 0, count: outCount)
        taps.withUnsafeBufferPointer { tp in
            mi.withUnsafeBufferPointer { ip in
                mq.withUnsafeBufferPointer { qp in
                    for k in 0..<outCount {
                        let base = k * decimation
                        var accI: Float = 0, accQ: Float = 0
                        for j in 0..<tp.count {
                            accI += ip[base + j] * tp[j]
                            accQ += qp[base + j] * tp[j]
                        }
                        bi[k] = accI
                        bq[k] = accQ
                    }
                }
            }
        }
        return Baseband(i: bi, q: bq)
    }

    // MARK: - Short-time FFT bank

    private struct SpectraBank {
        /// powers[w][bin]: |FFT|² of the 256-sample window starting at
        /// hop w·32, zero-padded to 512. Bin f = signedBin · 0.7324 Hz.
        var powers: [[Float]]
        var noiseFloor: Float
    }

    private static func spectraBank(_ bb: Baseband) -> SpectraBank {
        let count = bb.i.count
        guard count > symbolSamples else { return SpectraBank(powers: [], noiseFloor: 1) }
        let windows = (count - symbolSamples) / hop
        var powers = [[Float]](repeating: [], count: windows)
        var re = [Float](repeating: 0, count: fftSize)
        var im = [Float](repeating: 0, count: fftSize)
        var floorSamples: [Float] = []
        for w in 0..<windows {
            let start = w * hop
            for j in 0..<fftSize {
                if j < symbolSamples {
                    re[j] = bb.i[start + j]
                    im[j] = bb.q[start + j]
                } else {
                    re[j] = 0
                    im[j] = 0
                }
            }
            fft(&re, &im)
            var p = [Float](repeating: 0, count: fftSize)
            for j in 0..<fftSize {
                p[j] = re[j] * re[j] + im[j] * im[j]
            }
            powers[w] = p
            if w % 16 == 0 {
                floorSamples.append(contentsOf: p)
            }
        }
        let sorted = floorSamples.sorted()
        let floorValue = sorted.isEmpty ? 1 : max(sorted[sorted.count / 2], 1e-12)
        return SpectraBank(powers: powers, noiseFloor: floorValue)
    }

    /// In-place iterative radix-2 complex FFT (textbook Cooley–Tukey).
    private static func fft(_ re: inout [Float], _ im: inout [Float]) {
        let n = re.count
        // Bit-reversal permutation
        var j = 0
        for i in 0..<(n - 1) {
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
            var m = n >> 1
            while m >= 1 && j & m != 0 {
                j ^= m
                m >>= 1
            }
            j |= m
        }
        // Butterflies
        var len = 2
        while len <= n {
            let ang = -2.0 * Float.pi / Float(len)
            let wr = cos(ang), wi = sin(ang)
            var i = 0
            while i < n {
                var cwr: Float = 1, cwi: Float = 0
                for k in 0..<(len / 2) {
                    let a = i + k, b = i + k + len / 2
                    let tr = re[b] * cwr - im[b] * cwi
                    let ti = re[b] * cwi + im[b] * cwr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                    let nwr = cwr * wr - cwi * wi
                    cwi = cwr * wi + cwi * wr
                    cwr = nwr
                }
                i += len
            }
            len <<= 1
        }
    }

    /// Signed frequency (Hz) → FFT bin index.
    private static func bin(forHz hz: Double) -> Int {
        let raw = Int((hz / (basebandRate / Double(fftSize))).rounded())
        return (raw + fftSize) % fftSize
    }

    // MARK: - Candidate search

    private static func candidates(_ bank: SpectraBank) -> [Int] {
        // Average spectrum across the transmission, peak-pick within ±110 Hz
        let windows = bank.powers.count
        var avg = [Float](repeating: 0, count: fftSize)
        for w in stride(from: 0, to: windows, by: 8) {
            let p = bank.powers[w]
            for j in 0..<fftSize {
                avg[j] += p[j]
            }
        }
        let maxBinOffset = Int(110.0 / (basebandRate / Double(fftSize)))
        var scored: [(bin: Int, power: Float)] = []
        for off in -maxBinOffset...maxBinOffset {
            let b = (off + fftSize) % fftSize
            scored.append((b, avg[b]))
        }
        scored.sort { $0.power > $1.power }
        var picked: [Int] = []
        for (b, _) in scored {
            let signed = b > fftSize / 2 ? b - fftSize : b
            if picked.allSatisfy({ p in
                let ps = p > fftSize / 2 ? p - fftSize : p
                return abs(ps - signed) > 4
            }) {
                picked.append(b)
            }
            if picked.count >= 40 { break }
        }
        return picked
    }

    // MARK: - Sync alignment

    private struct Alignment {
        let startHop: Int
        let freqHz: Double     // signed baseband center of the 4-tone group
        let driftHz: Double    // total drift across the transmission
        let syncQuality: Float // sync-correlated power ratio
        let snrDB: Double
    }

    private static func align(_ bank: SpectraBank, centerBin: Int) -> Alignment? {
        let binHz = basebandRate / Double(fftSize)
        let center = Double(centerBin > fftSize / 2 ? centerBin - fftSize : centerBin) * binHz
        let hopsPerSymbol = symbolSamples / hop // 8
        let lastStart = bank.powers.count - 162 * hopsPerSymbol
        guard lastStart > 0 else { return nil }

        var best: Alignment?
        var bestScore: Float = 0
        // TX begins ~1 s into the slot; search 0…2.7 s in 85 ms steps
        for startHop in 0...min(32, lastStart) {
            for dfStep in -2...2 {
                let df = Double(dfStep) * binHz / 2.0
                for driftStep in -2...2 {
                    let drift = Double(driftStep) * 1.0
                    var syncPower: Float = 0
                    var unsyncPower: Float = 0
                    for k in 0..<162 {
                        let w = startHop + k * hopsPerSymbol
                        let progress = Double(k) / 161.0 - 0.5
                        let f = center + df + drift * progress
                        let p = bank.powers[w]
                        // Tone bins for symbol values 0…3
                        var tone = [Float](repeating: 0, count: 4)
                        for m in 0..<4 {
                            let hz = f + (Double(m) - 1.5) * WSPRCodec.toneSpacingHz
                            tone[m] = p[bin(forHz: hz)]
                        }
                        let sync1 = tone[1] + tone[3]
                        let sync0 = tone[0] + tone[2]
                        if WSPRCodec.syncVector[k] == 1 {
                            syncPower += sync1
                            unsyncPower += sync0
                        } else {
                            syncPower += sync0
                            unsyncPower += sync1
                        }
                    }
                    let score = syncPower / max(unsyncPower, 1e-9)
                    if score > bestScore {
                        bestScore = score
                        let signal = (syncPower + unsyncPower) / Float(162)
                        let snr = 10.0 * log10(Double(max(signal - 2 * bank.noiseFloor, 1e-12) / bank.noiseFloor))
                            - 10.0 * log10(2500.0 / binHz) // reference to 2500 Hz
                        best = Alignment(startHop: startHop, freqHz: center + df,
                                         driftHz: drift, syncQuality: score,
                                         snrDB: (snr * 10).rounded() / 10)
                    }
                }
            }
        }
        return best
    }

    // MARK: - Soft demod

    /// 162 soft data values (log tone-pair power ratio), interleaved order.
    private static func softBits(_ bank: SpectraBank, _ a: Alignment) -> [Float] {
        let hopsPerSymbol = symbolSamples / hop
        var soft = [Float](repeating: 0, count: 162)
        for k in 0..<162 {
            let w = a.startHop + k * hopsPerSymbol
            let progress = Double(k) / 161.0 - 0.5
            let f = a.freqHz + a.driftHz * progress
            let p = bank.powers[w]
            var tone = [Float](repeating: 0, count: 4)
            for m in 0..<4 {
                let hz = f + (Double(m) - 1.5) * WSPRCodec.toneSpacingHz
                tone[m] = p[bin(forHz: hz)]
            }
            // Data bit is the symbol's high bit: tones {2,3} vs {0,1}
            soft[k] = log((tone[2] + tone[3] + 1e-9) / (tone[0] + tone[1] + 1e-9))
        }
        return WSPRCodec.deinterleave(soft)
    }

    // MARK: - Verification

    private static func unpackAndVerify(bits: [UInt8], soft: [Float]) -> (call: String, grid: String, dBm: Int)? {
        guard bits.count >= 50 else { return nil }
        var n: UInt32 = 0
        for i in 0..<28 {
            n = (n << 1) | UInt32(bits[i])
        }
        var m: UInt32 = 0
        for i in 28..<50 {
            m = (m << 1) | UInt32(bits[i])
        }
        guard let call = WSPRCodec.unpackCallsign(n),
              let gp = WSPRCodec.unpackGridPower(m),
              call.count >= 3 else { return nil }
        // No CRC in WSPR: guard against sequential-decoder false positives
        // by re-encoding and demanding agreement with the received signs.
        let recoded = WSPRCodec.convolve(Array(bits[0..<50]))
        var agree = 0
        for k in 0..<162 where (soft[k] > 0) == (recoded[k] == 1) {
            agree += 1
        }
        guard agree >= 140 else { return nil } // ~86 %
        return (call, gp.grid, gp.dBm)
    }
}

/// Stack (Zigangirov–Jelinek) sequential decoder for the WSPR K=32
/// rate-1/2 zero-tail convolutional code. Textbook algorithm: maintain an
/// ordered stack of partial paths scored with the Fano metric; repeatedly
/// extend the best. The 31-bit zero tail constrains the final branches.
enum StackDecoder {
    private struct Path {
        var metric: Float
        var register: UInt32
        var depth: Int
        var bits: [UInt8]
    }

    static func decode(_ soft: [Float], maxIterations: Int = 60_000) -> [UInt8]? {
        // Per-bit log-likelihoods → probabilities of coded bit == 1
        let p1: [Float] = soft.map { 1 / (1 + exp(-max(-20, min(20, $0)))) }
        let bias: Float = 0.5 // Fano bias = code rate

        func branchMetric(depth: Int, out1: UInt8, out2: UInt8) -> Float {
            let i = depth * 2
            let a = out1 == 1 ? p1[i] : 1 - p1[i]
            let b = out2 == 1 ? p1[i + 1] : 1 - p1[i + 1]
            return log2(max(a, 1e-6)) + log2(max(b, 1e-6)) + 2 * (1 - bias)
        }

        var stack: [Path] = [Path(metric: 0, register: 0, depth: 0, bits: [])]
        stack.reserveCapacity(4096)

        for _ in 0..<maxIterations {
            guard let top = stack.popLast() else { return nil }
            if top.depth == 81 {
                return top.bits
            }
            // Tail: depths 50…80 are forced zero
            let choices: [UInt8] = top.depth < 50 ? [0, 1] : [0]
            for bit in choices {
                let reg = (top.register << 1) | UInt32(bit)
                let o1 = UInt8((reg & WSPRCodec.poly1).nonzeroBitCount & 1)
                let o2 = UInt8((reg & WSPRCodec.poly2).nonzeroBitCount & 1)
                var next = top
                next.register = reg
                next.depth += 1
                next.bits.append(bit)
                next.metric += branchMetric(depth: top.depth, out1: o1, out2: o2)
                // Ordered insert (stack sorted ascending; best at the end)
                var lo = 0, hi = stack.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if stack[mid].metric < next.metric {
                        lo = mid + 1
                    } else {
                        hi = mid
                    }
                }
                stack.insert(next, at: lo)
            }
            // Bound memory: drop the worst when oversized
            if stack.count > 8192 {
                stack.removeFirst(stack.count - 8192)
            }
        }
        return nil
    }
}
