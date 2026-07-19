import SwiftUI

/// Counts down to `endsAt`, self-updating in the widget. Guards against an
/// already-passed date (an invalid `Date...Date` range would trap).
struct CountdownText: View {
    let endsAt: Date

    var body: some View {
        if endsAt > Date() {
            Text(timerInterval: Date()...endsAt, countsDown: true)
                .monospacedDigit()
        } else {
            Text("0:00")
                .monospacedDigit()
        }
    }
}
