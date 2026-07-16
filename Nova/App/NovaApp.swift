import SwiftUI
import NovaComposition
import NovaFeatures
#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct NovaApp: App {
    /// Fake AI + silent mic + mock glasses for Simulator / first launch without
    /// credentials or hardware. On a real iPhone 11 + glasses, flip all three to
    /// `false` for Realtime + HFP audio + Meta AI registration and live camera.
    private let container = AppContainer(useFakeAI: true, useSilentMic: true, useMockGlasses: true)

    init() {
        #if canImport(MWDATCore)
        // Initialize the Meta Wearables Device Access Toolkit once at launch so
        // the glasses camera can be reached from MetaDATFrameCapture.
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Wearables SDK configuration failed: \(error)")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                session: container.sessionVM,
                conversation: container.conversationVM,
                vision: container.visionVM
            )
            #if canImport(MWDATCore)
            // Meta AI deep-links back here after registration / permission grants.
            .onOpenURL { url in
                Task { _ = try? await Wearables.shared.handleUrl(url) }
            }
            #endif
        }
    }
}
