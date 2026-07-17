import Foundation
import NovaCore
import NovaDomain

/// Start recording video from the glasses camera. Backs the spoken command
/// "Nova, start recording video" by exposing video capture as a model tool.
public struct StartVideoRecordingTool: Tool {
    public let name = "start_video_recording"
    public let description = "Start recording video from the glasses camera and save it to the phone. Use when the user says things like 'record a video', 'start video recording', or 'film this'."
    public let requiresConfirmation = false
    private let recorder: any VideoRecorder
    public init(recorder: any VideoRecorder) { self.recorder = recorder }

    public func invoke(argumentsJSON: String) async throws -> String {
        if await recorder.isRecording() {
            return #"{"ok":true,"already_recording":true}"#
        }
        try await recorder.start()
        return #"{"ok":true,"recording":true}"#
    }
}

/// Stop the current glasses video recording and persist it to the phone.
public struct StopVideoRecordingTool: Tool {
    public let name = "stop_video_recording"
    public let description = "Stop the current glasses video recording and save it to the phone. Use when the user says 'stop the video' or 'end video recording'."
    public let requiresConfirmation = false
    private let recorder: any VideoRecorder
    public init(recorder: any VideoRecorder) { self.recorder = recorder }

    public func invoke(argumentsJSON: String) async throws -> String {
        guard await recorder.isRecording() else {
            return #"{"ok":false,"error":"not_recording"}"#
        }
        guard let recording = await recorder.stop() else {
            return #"{"ok":true,"saved":false}"#
        }
        return """
        {"ok":true,"saved":true,"seconds":\(Int(recording.duration.rounded())),"frames":\(recording.frameCount),"file":"\(recording.fileName)"}
        """
    }
}

/// List saved glasses video recordings so the model can tell the user what's stored.
public struct ListVideoRecordingsTool: Tool {
    public let name = "list_video_recordings"
    public let description = "List the user's saved glasses video recordings (name, date, and length)."
    public let requiresConfirmation = false
    private let store: any VideoRecordingStoring
    public init(store: any VideoRecordingStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let recordings = await store.all().sorted { $0.createdAt > $1.createdAt }
        let items = recordings.map { rec -> [String: Any] in
            [
                "file": rec.fileName,
                "at": ISO8601.string(from: rec.createdAt),
                "seconds": Int(rec.duration.rounded())
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": items.count, "videos": items])
        return String(decoding: data, as: UTF8.self)
    }
}
