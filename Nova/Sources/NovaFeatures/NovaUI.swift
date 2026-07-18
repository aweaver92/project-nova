import SwiftUI

/// Compact shared UI primitives for the power-user shell.
enum NovaUI {
    /// Horizontal status chips used on the Assistant HUD.
    struct StatusChip: View {
        let title: String
        let value: String
        let color: Color

        var body: some View {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text("\(title): \(value)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    /// Confirmation alert for destructive bulk clears.
    struct ClearConfirmModifier: ViewModifier {
        @Binding var isPresented: Bool
        let title: String
        let message: String
        let confirmTitle: String
        let onConfirm: () -> Void

        func body(content: Content) -> some View {
            content
                .alert(title, isPresented: $isPresented) {
                    Button("Cancel", role: .cancel) {}
                    Button(confirmTitle, role: .destructive, action: onConfirm)
                } message: {
                    Text(message)
                }
        }
    }
}

extension View {
    func novaConfirmClear(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmTitle: String = "Delete All",
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(NovaUI.ClearConfirmModifier(
            isPresented: isPresented,
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            onConfirm: onConfirm
        ))
    }
}
