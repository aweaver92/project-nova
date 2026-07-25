import Foundation
import NovaCore
import NovaDomain

/// Start capturing a meeting/conversation. Reuses the voice recorder (fed by the
/// mic tee), so the audio is saved to the phone just like a voice memo — but the
/// intent is a longer capture that `end_meeting` will transcribe + summarize.
public struct StartMeetingTool: Tool {
    public let name = "start_meeting"
    public let description = "Begin capturing a meeting or conversation through the glasses mic. Use when the user says 'start a meeting', 'take notes on this meeting', or 'record this conversation'. Follow up later with end_meeting to get a summary and action items."
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

/// Stop the meeting capture, transcribe it, summarize it into key points +
/// action items, and save the summary as a note. Returns the summary so Nova can
/// read it back.
public struct EndMeetingTool: Tool {
    public let name = "end_meeting"
    public let description = "Stop the current meeting capture, transcribe it, and save a summary with key points and action items to the user's notes. Use when the user says 'end the meeting', 'wrap up', or 'summarize the meeting'."
    public let requiresConfirmation = false

    private let recorder: any VoiceRecorder
    private let store: any RecordingStoring
    private let transcriber: any AudioTranscribing
    private let summarizer: MeetingSummarizer
    private let notes: any NoteStoring
    private let cloudEnabled: @Sendable () async -> Bool

    public init(
        recorder: any VoiceRecorder,
        store: any RecordingStoring,
        transcriber: any AudioTranscribing,
        summarizer: MeetingSummarizer,
        notes: any NoteStoring,
        cloudEnabled: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.recorder = recorder
        self.store = store
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.notes = notes
        self.cloudEnabled = cloudEnabled
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        guard await cloudEnabled() else {
            return #"{"ok":false,"error":"meeting_cloud_processing_disabled"}"#
        }
        guard await recorder.isRecording() else {
            return #"{"ok":false,"error":"not_recording"}"#
        }
        guard let recording = await recorder.stop() else {
            return #"{"ok":true,"saved":false,"error":"no_audio"}"#
        }
        let fileURL = await store.directory().appendingPathComponent(recording.fileName)

        let transcript: String
        do {
            transcript = try await transcriber.transcribe(fileURL: fileURL)
        } catch {
            return "{\"ok\":false,\"error\":\"transcription_failed\",\"detail\":\"\(Self.escape(String(describing: error)))\"}"
        }
        guard !transcript.isEmpty else {
            return #"{"ok":true,"saved":false,"error":"empty_transcript"}"#
        }

        let summary = await summarizer.summarize(transcript: transcript)
        let stamp = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
        let note = "Meeting summary — \(stamp)\n\n\(summary)"
        await notes.save(note)

        let payload: [String: Any] = [
            "ok": true,
            "saved": true,
            "seconds": Int(recording.duration.rounded()),
            "summary": summary
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
