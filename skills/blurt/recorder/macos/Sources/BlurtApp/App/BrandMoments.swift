// SwiftUI helpers for the main window, Settings and onboarding on design system v2 (docs/design/system.md §3.3–3.5,
// §4), built on Icons/BrandViews.swift:
//
//   .primaryButton(on)            the brand button when `on`, the native one otherwise (one primary per view)
//   SpectrumGlow                  a soft, blurred, still spectrum disc behind the onboarding mascot — the one place the
//                                 spectrum appears; nothing with Reduce Transparency
//
// Empty states use `EmptyStateContent` (BrandViews.swift): the app-icon mark, a title, a hint.
import AppKit
import SwiftUI

extension View {
    /// The brand primary when `on`, else the default (native) button style.
    @ViewBuilder func primaryButton(_ on: Bool) -> some View {
        if on { buttonStyle(.brand) } else { buttonStyle(.automatic) }
    }
}

/// A soft spectrum glow behind the onboarding mascot (the hero art, §3.4): a blurred angular disc, still (it never
/// turns). Hidden with Reduce Transparency. Nowhere else.
struct SpectrumGlow: View {
    var size: CGFloat = 150
    var opacity: Double = 0.55
    var body: some View {
        if !reduceTransparency {
            let st = BrandGradient.spectrumStops + [BrandGradient.spectrumStops[0]]
            Circle()
                .fill(AngularGradient(stops: st.enumerated().map { i, s in
                    .init(color: Color(nsColor: BrandColor.srgb(s.0)), location: i == st.count - 1 ? 1 : s.1 * 0.92) },
                                      center: .center, angle: .degrees(-30)))
                .frame(width: size, height: size)
                .blur(radius: size * 0.22)
                .opacity(opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
