import AVFoundation
import Foundation
import NovaCore
import NovaDomain

#if os(iOS)
public final class AudioSessionCoordinator: AudioSessionCoordinating, @unchecked Sendable {
    public init() {}

    public func activateConversationalHFP() async throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.voiceChat` routes capture/playback through the system voice-processing
            // path (echo cancellation, noise suppression, automatic gain control),
            // which materially improves intelligibility on the narrowband HFP link.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(hfp)
                NovaLog.audio.info("HFP preferred input: \(hfp.portName, privacy: .public)")
            } else {
                NovaLog.audio.warning("No bluetoothHFP input yet; continuing with current route")
            }
            // Prefer wideband HFP (mSBC, 16 kHz) over narrowband (CVSD, 8 kHz).
            // Modern Bluetooth headsets — including the Meta glasses — negotiate
            // wideband when asked, which is audibly clearer for the Nova voice.
            // The system falls back to 8 kHz if wideband isn't available.
            try session.setPreferredSampleRate(16_000)
            // Match the ~20 ms conversational cadence: small enough to keep latency
            // low, large enough to avoid render underruns / choppy playback.
            try? session.setPreferredIOBufferDuration(0.02)
        } catch {
            throw NovaError.audioSession(String(describing: error))
        }
    }

    public func deactivate() async {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#else
public final class AudioSessionCoordinator: AudioSessionCoordinating, @unchecked Sendable {
    public init() {}
    public func activateConversationalHFP() async throws {}
    public func deactivate() async {}
}
#endif

/// Anti-aliased streaming PCM16 resampler (mono).
///
/// The previous MVP used bare linear interpolation, which aliases high frequencies
/// into the passband on downsampling (24 kHz → 8 kHz) and leaves spectral images on
/// upsampling (8 kHz → 24 kHz) — both audible as harshness/buzz on speech.
///
/// This version pairs the linear rate conversion with a windowed-sinc (Hamming)
/// low-pass filter applied on the high-rate side of each conversion: as an
/// anti-alias filter *before* decimation, and as an anti-image filter *after*
/// interpolation. The FIR is causal and carries per-direction history across calls
/// (overlap style), so streaming chunk boundaries stay click-free. Output length is
/// unchanged from the linear implementation, preserving the resampling contract.
public final class PCMResampler: AudioResampling, @unchecked Sendable {
    private let lock = NSLock()
    /// Filter history (last `taps-1` samples on the high-rate side) keyed by
    /// conversion direction, so a single instance can serve both the mic-up and
    /// speaker-down paths without cross-contaminating filter state.
    private var histories: [Int: [Float]] = [:]
    private var filters: [Int: [Float]] = [:]

    /// FIR length. 31 taps gives a usable transition band for the 3:1 ratios in
    /// use while keeping per-chunk cost trivial (group delay ≈ 15 samples ≈ 0.6 ms
    /// at 24 kHz).
    private static let taps = 31

    public init() {}

    public func resample(_ pcm16: Data, from: Int, to: Int) -> Data {
        guard from != to, from > 0, to > 0, !pcm16.isEmpty else { return pcm16 }
        let inputCount = pcm16.count / 2
        guard inputCount > 1 else { return pcm16 }

        var input = [Int16](repeating: 0, count: inputCount)
        _ = input.withUnsafeMutableBytes { dest in
            pcm16.copyBytes(to: dest)
        }
        var x = [Float](repeating: 0, count: inputCount)
        for i in 0..<inputCount { x[i] = Float(input[i]) }

        let outputCount = max(1, Int(Double(inputCount) * Double(to) / Double(from)))
        let key = from * 1_000_000 + to

        lock.lock()
        let coeffs = filter(from: from, to: to, key: key)
        let result: [Float]
        if to < from {
            // Downsample: band-limit at the source rate, then interpolate down.
            let filtered = applyFIR(x, key: key, taps: coeffs)
            result = linearInterpolate(filtered, outputCount: outputCount)
        } else {
            // Upsample: interpolate up, then strip the imaging above the source band.
            let interpolated = linearInterpolate(x, outputCount: outputCount)
            result = applyFIR(interpolated, key: key, taps: coeffs)
        }
        lock.unlock()

        var output = [Int16](repeating: 0, count: outputCount)
        let lo = Float(Int16.min), hi = Float(Int16.max)
        for i in 0..<outputCount {
            output[i] = Int16(min(hi, max(lo, result[i].rounded())))
        }
        return output.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Chunk-local linear interpolation over `[0, inputCount-1]` → `outputCount`.
    private func linearInterpolate(_ s: [Float], outputCount: Int) -> [Float] {
        let inputCount = s.count
        if inputCount == outputCount { return s }
        var output = [Float](repeating: 0, count: outputCount)
        let ratio = Double(inputCount - 1) / Double(max(outputCount - 1, 1))
        for i in 0..<outputCount {
            let src = Double(i) * ratio
            let i0 = Int(src)
            let i1 = min(i0 + 1, inputCount - 1)
            let frac = Float(src - Double(i0))
            output[i] = s[i0] + (s[i1] - s[i0]) * frac
        }
        return output
    }

    /// Causal FIR convolution with per-direction history warm-up. Caller holds `lock`.
    private func applyFIR(_ x: [Float], key: Int, taps h: [Float]) -> [Float] {
        let n = x.count
        let m = h.count
        var hist = histories[key] ?? [Float](repeating: 0, count: m - 1)
        if hist.count != m - 1 { hist = [Float](repeating: 0, count: m - 1) }

        var ext = hist
        ext.append(contentsOf: x)
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var acc: Float = 0
            let base = i + (m - 1)
            for k in 0..<m { acc += h[k] * ext[base - k] }
            y[i] = acc
        }
        histories[key] = Array(x.suffix(m - 1))
        return y
    }

    /// Windowed-sinc low-pass (Hamming), normalized to unity DC gain, cached per
    /// direction. Cutoff sits just below the lower of the two Nyquist limits.
    private func filter(from: Int, to: Int, key: Int) -> [Float] {
        if let cached = filters[key] { return cached }
        let m = Self.taps
        let highRate = Double(max(from, to))
        // 0.45 * min(rate) leaves a small transition margin below Nyquist.
        let cutoff = 0.45 * Double(min(from, to))
        let fc = cutoff / highRate
        let center = Double(m - 1) / 2.0
        var h = [Float](repeating: 0, count: m)
        var sum: Double = 0
        for i in 0..<m {
            let x = Double(i) - center
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let window = 0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(m - 1))
            let v = sinc * window
            h[i] = Float(v)
            sum += v
        }
        if sum != 0 { for i in 0..<m { h[i] /= Float(sum) } }
        filters[key] = h
        return h
    }
}
