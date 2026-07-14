import SwiftUI
import AppKit

/// Hero art for the setup wizard: bundled illustrations when present, with
/// code-drawn abstract compositions as the fallback for any missing step.
struct OnboardingArt: View {
    let step: Int

    /// Bundled step art, loaded once (onboarding-<step>.png in Resources).
    private static let images: [NSImage?] = (0..<4).map { step in
        Bundle.module.url(forResource: "onboarding-\(step)", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    }

    var body: some View {
        if step < Self.images.count, let image = Self.images[step] {
            GeometryReader { geo in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.backdropTop, Brand.backdrop],
                startPoint: .top, endPoint: .bottom)

            // Soft glows behind the geometry
            Circle().fill(Brand.indigo.opacity(0.32))
                .frame(width: 150, height: 150).blur(radius: 46)
                .offset(x: -90, y: -18)
            Circle().fill(Brand.violet.opacity(0.30))
                .frame(width: 180, height: 180).blur(radius: 55)
                .offset(x: 110, y: 28)

            composition
                .rotationEffect(.degrees(-6))

            dotTrail
        }
        .clipped()
    }

    @ViewBuilder
    private var composition: some View {
        switch step {
        case 0: welcomeArt
        case 1: accountArt
        case 2: storageArt
        default: tokenArt
        }
    }

    /// Drop → link: a gradient disc, a floating "file" tile, an orbit arc.
    private var welcomeArt: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Brand.indigo, Brand.violet],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 110, height: 110)
                .offset(x: -34, y: 4)
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.09))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.2))
                .frame(width: 74, height: 92)
                .rotationEffect(.degrees(9))
                .offset(x: 34, y: -8)
            orbitArc(radius: 84, trim: 0.30)
                .offset(x: 0, y: 6)
            Circle().fill(Brand.coral)
                .frame(width: 12, height: 12)
                .offset(x: 78, y: -46)
        }
    }

    /// Identity: two overlapping discs with an orbiting satellite.
    private var accountArt: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Brand.violet, Brand.indigo.opacity(0.6)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 96, height: 96)
                .offset(x: -26, y: 0)
            Circle()
                .strokeBorder(Brand.indigo, lineWidth: 2)
                .frame(width: 96, height: 96)
                .offset(x: 24, y: -6)
            orbitArc(radius: 92, trim: 0.42)
            Circle().fill(Brand.coral)
                .frame(width: 10, height: 10)
                .offset(x: -88, y: 26)
        }
    }

    /// Storage: stacked gradient bars behind a dashed ring.
    private var storageArt: some View {
        ZStack {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [4, 6]))
                .foregroundStyle(Color.white.opacity(0.30))
                .frame(width: 148, height: 148)
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(
                            colors: [Brand.indigo.opacity(1 - Double(index) * 0.28),
                                     Brand.violet.opacity(0.9 - Double(index) * 0.28)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: 118 - CGFloat(index) * 14, height: 22)
                }
            }
            Circle().fill(Brand.coral)
                .frame(width: 12, height: 12)
                .offset(x: 70, y: -58)
        }
    }

    /// Capability: a broken ring with its key-dot, one clean diagonal.
    private var tokenArt: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(LinearGradient(colors: [Brand.indigo, Brand.violet],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .frame(width: 104, height: 104)
                .rotationEffect(.degrees(58))
            Circle().fill(Brand.coral)
                .frame(width: 16, height: 16)
                .offset(x: 44, y: 44)
            Rectangle()
                .fill(Color.white.opacity(0.30))
                .frame(width: 74, height: 2)
                .rotationEffect(.degrees(-32))
                .offset(x: -66, y: -34)
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.2)
                .frame(width: 30, height: 30)
                .offset(x: 84, y: -30)
        }
    }

    private func orbitArc(radius: CGFloat, trim: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(Color.white.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: radius * 2, height: radius * 2)
            .rotationEffect(.degrees(-150))
    }

    /// A little confetti of fixed dots in the corners — deterministic, tuned.
    private var dotTrail: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.30)).frame(width: 4, height: 4)
                .offset(x: -150, y: -48)
            Circle().fill(Brand.indigo.opacity(0.8)).frame(width: 6, height: 6)
                .offset(x: -170, y: 30)
            Circle().fill(Color.white.opacity(0.22)).frame(width: 4, height: 4)
                .offset(x: 156, y: -52)
            Circle().fill(Brand.violet.opacity(0.8)).frame(width: 5, height: 5)
                .offset(x: 176, y: 44)
        }
    }
}
