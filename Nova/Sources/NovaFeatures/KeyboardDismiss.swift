import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum KeyboardDismiss {
    /// Resign first responder so any open software keyboard hides.
    public static func hide() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }
}

public extension View {
    /// Tap anywhere to dismiss the keyboard without delaying buttons / NavigationLinks.
    ///
    /// Uses a window-level UIKit recognizer (`cancelsTouchesInView = false`) instead of
    /// SwiftUI `simultaneousGesture(TapGesture)`, which races List row recognition and
    /// makes quick taps feel like they require a press-and-hold.
    func dismissKeyboardOnTap() -> some View {
        #if canImport(UIKit)
        background(WindowKeyboardDismissInstaller())
        #else
        self
        #endif
    }
}

#if canImport(UIKit)
/// Installs a non-cancelling tap recognizer on the key window so keyboard dismiss
/// coexists with SwiftUI controls.
private struct WindowKeyboardDismissInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.anchorView = view
        // Window may not be attached yet during makeUIView.
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded()
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.installIfNeeded()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var anchorView: UIView?
        private weak var window: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        func installIfNeeded() {
            guard recognizer == nil, let window = anchorView?.window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            self.window = window
            recognizer = tap
        }

        func uninstall() {
            if let recognizer, let window {
                window.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            window = nil
        }

        @objc private func handleTap() {
            KeyboardDismiss.hide()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
