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

    #if canImport(UserNotifications)
    /// Runs scheduled skills when their notification fires/is tapped.
    private let notifications: NotificationCoordinator
    #endif

    init() {
        #if canImport(UserNotifications)
        let coordinator = NotificationCoordinator(
            orchestrator: container.orchestrator,
            skillStore: container.skillStore
        )
        self.notifications = coordinator
        coordinator.install()
        #endif

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
                video: container.videoRecordingVM,
                workspaces: container.workspacesVM,
                skills: container.skillsVM,
                knowledge: container.knowledgeVM,
                visualMemory: container.visualMemoryVM,
                agents: container.agentsVM,
                coding: container.codingVM,
                training: container.trainingVM,
                wellness: container.wellnessVM,
                kitchen: container.kitchenVM,
                study: container.studyVM,
                settings: container.settingsVM,
                toolConfirmation: container.toolConfirmation,
                appNavigation: container.appNavigation
            )
            #if canImport(MWDATCore)
            // Meta AI deep-links back here after registration / permission grants.
            // handleUrl must complete so Wearables can apply the Always-Allow result
            // before the next createSession / activeDevice wait.
            .onOpenURL { url in
                Task {
                    do {
                        _ = try await Wearables.shared.handleUrl(url)
                    } catch {
                        print("Wearables.handleUrl failed: \(error)")
                    }
                }
            }
            #endif
        }
    }
}
