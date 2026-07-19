import Foundation
import NovaDomain

/// "Nova, find my phone" — rings THIS device with repeated alerts (sound,
/// vibration, screen wake) so the user can locate a misplaced phone, even from
/// another room while wearing the glasses.
public struct FindMyPhoneTool: Tool {
    public let name = "find_my_phone"
    public let description = "Ring this phone with repeated loud alerts (sound, vibration, screen wake) so the user can locate a misplaced device, even from another room. Use for 'find my phone', 'where's my phone', or 'ring my phone'. Pass action='stop' to silence it."
    public let requiresConfirmation = false
    public let parametersJSON = """
    {"type":"object","properties":{"action":{"type":"string","enum":["ring","stop"],"description":"'ring' (default) starts the alerts; 'stop' silences them."}},"additionalProperties":false}
    """

    private let ringer: any PhoneRinging
    private let phoneNumber: String?

    public init(ringer: any PhoneRinging, phoneNumber: String? = nil) {
        self.ringer = ringer
        let trimmed = phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phoneNumber = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public func invoke(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let action: String? }
        let args = (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))) ?? Args(action: nil)

        if (args.action ?? "ring").lowercased() == "stop" {
            await ringer.stop()
            return #"{"ok":true,"action":"stop"}"#
        }

        let ok = await ringer.ring()
        guard ok else {
            return #"{"ok":false,"error":"notifications_unavailable","hint":"Enable notifications for Nova in iOS Settings so the phone can ring."}"#
        }
        if let phoneNumber {
            return #"{"ok":true,"action":"ring","number":"\#(Self.escape(phoneNumber))"}"#
        }
        return #"{"ok":true,"action":"ring"}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
