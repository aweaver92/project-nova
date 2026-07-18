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
    /// Tap anywhere (alongside buttons/rows) to dismiss the keyboard.
    func dismissKeyboardOnTap() -> some View {
        simultaneousGesture(
            TapGesture().onEnded { _ in
                KeyboardDismiss.hide()
            }
        )
    }
}
