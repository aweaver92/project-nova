import Foundation
import NovaCore
import NovaDomain

/// Capture what the user is looking at through the glasses, read any text on it
/// with on-device OCR, and save it to Nova's searchable visual memory. This is
/// the "remember this" life-log primitive — later the user can ask things like
/// "what was that wine I saw?" and `search_knowledge` will surface it.
///
/// The camera is released immediately after the single still so the hardware
/// capture indicator is lit for the shortest possible time.
public struct RememberVisualTool: Tool {
    public let name = "remember_visual"
    public let description = "Capture what the user is looking at through the glasses camera, read any text on it, and save it to visual memory so it can be searched later. Use for 'remember this', 'save what I'm looking at', 'log this', 'note where I parked'."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"label":{"type":"string","description":"Optional short label for what this is, e.g. 'my parking spot' or 'the wine bottle'."}},"additionalProperties":false}
    """

    private let frameCapture: any FrameCapture
    private let ocr: any TextRecognizing
    private let store: any VisualMemoryStoring
    private let workspaceId: @Sendable () async -> UUID?

    public init(
        frameCapture: any FrameCapture,
        ocr: any TextRecognizing,
        store: any VisualMemoryStoring,
        workspaceId: @escaping @Sendable () async -> UUID?
    ) {
        self.frameCapture = frameCapture
        self.ocr = ocr
        self.store = store
        self.workspaceId = workspaceId
    }

    private struct Args: Decodable { var label: String? }

    public func invoke(argumentsJSON: String) async throws -> String {
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(label: nil)
        let label = args.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let frame = try await frameCapture.captureStill()
        // Frame is in hand; release the camera right away (privacy: LED off ASAP).
        await frameCapture.releaseCamera()

        let text = await ocr.recognizeText(in: frame.imageData)
        let item = await store.save(imageData: frame.imageData, text: text, caption: label, workspaceId: await workspaceId())

        let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(160)
        let payload: [String: Any] = [
            "ok": true,
            "saved": true,
            "id": item.id.uuidString,
            "has_text": !text.isEmpty,
            "text_preview": String(preview)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }
}
