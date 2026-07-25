import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Soft keep-alive so Coding can poll the PC bridge while the screen is off.
/// Uses silent looping playback under `UIBackgroundModes: audio` with
/// `mixWithOthers` so it does not steal the glasses / Listen route when possible.
@MainActor
public final class BackgroundNetworkKeepAlive {
    public static let shared = BackgroundNetworkKeepAlive()

    private var retainCount = 0
    #if canImport(AVFoundation)
    private var player: AVAudioPlayer?
    #endif

    private init() {}

    public func start(reason: String) {
        retainCount += 1
        guard retainCount == 1 else { return }
        #if canImport(AVFoundation)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            let player = try AVAudioPlayer(data: Self.silentWavData())
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            guard player.play() else {
                NovaLog.session.error("Coding keep-alive failed to start silent player (\(reason, privacy: .public))")
                retainCount = max(0, retainCount - 1)
                return
            }
            self.player = player
            NovaLog.session.info("Coding keep-alive started (\(reason, privacy: .public))")
        } catch {
            NovaLog.session.error(
                "Coding keep-alive audio session failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            retainCount = max(0, retainCount - 1)
        }
        #endif
    }

    public func stop(reason: String) {
        guard retainCount > 0 else { return }
        retainCount -= 1
        guard retainCount == 0 else { return }
        #if canImport(AVFoundation)
        player?.stop()
        player = nil
        NovaLog.session.info("Coding keep-alive stopped (\(reason, privacy: .public))")
        #endif
    }

    /// Tiny mono 8 kHz PCM WAV (~0.25s of near-silence).
    private static func silentWavData() -> Data {
        let sampleRate = 8000
        let sampleCount = sampleRate / 4
        var data = Data()
        func appendUInt32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + sampleCount * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(1) // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(sampleCount * 2))
        data.append(contentsOf: [UInt8](repeating: 0, count: sampleCount * 2))
        return data
    }
}
