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

    /// Wall-clock cap on one slot's decode. Real signals decode in ~2 s
    /// total; the failure mode this guards is dead-band noise, where dozens
    /// of candidates squeak past the sync gate and each burns a full stack
    /// budget — pushing a slot past its own 2-minute period and starting a
    /// backlog the serial decode queue never recovers from.
    static let decodeBudgetSeconds: TimeInterval = 60

    static func decode(_ samples: [Float], deadline: Date? = nil) -> [Result] {
        decodeDetailed(samples, deadline: deadline).results
    }

    /// Also reports the strongest sync-vector correlation seen: real WSPR
    /// structure scores ≥ 2 even below the decode floor, noise stays near 1.
    /// "Strong sync, no decodes, slot after slot" means the audio is being
    /// mangled upstream (radio noise reduction, notch, EQ).
    static func decodeDetailed(_ samples: [Float], deadline: Date? = nil)
        -> (results: [Result], strongestSync: Float) {
        let deadline = deadline ?? Date().addingTimeInterval(decodeBudgetSeconds)
        guard samples.count > Int(inRate) * 60 else { return ([], 0) }
        let baseband = downconvert(samples)
        let bank = spectraBank(baseband)
        guard !bank.powers.isEmpty else { return ([], 0) }

        // Align everything first (bounded cost), then spend the stack-decode
        // budget on the most promising candidates
        let alignedCandidates = candidateCenters(bank)
            .compactMap { align(bank, centerHz: $0) }
            .filter { $0.syncQuality > 1.10 } // sync gate
            .sorted { $0.syncQuality > $1.syncQuality }
        let strongestSync = alignedCandidates.first?.syncQuality ?? 0

        var prepared: [(alignment: Alignment, soft: [Float], decoded: Bool)] = []
        var results: [Result] = []
        var claimed = Set<String>()
        // The deadline sheds load from the BOTTOM of the sync-sorted list;
        // the best candidate is always seen through, or a slow machine
        // (or debug build) would decode nothing at all.
        func attempt(_ index: Int, iterations: Int) {
            guard index == 0 || Date() < deadline else { return }
            let item = prepared[index]
            guard let bits = StackDecoder.decode(item.soft, maxIterations: iterations) else { return }
            prepared[index].decoded = true // don't re-grind it in pass 2, even if unverified
            guard let msg = unpackAndVerify(bits: bits, soft: item.soft) else { return }
            let key = "\(msg.call) \(msg.grid) \(msg.dBm)"
            guard !claimed.contains(key) else { return }
            claimed.insert(key)
            results.append(Result(
                call: msg.call, grid: msg.grid, dBm: msg.dBm,
                audioFrequencyHz: mixHz + item.alignment.freqHz,
                dtSeconds: Double(item.alignment.startHop * hop) / basebandRate - 1.0,
                snrDB: item.alignment.snrDB
            ))
        }
        // Pass 1: refine + a quick budget, one candidate at a time, so the
        // deadline can't burn on preparation before anything is attempted.
        // Strong signals decode here in a few thousand iterations.
        for (i, aligned) in alignedCandidates.enumerated() {
            guard i == 0 || Date() < deadline else { break }
            let refined = refine(bank, baseband, around: aligned)
            prepared.append((refined, softBits(baseband, refined), false))
            attempt(i, iterations: 30_000)
        }
        // Sync ≥ 1.5 separates real-but-weak signals (≥ 2.0 even at −24 dB)
        // from noise that squeaked past the gate — the deep budget would
        // only grind on the latter.
        for i in prepared.indices where !prepared[i].decoded && prepared[i].alignment.syncQuality >= 1.5 {
            attempt(i, iterations: 300_000)
        }
        return (results, strongestSync)
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

    /// Candidate CENTER frequencies of the 4-tone group. A lone spectral
    /// peak can be any one of the four tones — up to ±2.2 Hz off center,
    /// beyond the alignment search — so score whole quartets instead:
    /// sum the time-averaged power at all four tone positions for every
    /// possible center on a half-bin grid.
    private static func candidateCenters(_ bank: SpectraBank) -> [Double] {
        let windows = bank.powers.count
        var avg = [Float](repeating: 0, count: fftSize)
        for w in 0..<windows {
            let p = bank.powers[w]
            for j in 0..<fftSize {
                avg[j] += p[j]
            }
        }
        let binHz = basebandRate / Double(fftSize)
        let step = binHz / 2.0
        let reach = 110.0 - 1.5 * WSPRCodec.toneSpacingHz // keep all tones in band
        var scored: [(hz: Double, power: Float)] = []
        var hz = -reach
        while hz <= reach {
            var quartet: Float = 0
            for m in 0..<4 {
                quartet += avg[bin(forHz: hz + (Double(m) - 1.5) * WSPRCodec.toneSpacingHz)]
            }
            scored.append((hz, quartet))
            hz += step
        }
        scored.sort { $0.power > $1.power }
        var picked: [Double] = []
        for (hz, _) in scored {
            // 1.5 Hz separation also suppresses the same signal's secondary
            // score peaks one tone-spacing off center
            if picked.allSatisfy({ abs($0 - hz) > 1.5 }) {
                picked.append(hz)
            }
            if picked.count >= 30 { break }
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

    /// Sync-vector score of one (start, frequency, drift) hypothesis.
    private static func syncScore(_ bank: SpectraBank, startHop: Int, freqHz: Double,
                                  driftHz: Double) -> (score: Float, signal: Float) {
        let hopsPerSymbol = symbolSamples / hop // 8
        var syncPower: Float = 0
        var unsyncPower: Float = 0
        for k in 0..<162 {
            let w = startHop + k * hopsPerSymbol
            let progress = Double(k) / 161.0 - 0.5
            let f = freqHz + driftHz * progress
            let p = bank.powers[w]
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
        return (syncPower / max(unsyncPower, 1e-9), (syncPower + unsyncPower) / Float(162))
    }

    private static func snrEstimate(_ bank: SpectraBank, signal: Float) -> Double {
        let binHz = basebandRate / Double(fftSize)
        let snr = 10.0 * log10(Double(max(signal - 2 * bank.noiseFloor, 1e-12) / bank.noiseFloor))
            - 10.0 * log10(2500.0 / binHz) // reference to 2500 Hz
        return (snr * 10).rounded() / 10
    }

    private static func align(_ bank: SpectraBank, centerHz: Double) -> Alignment? {
        let binHz = basebandRate / Double(fftSize)
        let hopsPerSymbol = symbolSamples / hop // 8
        let lastStart = bank.powers.count - 162 * hopsPerSymbol
        guard lastStart > 0 else { return nil }

        var best: Alignment?
        var bestScore: Float = 0
        // TX begins ~1 s into the slot; search 0…2.7 s in 85 ms steps.
        // The quartet-scored center is good to ±half a search step, so the
        // frequency search stays narrow; drift gets the wide sweep instead.
        for startHop in 0...min(32, lastStart) {
            for dfStep in -1...1 {
                let df = Double(dfStep) * binHz / 2.0
                for driftStep in -4...4 {
                    let drift = Double(driftStep) * 1.0
                    let (score, signal) = syncScore(bank, startHop: startHop,
                                                    freqHz: centerHz + df, driftHz: drift)
                    if score > bestScore {
                        bestScore = score
                        best = Alignment(startHop: startHop, freqHz: centerHz + df,
                                         driftHz: drift, syncQuality: score,
                                         snrDB: snrEstimate(bank, signal: signal))
                    }
                }
            }
        }
        return best
    }

    /// Sync score from exact-frequency tone powers. The FFT-bank score
    /// quantizes each tone to a bin, which systematically biases the drift
    /// estimate (a false +1 Hz can out-score the truth); the exact version
    /// has no such artifact, so refine uses it despite the extra cost.
    private static func exactSyncScore(_ bb: Baseband, startHop: Int, freqHz: Double,
                                       driftHz: Double) -> (score: Float, signal: Float) {
        var syncPower: Float = 0
        var unsyncPower: Float = 0
        let startSample = startHop * hop
        for k in 0..<162 {
            let s0 = startSample + k * symbolSamples
            guard s0 + symbolSamples <= bb.i.count else { break }
            let progress = Double(k) / 161.0 - 0.5
            let f = freqHz + driftHz * progress
            var tone = [Float](repeating: 0, count: 4)
            for m in 0..<4 {
                tone[m] = tonePower(bb, start: s0, hz: f + (Double(m) - 1.5) * WSPRCodec.toneSpacingHz)
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
        return (syncPower / max(unsyncPower, 1e-9), (syncPower + unsyncPower) / Float(162))
    }

    /// Local fine search around a coarse alignment: frequency to 0.09 Hz,
    /// drift to 0.25 Hz, start ±1 hop, scored exactly. Runs only on gate
    /// survivors, so the cost lands where it pays.
    private static func refine(_ bank: SpectraBank, _ bb: Baseband, around coarse: Alignment) -> Alignment {
        let hopsPerSymbol = symbolSamples / hop
        let lastStart = bank.powers.count - 162 * hopsPerSymbol
        var best = coarse
        var bestScore: Float = 0 // re-score the coarse point exactly too
        for dHop in -1...1 {
            let startHop = coarse.startHop + dHop
            guard startHop >= 0, startHop <= lastStart else { continue }
            for dfStep in -3...3 {
                let f = coarse.freqHz + Double(dfStep) * 0.0915 // binHz/8
                // ±1 Hz reach: the coarse estimate's bin quantization can
                // park a full step away from the true drift
                for driftStep in -4...4 {
                    let drift = coarse.driftHz + Double(driftStep) * 0.25
                    let (score, signal) = exactSyncScore(bb, startHop: startHop,
                                                         freqHz: f, driftHz: drift)
                    if score > bestScore {
                        bestScore = score
                        best = Alignment(startHop: startHop, freqHz: f, driftHz: drift,
                                         syncQuality: score,
                                         snrDB: snrEstimate(bank, signal: signal))
                    }
                }
            }
        }
        return best
    }

    // MARK: - Soft demod

    /// 162 soft data values (log tone-pair power ratio), interleaved order.
    /// Tone powers come from exact-frequency correlation over each symbol's
    /// own 256 samples — no FFT bin quantization, no scalloping loss, and
    /// the drift model is applied per symbol.
    private static func softBits(_ bb: Baseband, _ a: Alignment) -> [Float] {
        var soft = [Float](repeating: 0, count: 162)
        let startSample = a.startHop * hop
        for k in 0..<162 {
            let s0 = startSample + k * symbolSamples
            guard s0 + symbolSamples <= bb.i.count else { break }
            let progress = Double(k) / 161.0 - 0.5
            let f = a.freqHz + a.driftHz * progress
            // The sync bit is known per symbol (tone = 2·data + sync), so
            // the data decision is 1-of-2 tones, not 2-of-4 — comparing
            // pair sums would add a pure-noise bin to each side (~2 dB).
            let sync = Double(WSPRCodec.syncVector[k])
            let low = tonePower(bb, start: s0, hz: f + (sync - 1.5) * WSPRCodec.toneSpacingHz)
            let high = tonePower(bb, start: s0, hz: f + (sync + 0.5) * WSPRCodec.toneSpacingHz)
            soft[k] = log((high + 1e-9) / (low + 1e-9))
        }
        return WSPRCodec.deinterleave(soft)
    }

    /// |Σ x[t]·e^{−j2πf·t/rate}|² over one symbol.
    private static func tonePower(_ bb: Baseband, start: Int, hz: Double) -> Float {
        let w = 2.0 * Double.pi * hz / basebandRate
        let cosW = Float(cos(w)), sinW = Float(sin(w))
        var cr: Float = 1, ci: Float = 0 // e^{−jwt} via rotation recurrence
        var accR: Float = 0, accI: Float = 0
        for t in 0..<symbolSamples {
            let xr = bb.i[start + t]
            let xi = bb.q[start + t]
            accR += xr * cr - xi * ci
            accI += xr * ci + xi * cr
            let nr = cr * cosW + ci * sinW
            ci = ci * cosW - cr * sinW
            cr = nr
        }
        return accR * accR + accI * accI
    }

    // MARK: - Diagnostics (tests only)

    /// Stage-by-stage trace for sensitivity work: where does a known
    /// signal fall out of the pipeline?
    static func diagnose(_ samples: [Float], expectedAudioHz: Double,
                         call: String, grid: String, dBm: Int) -> [String] {
        var out: [String] = []
        guard samples.count > Int(inRate) * 60 else { return ["too few samples"] }
        let baseband = downconvert(samples)
        let bank = spectraBank(baseband)
        let expected = expectedAudioHz - mixHz
        let centers = candidateCenters(bank)
        guard let (rank, center) = centers.enumerated()
            .min(by: { abs($0.1 - expected) < abs($1.1 - expected) }) else { return ["no candidates"] }
        out.append(String(format: "candidate: rank %d of %d, center %+.2f Hz (expected %+.2f)",
                          rank, centers.count, center, expected))
        guard let coarse = align(bank, centerHz: center) else { return out + ["align nil"] }
        out.append(String(format: "coarse:  start %2d  f %+7.2f  drift %+.2f  sync %.3f  snr %+.1f",
                          coarse.startHop, coarse.freqHz, coarse.driftHz, coarse.syncQuality, coarse.snrDB))
        let refined = refine(bank, baseband, around: coarse)
        out.append(String(format: "refined: start %2d  f %+7.2f  drift %+.2f  sync %.3f  snr %+.1f",
                          refined.startHop, refined.freqHz, refined.driftHz, refined.syncQuality, refined.snrDB))
        let soft = softBits(baseband, refined)
        if let msg = WSPRCodec.messageBits(call: call, grid: grid, dBm: dBm) {
            let coded = WSPRCodec.convolve(msg)
            var agree = 0
            for k in 0..<162 where (soft[k] > 0) == (coded[k] == 1) {
                agree += 1
            }
            out.append("raw soft-bit agreement: \(agree)/162")
        }
        if let bits = StackDecoder.decode(soft, maxIterations: 2_000_000) {
            let verified = unpackAndVerify(bits: bits, soft: soft) != nil
            var n: UInt32 = 0
            for i in 0..<28 {
                n = (n << 1) | UInt32(bits[i])
            }
            let decodedCall = WSPRCodec.unpackCallsign(n) ?? "?"
            out.append("stack(2M): decoded \(decodedCall), verify \(verified ? "OK" : "REJECTED")")
        } else {
            out.append("stack(2M): FAILED")
        }
        return out
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

    static func decode(_ soft: [Float], maxIterations: Int = 200_000) -> [UInt8]? {
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
            if stack.count > 16384 {
                stack.removeFirst(stack.count - 16384)
            }
        }
        return nil
    }
}
