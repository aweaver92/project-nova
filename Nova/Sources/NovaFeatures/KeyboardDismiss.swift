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
    /// Tap outside editable text to dismiss the keyboard without delaying buttons /
    /// NavigationLinks.
    ///
    /// Uses a window-level UIKit recognizer (`cancelsTouchesInView = false`) instead of
    /// SwiftUI `simultaneousGesture(TapGesture)`, which races List row recognition and
    /// makes quick taps feel like they require a press-and-hold.
    ///
    /// Taps on `UITextField` / `UITextView` (SwiftUI `TextField` / `TextEditor`) and
    /// the prompt/composer fields are ignored so caret placement and editing keep working.
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
        private var keyboardVisible = false
        private var keyboardObservers: [NSObjectProtocol] = []

        override init() {
            super.init()
            let center = NotificationCenter.default
            keyboardObservers = [
                center.addObserver(
                    forName: UIResponder.keyboardWillShowNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.keyboardVisible = true
                },
                center.addObserver(
                    forName: UIResponder.keyboardDidHideNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.keyboardVisible = false
                }
            ]
        }

        deinit {
            keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        func installIfNeeded() {
            let targetWindow = anchorView?.window ?? Self.keyWindow()
            guard let targetWindow else { return }

            // Re-bind if the key window changed (tab / sheet presentation).
            if let recognizer, window !== targetWindow {
                window?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
                window = nil
            }

            guard recognizer == nil else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            targetWindow.addGestureRecognizer(tap)
            window = targetWindow
            recognizer = tap
        }

        func uninstall() {
            if let recognizer, let window {
                window.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            window = nil
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard keyboardVisible || Self.hasFirstResponder() else { return }
            guard let host = gesture.view else {
                KeyboardDismiss.hide()
                return
            }
            let point = gesture.location(in: host)
            if let hit = host.hitTest(point, with: nil), Self.isEditableTextSurface(hit) {
                // Prompt box / TextField / TextEditor — keep keyboard and caret.
                return
            }
            KeyboardDismiss.hide()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            // Don't even begin recognizing on text surfaces — avoids racing caret
            // placement with resignFirstResponder.
            if let view = touch.view, Self.isEditableTextSurface(view) {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// True when the touch is inside a text field, text view, or search bar
        /// (walks superviews for SwiftUI hosting wrappers).
        static func isEditableTextSurface(_ view: UIView) -> Bool {
            var current: UIView? = view
            while let node = current {
                if node is UITextField || node is UITextView || node is UISearchBar {
                    return true
                }
                // SwiftUI sometimes inserts private subclasses; class name is stable enough.
                let name = String(describing: type(of: node))
                if name.contains("TextField")
                    || name.contains("TextEditor")
                    || name.contains("UIText")
                    || name.contains("SearchField")
                {
                    return true
                }
                current = node.superview
            }
            return false
        }

        static func hasFirstResponder() -> Bool {
            guard let window = keyWindow() else { return false }
            return window.findFirstResponder() != nil
        }

        static func keyWindow() -> UIWindow? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        }
    }
}

private extension UIView {
    func findFirstResponder() -> UIView? {
        if isFirstResponder { return self }
        for child in subviews {
            if let found = child.findFirstResponder() { return found }
        }
        return nil
    }
}
#endif
