import ActivityKit
import SwiftUI
import WidgetKit
import NovaLiveActivity

/// Max's rest-timer Live Activity — lock screen banner + Dynamic Island.
struct RestTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestTimerAttributes.self) { context in
            RestLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.exercise).lineLimit(1)
                    } icon: {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(endsAt: context.state.endsAt)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.orange)
                        .frame(width: 66)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Rest — \(context.attributes.workoutTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(.orange)
            } compactTrailing: {
                CountdownText(endsAt: context.state.endsAt)
                    .foregroundStyle(.orange)
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.orange)
            }
            .keylineTint(.orange)
        }
    }
}

private struct RestLockScreenView: View {
    let context: ActivityViewContext<RestTimerAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "timer")
                .font(.title)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("REST")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.secondary)
                Text(context.state.exercise)
                    .font(.headline)
                    .lineLimit(1)
                Text(context.attributes.workoutTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            CountdownText(endsAt: context.state.endsAt)
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.orange)
        }
        .padding()
    }
}
