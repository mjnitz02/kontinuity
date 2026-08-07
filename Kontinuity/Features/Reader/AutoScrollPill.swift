//
//  AutoScrollPill.swift
//  Kontinuity
//
//  Auto mode's own controls, on the reading surface rather than in the menu
//  that covers it. The problem it replaces: the speed buttons used to live in
//  the chrome toolbar, so the only way to press one was with the chrome open —
//  and the chrome's material toolbar draws directly over the status line the
//  press was trying to report through. The controls and their feedback could
//  never be on screen at the same time.
//
//  So the pill sits in the bottom corner, visible exactly when auto mode is on
//  and the chrome is *not*, and reports the current speed by tinting itself
//  rather than by printing a number: at reading distance through the glasses a
//  colour is legible where "2.0s / move" is not. Four steps, because four
//  colours are tellable apart and twenty were not.
//
//  Rendered in two configurations off the same view, mirroring
//  `GlassesReaderView`'s own split:
//
//  - `isInteractive: true`, the iPad panel — real buttons.
//  - `isInteractive: false`, the external display (`GlassesExternalView`) —
//    the identical pill as a pure indicator, since that scene can never be key
//    and is driven entirely by the keyboard. This is the case the old status
//    line served worst: a 2-second text fade is easy to miss under a blanket,
//    where a colour parked in the corner is not.
//

import KontinuityCore
import SwiftUI

struct AutoScrollPill: View {
    let glasses: GlassesCoordinator
    var isInteractive = true

    var body: some View {
        HStack(spacing: 0) {
            button(
                systemName: "minus",
                label: "Slower",
                identifier: AID.glassesSpeedDecrease,
                isEnabled: glasses.autoScrollStep > 0
            ) {
                glasses.adjustAutoScrollStep(by: -1)
            }

            button(
                systemName: glasses.isAutoScrolling ? "pause.fill" : "play.fill",
                label: glasses.isAutoScrolling ? "Pause auto mode" : "Play auto mode",
                identifier: AID.glassesAutoScrollPlayPause,
                isEnabled: true
            ) {
                glasses.toggleAutoScrollPlayback()
            }

            button(
                systemName: "plus",
                label: "Faster",
                identifier: AID.glassesSpeedIncrease,
                isEnabled: glasses.autoScrollStep < GlassesCoordinator.autoScrollIntervals.count - 1
            ) {
                glasses.adjustAutoScrollStep(by: 1)
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    // Speed is the hue; running-versus-paused is the strength
                    // of it. Two independent signals, no text, and the speed
                    // stays readable while paused instead of going flat grey.
                    Capsule().fill(speedTint.opacity(glasses.isAutoScrolling ? 0.75 : 0.38))
                }
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                }
        }
        .clipShape(Capsule())
        .accessibilityElement(children: isInteractive ? .contain : .ignore)
        .accessibilityIdentifier(AID.glassesAutoScrollPill)
        // Colour alone is no signal to a colourblind reader and none at all to
        // VoiceOver, so the number the pill deliberately doesn't print is
        // still carried here.
        .accessibilityValue(speedDescription)
        .allowsHitTesting(isInteractive)
    }

    private var speedDescription: String {
        let interval = glasses.autoScrollInterval
        let seconds = interval == interval.rounded() ? String(Int(interval)) : String(format: "%.1f", interval)
        let unit = interval == 1 ? "second" : "seconds"
        return "\(seconds) \(unit) per band, \(glasses.isAutoScrolling ? "playing" : "paused")"
    }

    /// Cool for slow, hot for fast — the one mapping a reader guesses without
    /// being told. Indexed by step, so the ramp and
    /// `GlassesCoordinator.autoScrollIntervals` stay the same length.
    private var speedTint: Color {
        let ramp: [Color] = [.blue, .green, .orange, .red]
        return ramp[min(ramp.count - 1, max(0, glasses.autoScrollStep))]
    }

    @ViewBuilder
    private func button(
        systemName: String,
        label: String,
        identifier: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isInteractive {
            Button(action: action) {
                icon(systemName: systemName, isEnabled: isEnabled)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
        } else {
            icon(systemName: systemName, isEnabled: isEnabled)
        }
    }

    /// 44pt tall so the touch target clears the minimum even though the pill
    /// reads as small — it sits inside the forward-paging quarter, where a
    /// near-miss turns a page.
    private func icon(systemName: String, isEnabled: Bool) -> some View {
        Image(systemName: systemName)
            .frame(width: 44, height: 44)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}
