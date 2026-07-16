import Foundation
import os

public enum NovaLog {
    public static let session = Logger(subsystem: "ai.nova", category: "session")
    public static let audio = Logger(subsystem: "ai.nova", category: "audio")
    public static let ai = Logger(subsystem: "ai.nova", category: "ai")
    public static let vision = Logger(subsystem: "ai.nova", category: "vision")
    public static let tools = Logger(subsystem: "ai.nova", category: "tools")
}
