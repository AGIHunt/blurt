// SwiftUI helpers for the main window, Settings and onboarding on design system v2 (docs/design/system.md §3.3–3.5,
// §4), built on Icons/BrandViews.swift:
//
//   .primaryButton(on)            the brand button when `on`, the native one otherwise (one primary per view)
//   .celebrate(on: trigger)       the completion bloom: a spectrum ring grows out of the view once each time `trigger`
//                                 changes (not on first show); nothing with Reduce Motion or Reduce Transparency
//   SpectrumGlow                  a soft, blurred, still spectrum disc behind a hero (the onboarding mascot); nothing
//                                 with Reduce Transparency
//   BrandArtTile                  the empty-state art in SwiftUI: the field tile with a white line glyph (§3.5)
import AppKit
import SwiftUI

extension View {
    /// The brand primary when `on`, else the default (native) button style.
    @ViewBuilder func primaryButton(_ on: Bool) -> some View {
        if on { buttonStyle(.brand) } else { buttonStyle(.automatic) }
    }

    /// The completion celebration (§4): when `trigger` changes, a spectrum ring blooms out of this view once (0.9 s).
    func celebrate<T: Equatable>(on trigger: T, cornerRadius: CGFloat = 12) -> some View {
        modifier(CelebrationBloom(trigger: trigger, cornerRadius: cornerRadius))
    }
}

private func spectrumAngular(_ angle: Angle = .zero) -> AngularGradient {
    let st = BrandGradient.spectrumStops + [BrandGradient.spectrumStops[0]]
    return AngularGradient(stops: st.enumerated().map { i, s in
        .init(color: Color(nsColor: BrandColor.srgb(s.0)), location: i == st.count - 1 ? 1 : s.1 * 0.92) },
                           center: .center, angle: angle)
}

struct CelebrationBloom<T: Equatable>: ViewModifier {
    let trigger: T
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var progress: CGFloat = 1        // 1 = done (invisible)

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(spectrumAngular(), lineWidth: 3)
                    .padding(-6)
                    .scaleEffect(1 + 0.12 * progress)
                    .opacity(progress >= 1 ? 0 : Double(1 - progress))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onChange(of: trigger) { _ in
                guard !(reduce || reduceMotion || reduceTransparency) else { return }
                progress = 0
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9)) { progress = 1 }
            }
    }
}

/// A soft spectrum glow (the special-moment spectrum, §4): a blurred angular disc, still (it never turns: one moving
/// brand thing per screen, and the hero is a still picture). Hidden with Reduce Transparency.
struct SpectrumGlow: View {
    var size: CGFloat = 150
    var opacity: Double = 0.55
    var body: some View {
        if !reduceTransparency {
            Circle()
                .fill(spectrumAngular(.degrees(-30)))
                .frame(width: size, height: size)
                .blur(radius: size * 0.22)
                .opacity(opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The empty-state art tile (§3.5) for SwiftUI pages: the field (light) / deep (dark) with grain, corners ≈ 30 % of the
/// side, a white line glyph with a soft `BrandColor.on` 30 % shadow. Decoration.
struct BrandArtTile: View {
    var icon: BlurtIcon = .blurt
    var side: CGFloat = 104
    var body: some View {
        ZStack {
            BrandField(cornerRadius: (side * 0.3).rounded())
            Image(nsImage: icon.image(size: (side * 0.52).rounded(), color: .white, weight: 1.15))
                .shadow(color: reduceTransparency ? .clear : Color(nsColor: BrandColor.srgb(0x04261E)).opacity(0.3), radius: 5, y: 2)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
