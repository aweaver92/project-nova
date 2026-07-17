import Foundation
import NovaCore

/// Streams mono PCM16 into a canonical 44-byte-header WAV file.
///
/// Pure Foundation (no AVFoundation) so it is portable and unit-testable on any
/// platform. The header is written up front with placeholder sizes and patched
/// on `finalize()` once the payload length is known, which lets us append audio
/// incrementally without buffering the whole recording in memory.
final class WAVWriter {
    let url: URL
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    private(set) var bytesWritten: Int = 0

    private let handle: FileHandle
    private var finalized = false

    private static let headerSize = 44

    init(url: URL, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NovaError.audioSession("Could not create recording file at \(url.lastPathComponent)")
        }
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            dataBytes: 0
        ))
    }

    func append(_ pcm: Data) throws {
        guard !finalized, !pcm.isEmpty else { return }
        try handle.write(contentsOf: pcm)
        bytesWritten += pcm.count
    }

    /// Patches the RIFF + data chunk sizes and closes the file. Idempotent.
    func finalize() {
        guard !finalized else { return }
        finalized = true
        let riffSize = UInt32(Self.headerSize - 8 + bytesWritten)
        let dataSize = UInt32(bytesWritten)
        do {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Self.le32(riffSize))
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: Self.le32(dataSize))
            try handle.close()
        } catch {
            NovaLog.audio.error("WAV finalize failed: \(String(describing: error), privacy: .public)")
            try? handle.close()
        }
    }

    // MARK: - Header

    private static func header(sampleRate: Int, channels: Int, bitsPerSample: Int, dataBytes: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var data = Data(capacity: headerSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(le32(UInt32(headerSize - 8 + dataBytes)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(le32(16))                       // PCM fmt chunk size
        data.append(le16(1))                         // audio format = PCM
        data.append(le16(UInt16(channels)))
        data.append(le32(UInt32(sampleRate)))
        data.append(le32(UInt32(byteRate)))
        data.append(le16(UInt16(blockAlign)))
        data.append(le16(UInt16(bitsPerSample)))
        data.append(contentsOf: Array("data".utf8))
        data.append(le32(UInt32(dataBytes)))
        return data
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
