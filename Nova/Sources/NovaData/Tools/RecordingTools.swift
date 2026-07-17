import Foundation
import NovaCore
import NovaDomain

/// Start a voice recording. Backs the spoken command "Nova, begin voice
/// recording" (and variants) by exposing recording as a model tool.
public struct StartVoiceRecordingTool: Tool {
    public let name = "start_voice_recording"
    public let description = "Start recording audio from the microphone and save it to the phone. Use when the user says things like 'begin voice recording', 'start recording', or 'record this'."
    public let requiresConfirmation = false
    private let recorder: any VoiceRecorder
    public init(recorder: any VoiceRecorder) { self.recorder = recorder }

    public func invoke(argumentsJSON: String) async throws -> String {
        if await recorder.isRecording() {
            return #"{"ok":true,"already_recording":true}"#
        }
        try await recorder.start()
        return #"{"ok":true,"recording":true}"#
    }
}

/// Stop the current voice recording and persist it to the phone.
public struct StopVoiceRecordingTool: Tool {
    public let name = "stop_voice_recording"
    public let description = "Stop the current voice recording and save it to the phone. Use when the user says 'stop recording' or 'end voice recording'."
    public let requiresConfirmation = false
    private let recorder: any VoiceRecorder
    public init(recorder: any VoiceRecorder) { self.recorder = recorder }

    public func invoke(argumentsJSON: String) async throws -> String {
        guard await recorder.isRecording() else {
            return #"{"ok":false,"error":"not_recording"}"#
        }
        guard let recording = await recorder.stop() else {
            return #"{"ok":true,"saved":false}"#
        }
        return """
        {"ok":true,"saved":true,"seconds":\(Int(recording.duration.rounded())),"file":"\(recording.fileName)"}
        """
    }
}

/// List saved voice recordings so the model can tell the user what's stored.
public struct ListRecordingsTool: Tool {
    public let name = "list_recordings"
    public let description = "List the user's saved voice recordings (name, date, and length)."
    public let requiresConfirmation = false
    private let store: any RecordingStoring
    public init(store: any RecordingStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let recordings = await store.all().sorted { $0.createdAt > $1.createdAt }
        let items = recordings.map { rec -> [String: Any] in
            [
                "file": rec.fileName,
                "at": ISO8601.string(from: rec.createdAt),
                "seconds": Int(rec.duration.rounded())
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": items.count, "recordings": items])
        return String(decoding: data, as: UTF8.self)
    }
}
