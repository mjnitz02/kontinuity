//
//  GlassesKeyCommands.swift
//  Kontinuity
//
//  Mode B's keyboard, as `UIKeyCommand`s rather than SwiftUI's `onKeyPress`
//  (READER-DESIGN §3's binding table). The swap isn't stylistic — measured on
//  an iPad with a Magic Keyboard and reproduced by
//  `GlassesModeUITests.testArrowKeysAdvanceAndRetreatTheBandIndex`, the arrow
//  keys never arrive at `onKeyPress` at all, in either the catch-all or the
//  explicit `keys:` form, while Esc and every letter binding arrive fine.
//  iPadOS reserves the directional keys for focus movement ahead of the
//  responder chain, and SwiftUI offers no way to say otherwise.
//
//  `UIKeyCommand.wantsPriorityOverSystemBehavior` is exactly that opt-out, and
//  it's UIKit-only — hence this bridge. Routing *every* binding through it,
//  not just the arrows, is deliberate: one input mechanism for the surface
//  that "owns all keyboard handling" beats two that disagree about which keys
//  they see, and it drops Mode B's dependence on SwiftUI focus entirely
//  (nothing here needs `.focusable()`, so nothing can steal focus and
//  silently kill paging).
//

import SwiftUI
import UIKit

/// One place for the binding table so `GlassesReaderView` maps intent to
/// action and this file maps hardware to intent — neither has to know both.
enum GlassesKey: Int, CaseIterable {
    case advanceBand
    case retreatBand
    case nextPage
    case previousPage
    case exit
    case dimDecrease
    case dimIncrease
    case toggleAutoScroll
    case exitAutoMode
    case autoScrollSlower
    case autoScrollFaster
    case nextBook
    case toggleFlow
    case widthFitDecrease
    case widthFitIncrease
}

/// One hardware key, its modifiers, and what Mode B does with it. File scope
/// rather than nested inside `KeyCommandView` purely so the nesting stays one
/// level deep.
private struct KeyBinding {
    let input: String
    let modifiers: UIKeyModifierFlags
    let key: GlassesKey

    init(_ input: String, _ modifiers: UIKeyModifierFlags, _ key: GlassesKey) {
        self.input = input
        self.modifiers = modifiers
        self.key = key
    }
}

/// An invisible, zero-size first responder. It carries no content and takes no
/// touches — the surrounding SwiftUI view still draws the bands and handles
/// taps; this exists only to hold the key commands.
struct GlassesKeyCommandCatcher: UIViewRepresentable {
    let onKey: (GlassesKey) -> Void

    func makeUIView(context _: Context) -> KeyCommandView {
        let view = KeyCommandView()
        view.onKey = onKey
        return view
    }

    /// Also the re-acquire hook: tapping a chrome button makes *it* the first
    /// responder, and SwiftUI runs this on the state change that follows, so
    /// the keyboard comes back without a separate watchdog.
    func updateUIView(_ uiView: KeyCommandView, context _: Context) {
        uiView.onKey = onKey
        if uiView.window != nil, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        }
    }

    final class KeyCommandView: UIView {
        var onKey: ((GlassesKey) -> Void)?

        override var canBecomeFirstResponder: Bool {
            true
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // A first `becomeFirstResponder()` can land before the window is
            // ready to hand it over; one deferred retry covers that without a
            // polling loop.
            if !becomeFirstResponder() {
                DispatchQueue.main.async { [weak self] in
                    _ = self?.becomeFirstResponder()
                }
            }
        }

        override var keyCommands: [UIKeyCommand]? {
            Self.bindings.enumerated().map { index, binding in
                let command = UIKeyCommand(
                    action: #selector(handleKeyCommand(_:)),
                    input: binding.input,
                    modifierFlags: binding.modifiers,
                    propertyList: index
                )
                // The whole reason this file exists: without it the arrows go
                // to focus movement and never reach `handleKeyCommand`.
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }

        @objc private func handleKeyCommand(_ command: UIKeyCommand) {
            guard let index = command.propertyList as? Int, Self.bindings.indices.contains(index) else { return }
            onKey?(Self.bindings[index].key)
        }

        /// READER-DESIGN §3's table, plus `,`/`.` for the width fit, which
        /// postdates that table. `P` (previous volume) is the one
        /// binding still missing: nothing in the app fetches a *previous* book
        /// yet, so it's left unbound rather than bound to a no-op.
        private static let bindings: [KeyBinding] = [
            KeyBinding(UIKeyCommand.inputRightArrow, [], .advanceBand),
            KeyBinding(UIKeyCommand.inputDownArrow, [], .advanceBand),
            KeyBinding(" ", [], .advanceBand),
            KeyBinding(UIKeyCommand.inputLeftArrow, [], .retreatBand),
            KeyBinding(UIKeyCommand.inputUpArrow, [], .retreatBand),
            KeyBinding(" ", .shift, .retreatBand),
            KeyBinding(UIKeyCommand.inputPageDown, [], .nextPage),
            KeyBinding(UIKeyCommand.inputPageUp, [], .previousPage),
            KeyBinding(UIKeyCommand.inputEscape, [], .exit),
            KeyBinding("[", [], .dimDecrease),
            KeyBinding("]", [], .dimIncrease),
            KeyBinding("a", [], .toggleAutoScroll),
            KeyBinding("a", .shift, .exitAutoMode),
            KeyBinding("-", [], .autoScrollSlower),
            KeyBinding("=", [], .autoScrollFaster),
            KeyBinding("n", [], .nextBook),
            KeyBinding("c", [], .toggleFlow),
            KeyBinding(",", [], .widthFitDecrease),
            KeyBinding(".", [], .widthFitIncrease)
        ]
    }
}
