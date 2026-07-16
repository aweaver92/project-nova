import SwiftUI
import NovaComposition
import NovaFeatures

@main
struct NovaApp: App {
    /// Fake AI + silent mic for Simulator / first launch without credentials or glasses.
    /// Flip both to `false` for device + Realtime + HFP.
    private let container = AppContainer(useFakeAI: true, useSilentMic: true)

    var body: some Scene {
        WindowGroup {
            RootView(
                session: container.sessionVM,
                conversation: container.conversationVM,
                vision: container.visionVM
            )
        }
    }
}
