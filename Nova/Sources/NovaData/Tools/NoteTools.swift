import Foundation
import NovaCore
import NovaDomain

/// Save a spoken note.
public struct SaveNoteTool: Tool {
    public let name = "save_note"
    public let description = "Save a note to the user's Nova notes for later."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"text":{"type":"string","description":"The note contents"}},"required":["text"],"additionalProperties":false}
    """
    private let store: any NoteStoring
    public init(store: any NoteStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let text: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let note = await store.save(args.text)
        return #"{"ok":true,"id":"\#(note.id.uuidString)"}"#
    }
}

/// Read back saved notes.
public struct ListNotesTool: Tool {
    public let name = "list_notes"
    public let description = "List the user's saved Nova notes."
    public let requiresConfirmation = false
    private let store: any NoteStoring
    public init(store: any NoteStoring) { self.store = store }

    public func invoke(argumentsJSON: String) async throws -> String {
        let notes = await store.all()
        let items = notes.map { ["text": $0.text, "at": ISO8601.string(from: $0.at)] }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "count": items.count, "notes": items])
        return String(decoding: data, as: UTF8.self)
    }
}
