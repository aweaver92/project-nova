import SwiftUI
import WidgetKit

/// Widget extension entry point. Hosts Nova's Live Activities (Max rest timer,
/// Remy cook mode) so they render on the lock screen and Dynamic Island.
@main
struct NovaWidgetBundle: WidgetBundle {
    var body: some Widget {
        RestTimerLiveActivity()
        CookStepLiveActivity()
    }
}
