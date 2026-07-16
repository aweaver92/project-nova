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
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            if let hfp = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try session.setPreferredInput(hfp)
                NovaLog.audio.info("HFP preferred input: \(hfp.portName, privacy: .public)")
            } else {
                NovaLog.audio.warning("No bluetoothHFP input yet; continuing with current route")
            }
            try session.setPreferredSampleRate(8_000)
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

/// Linear PCM16 resampler (mono). Adequate for MVP; replace with vDSP/AVAudioConverter on device if needed.
public struct PCMResampler: AudioResampling, Sendable {
    public init() {}

    public func resample(_ pcm16: Data, from: Int, to: Int) -> Data {
        guard from != to, from > 0, to > 0, !pcm16.isEmpty else { return pcm16 }
        let inputCount = pcm16.count / 2
        guard inputCount > 1 else { return pcm16 }

        var input = [Int16](repeating: 0, count: inputCount)
        _ = input.withUnsafeMutableBytes { dest in
            pcm16.copyBytes(to: dest)
        }

        let outputCount = max(1, Int(Double(inputCount) * Double(to) / Double(from)))
        var output = [Int16](repeating: 0, count: outputCount)
        let ratio = Double(inputCount - 1) / Double(max(outputCount - 1, 1))

        for i in 0..<outputCount {
            let src = Double(i) * ratio
            let i0 = Int(src)
            let i1 = min(i0 + 1, inputCount - 1)
            let frac = src - Double(i0)
            let s0 = Double(input[i0])
            let s1 = Double(input[i1])
            output[i] = Int16((s0 + (s1 - s0) * frac).rounded())
        }

        return output.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
