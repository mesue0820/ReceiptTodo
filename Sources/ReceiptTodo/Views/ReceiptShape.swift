import SwiftUI

enum ReceiptTheme {
    static let paper = Color(red: 0.985, green: 0.985, blue: 0.982)
    static let paperSubtle = Color(red: 0.935, green: 0.938, blue: 0.942)
    static let ink = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let inkSecondary = Color(red: 0.34, green: 0.34, blue: 0.35)
    static let inkMuted = Color(red: 0.54, green: 0.55, blue: 0.56)
    static let dashLine = Color(red: 0.35, green: 0.35, blue: 0.36)
    static let stampRed = Color(red: 0.80, green: 0.17, blue: 0.14)
    static let accentWarm = Color(red: 0.84, green: 0.32, blue: 0.16)
    static let highlightBg = Color(red: 0.99, green: 0.94, blue: 0.78)
}

/// Photorealistic hanging thermal receipt silhouette with a crisp classic sawtooth serrated hem
/// (matching the iconic serrated bottom edge in the reference receipt images).
struct ThermalReceiptShape: Shape {
    var topPinch: CGFloat = 1.6
    var toothWidth: CGFloat = 13.5
    var toothHeight: CGFloat = 6.5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let p = min(topPinch, rect.width * 0.04)
        let teethBaseY = rect.maxY - toothHeight

        // Flat top edge tucked cleanly inside the dark center printer slot
        path.move(to: CGPoint(x: rect.minX + p, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - p, y: rect.minY))

        // Gentle hanging right edge down to serrated hem
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: teethBaseY),
            control1: CGPoint(x: rect.maxX - p * 0.25, y: teethBaseY * 0.30),
            control2: CGPoint(x: rect.maxX + 0.5, y: teethBaseY * 0.72)
        )

        // Crisp equilateral sawtooth serrated bottom edge (right -> left)
        let count = max(6, Int(round(rect.width / toothWidth)))
        let actualToothWidth = rect.width / CGFloat(count)
        var currentX = rect.maxX
        for _ in 0..<count {
            let midX = currentX - actualToothWidth / 2.0
            let nextX = currentX - actualToothWidth
            path.addLine(to: CGPoint(x: midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: nextX, y: teethBaseY))
            currentX = nextX
        }

        // Gentle hanging left edge back up to top slot
        path.addCurve(
            to: CGPoint(x: rect.minX + p, y: rect.minY),
            control1: CGPoint(x: rect.minX - 0.5, y: teethBaseY * 0.72),
            control2: CGPoint(x: rect.minX + p * 0.25, y: teethBaseY * 0.30)
        )
        path.closeSubpath()
        return path
    }
}

/// Hanging receipt silhouette whose top edge progressively unzips into crisp cutter teeth
/// from left to right as `topTearProgress` moves from 0.0 -> 1.0, while keeping the classic
/// sawtooth serrated bottom hem intact.
struct DoubleSerratedReceiptShape: Shape {
    var topPinch: CGFloat = 1.6
    var toothWidth: CGFloat = 13.5
    var toothHeight: CGFloat = 6.5
    var topToothHeight: CGFloat = 4.8
    var topTearProgress: CGFloat = 0.0

    var animatableData: CGFloat {
        get { topTearProgress }
        set { topTearProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let p = min(topPinch, rect.width * 0.04)
        let teethBaseY = rect.maxY - toothHeight
        let topStartX = rect.minX + p
        let topEndX = rect.maxX - p
        let topSpan = max(1, topEndX - topStartX)
        let progress = max(0.0, min(1.0, topTearProgress))

        if progress <= 0.005 {
            path.move(to: CGPoint(x: topStartX, y: rect.minY))
            path.addLine(to: CGPoint(x: topEndX, y: rect.minY))
        } else {
            let count = max(8, Int(round(topSpan / toothWidth)))
            let actualTW = topSpan / CGFloat(count)
            let tearEndX = topStartX + topSpan * progress

            path.move(to: CGPoint(x: topStartX, y: rect.minY + topToothHeight))
            var x = topStartX
            for _ in 0..<count {
                let midX = x + actualTW * 0.5
                let nextX = x + actualTW
                if x >= tearEndX {
                    break
                }
                if midX <= tearEndX {
                    path.addLine(to: CGPoint(x: midX, y: rect.minY))
                    if nextX <= tearEndX {
                        path.addLine(to: CGPoint(x: nextX, y: rect.minY + topToothHeight))
                    } else {
                        let frac = (tearEndX - midX) / max(0.001, actualTW * 0.5)
                        path.addLine(to: CGPoint(x: tearEndX, y: rect.minY + topToothHeight * frac))
                    }
                } else {
                    let frac = (tearEndX - x) / max(0.001, actualTW * 0.5)
                    path.addLine(to: CGPoint(x: tearEndX, y: rect.minY + topToothHeight * (1.0 - frac)))
                }
                x = nextX
            }

            if tearEndX < topEndX - 0.5 {
                // Smoothly rejoin the still-attached straight top edge tucked into the slot
                path.addLine(to: CGPoint(x: min(topEndX, tearEndX + 2.5), y: rect.minY))
                path.addLine(to: CGPoint(x: topEndX, y: rect.minY))
            } else {
                path.addLine(to: CGPoint(x: topEndX, y: rect.minY + topToothHeight))
            }
        }

        // Gentle hanging right edge down to serrated bottom hem
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: teethBaseY),
            control1: CGPoint(x: rect.maxX - p * 0.25, y: teethBaseY * 0.30),
            control2: CGPoint(x: rect.maxX + 0.5, y: teethBaseY * 0.72)
        )

        // Classic sawtooth serrated bottom edge (right -> left)
        let bottomCount = max(6, Int(round(rect.width / toothWidth)))
        let actualBottomTW = rect.width / CGFloat(bottomCount)
        var currentX = rect.maxX
        for _ in 0..<bottomCount {
            let midX = currentX - actualBottomTW / 2.0
            let nextX = currentX - actualBottomTW
            path.addLine(to: CGPoint(x: midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: nextX, y: teethBaseY))
            currentX = nextX
        }

        // Gentle hanging left edge back up to top
        let topLeftY = progress > 0.005 ? (rect.minY + topToothHeight) : rect.minY
        path.addCurve(
            to: CGPoint(x: topStartX, y: topLeftY),
            control1: CGPoint(x: rect.minX - 0.5, y: teethBaseY * 0.72),
            control2: CGPoint(x: rect.minX + p * 0.25, y: teethBaseY * 0.30)
        )
        path.closeSubpath()
        return path
    }
}

/// Delicate perforation guide visible along the untorn portion of the top seam while pulling.
struct PerforationSeamLine: View {
    let tearProgress: CGFloat
    let tensionOpacity: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let splitX = max(0, min(w, w * tearProgress))
            ZStack(alignment: .leading) {
                if splitX < w - 2 {
                    Path { path in
                        path.move(to: CGPoint(x: splitX + 2, y: 2.5))
                        path.addLine(to: CGPoint(x: w - 2, y: 2.5))
                    }
                    .stroke(
                        ReceiptTheme.ink.opacity(0.32 * tensionOpacity),
                        style: StrokeStyle(lineWidth: 1.0, lineCap: .round, dash: [2.2, 3.0])
                    )
                }

                // Subtle tactile highlight at the active fiber separation point
                if tearProgress > 0.03 && tearProgress < 0.98 {
                    Circle()
                        .fill(ReceiptTheme.ink.opacity(0.28))
                        .frame(width: 4, height: 4)
                        .offset(x: max(0, splitX - 2), y: 0.5)
                }
            }
        }
        .frame(height: 5)
        .allowsHitTesting(false)
    }
}

/// Tiny matching serrated remnant paper stub visible inside the slot as the receipt peels away.
struct SlotRemnantStubView: View {
    let width: CGFloat
    let tearProgress: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            ThermalPaperSurface()
            SlotContactShadow()
        }
        .frame(width: width, height: 11)
        .clipShape(ThermalReceiptShape(topPinch: 1.6, toothWidth: 13.5, toothHeight: 4.5))
        .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1.5)
        .mask(
            HStack(spacing: 0) {
                Rectangle()
                    .frame(width: max(0, width * max(0, min(1, tearProgress))))
                Spacer(minLength: 0)
            }
            .frame(width: width)
        )
        .allowsHitTesting(false)
    }
}

struct ThermalPaperSurface: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.91, green: 0.915, blue: 0.925), location: 0.00),
                    .init(color: Color(red: 0.992, green: 0.992, blue: 0.990), location: 0.14),
                    .init(color: Color(red: 0.998, green: 0.998, blue: 0.996), location: 0.30),
                    .init(color: Color(red: 0.922, green: 0.926, blue: 0.935), location: 0.50),
                    .init(color: Color(red: 0.916, green: 0.920, blue: 0.930), location: 0.57),
                    .init(color: Color(red: 0.994, green: 0.994, blue: 0.992), location: 0.80),
                    .init(color: Color(red: 0.968, green: 0.970, blue: 0.974), location: 0.93),
                    .init(color: Color(red: 0.885, green: 0.890, blue: 0.900), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.065), location: 0.00),
                    .init(color: Color.black.opacity(0.015), location: 0.025),
                    .init(color: Color.clear, location: 0.07),
                    .init(color: Color.clear, location: 0.93),
                    .init(color: Color.black.opacity(0.018), location: 0.975),
                    .init(color: Color.black.opacity(0.075), location: 1.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

struct SlotContactShadow: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.52), location: 0.00),
                .init(color: Color.black.opacity(0.24), location: 0.24),
                .init(color: Color.black.opacity(0.07), location: 0.58),
                .init(color: Color.clear, location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 20)
        .allowsHitTesting(false)
    }
}

struct DashedDivider: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(
                ReceiptTheme.dashLine.opacity(0.82),
                style: StrokeStyle(lineWidth: 1, dash: [3.2, 2.8])
            )
        }
        .frame(height: 1)
    }
}

/// Delicate Swiss receipt dotted leader line ("…………") linking task title to right-aligned time.
struct DottedLeaderLine: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let y = geo.size.height - 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
            .stroke(
                ReceiptTheme.ink.opacity(0.24),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3.2])
            )
        }
        .frame(height: 10)
        .frame(minWidth: 12)
    }
}

struct DecorativeBarcodeView: View {
    let seed: String
    var height: CGFloat = 30
    var barCount: Int = 56

    private var bars: [CGFloat] {
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        var widths: [CGFloat] = []
        for i in 0..<barCount {
            let bit = (hash >> UInt64(i % 56)) & 0x3
            switch bit {
            case 0: widths.append(1.0)
            case 1: widths.append(2.3)
            case 2: widths.append(1.4)
            default: widths.append(3.2)
            }
            hash = hash &* 6364136223846793005 &+ 1
        }
        return widths
    }

    var body: some View {
        HStack(spacing: 1.35) {
            ForEach(Array(bars.enumerated()), id: \.offset) { idx, width in
                Rectangle()
                    .fill(idx % 2 == 0 ? ReceiptTheme.ink.opacity(0.92) : Color.clear)
                    .frame(width: width, height: height)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

struct StampBadgeView: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 10, weight: .bold))
            Text("PAID · 今日已核销")
                .font(.system(size: 10, weight: .black, design: .monospaced))
        }
        .foregroundColor(ReceiptTheme.stampRed)
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(ReceiptTheme.stampRed.opacity(0.88), lineWidth: 1.5)
        )
        .rotationEffect(.degrees(-5))
        .transition(.scale(scale: 1.38).combined(with: .opacity))
    }
}
