import SwiftUI
import NovaComposition
import NovaFeatures
#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct NovaApp: App {
    /// Device mode: real OpenAI Realtime + HFP glasses audio + Meta AI registration
    /// and live camera. Requires a key in Config/Secrets.xcconfig and paired glasses.
    /// For Simulator / no-hardware runs, set all three back to `true`.
    private let container = AppContainer(useFakeAI: false, useSilentMic: false, useMockGlasses: false)

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
                vision: container.visionVM,
                notes: container.notesVM,
                recording: container.recordingVM,
                workspaces: container.workspacesVM,
                skills: container.skillsVM,
                knowledge: container.knowledgeVM
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
