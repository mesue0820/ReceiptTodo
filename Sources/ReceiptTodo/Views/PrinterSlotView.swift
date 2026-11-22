import SwiftUI

enum PrinterSlotMetrics {
    static let bezelHeight: CGFloat = 42
    static let slotCenterY: CGFloat = 21          // Dead-center vertically, matching real slot bezel
    static let slotHeight: CGFloat = 8
    static let expandedBezelWidth: CGFloat = 374
    static let expandedPaperWidth: CGFloat = 320  // 27pt brushed metal flange on each side
    static let expandedSlotWidth: CGFloat = 334   // 7pt dark slit visible flanking left & right of paper

    static let collapsedBezelWidth: CGFloat = 246
    static let collapsedPaperWidth: CGFloat = 200
    static let collapsedSlotWidth: CGFloat = 212
}

/// Layer 1 (Back): Complete photorealistic brushed-silver metallic printer bezel
/// including the inner recessed channel, dead-center deep black exit slot, and lower metallic lip.
struct PrinterSlotBackLayer: View {
    let bezelWidth: CGFloat
    let slotWidth: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(white: 0.72), location: 0.00),
                            .init(color: Color(white: 0.98), location: 0.09),
                            .init(color: Color(white: 0.94), location: 0.22),
                            .init(color: Color(white: 0.78), location: 0.46),
                            .init(color: Color(white: 0.74), location: 0.54),
                            .init(color: Color(white: 0.89), location: 0.80),
                            .init(color: Color(white: 0.96), location: 0.92),
                            .init(color: Color(white: 0.62), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.black.opacity(0.14), location: 0.00),
                                    .init(color: Color.white.opacity(0.32), location: 0.08),
                                    .init(color: Color.black.opacity(0.05), location: 0.26),
                                    .init(color: Color.white.opacity(0.24), location: 0.50),
                                    .init(color: Color.black.opacity(0.06), location: 0.76),
                                    .init(color: Color.white.opacity(0.30), location: 0.92),
                                    .init(color: Color.black.opacity(0.16), location: 1.00)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color(white: 0.55), Color(white: 0.92), Color(white: 0.42)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.9
                        )
                )
                .shadow(color: Color.black.opacity(0.28), radius: 6, x: 0, y: 3)
                .shadow(color: Color.black.opacity(0.14), radius: 1.5, x: 0, y: 1)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(white: 0.62), location: 0.00),
                            .init(color: Color(white: 0.80), location: 0.22),
                            .init(color: Color(white: 0.90), location: 0.44),
                            .init(color: Color(white: 0.72), location: 0.50),
                            .init(color: Color(white: 0.88), location: 0.60),
                            .init(color: Color(white: 0.82), location: 0.82),
                            .init(color: Color(white: 0.66), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.black.opacity(0.30), Color.white.opacity(0.75)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .padding(.horizontal, 5)
                .padding(.vertical, 4)

            ZStack {
                Capsule()
                    .fill(Color.black.opacity(0.24))
                    .frame(width: slotWidth + 4, height: PrinterSlotMetrics.slotHeight + 2.5)
                    .blur(radius: 0.8)

                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(white: 0.02), location: 0.0),
                                .init(color: Color(white: 0.08), location: 0.55),
                                .init(color: Color(white: 0.02), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: slotWidth, height: PrinterSlotMetrics.slotHeight)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
                            .offset(y: 0.8)
                            .mask(Capsule())
                    )
            }
        }
        .frame(width: bezelWidth, height: PrinterSlotMetrics.bezelHeight)
    }
}

/// Layer 3 (Front, top half ONLY): Sits above y = slotCenterY so the emerging paper
/// passes cleanly underneath the upper metallic lip while draping OVER the lower metallic lip.
struct PrinterSlotUpperOverlay: View {
    let bezelWidth: CGFloat
    let isRecording: Bool
    let isPrinting: Bool
    let hasReminder: Bool
    let isExpanded: Bool
    let isHoveringBezel: Bool
    var isClosedForDay: Bool = false

    let onToggleExpand: () -> Void
    let onToggleVoice: () -> Void
    let onOpenSettings: () -> Void

    @State private var ledBlink: Bool = false

    private var isLedActive: Bool {
        isRecording || isPrinting || hasReminder
    }

    private var ledColor: Color {
        if isRecording || hasReminder { return ReceiptTheme.stampRed }
        if isPrinting { return Color(red: 0.14, green: 0.82, blue: 0.42) }
        if isClosedForDay { return Color(white: 0.52) }
        return Color(red: 0.28, green: 0.72, blue: 0.46)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: bezelWidth, height: PrinterSlotMetrics.slotCenterY)
                .contentShape(Rectangle())
                .onTapGesture {
                    onToggleExpand()
                }

            HStack(spacing: 6) {
                Circle()
                    .fill(ledColor)
                    .frame(width: 4.5, height: 4.5)
                    .shadow(color: ledColor.opacity(0.9), radius: isLedActive ? 3.5 : 1.0)
                    .opacity(isLedActive ? (ledBlink ? 1.0 : 0.25) : 0.85)
                    .onAppear {
                        if isLedActive {
                            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                                ledBlink = true
                            }
                        }
                    }
                    .onChange(of: isLedActive) { _, active in
                        if active {
                            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                                ledBlink = true
                            }
                        } else {
                            withAnimation(.default) { ledBlink = false }
                        }
                    }

                if isPrinting {
                    Text("PRINTING")
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(Color(white: 0.25))
                } else if isRecording {
                    Text("REC")
                        .font(.system(size: 7.5, weight: .black, design: .monospaced))
                        .tracking(0.8)
                        .foregroundColor(ReceiptTheme.stampRed)
                }

                Spacer()

                HStack(spacing: 5) {
                    Button(action: onToggleVoice) {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(isRecording ? ReceiptTheme.stampRed : Color(white: 0.24))
                            .frame(width: 16, height: 12)
                    }
                    .buttonStyle(.plain)
                    .help(isRecording ? "停止语音并打印" : "语音输入今日待办")

                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(Color(white: 0.28))
                            .frame(width: 15, height: 12)
                    }
                    .buttonStyle(.plain)
                    .help("设置 API Key 与偏好")

                    Button(action: onToggleExpand) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8.5, weight: .black))
                            .foregroundColor(Color(white: 0.24))
                            .frame(width: 15, height: 12)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "卷回收起小票" : "吐出展开小票")
                }
                .opacity((isHoveringBezel || isRecording || isPrinting) ? 0.95 : 0.42)
                .animation(.easeOut(duration: 0.16), value: isHoveringBezel)
            }
            .padding(.horizontal, 10)
            .padding(.top, 3)
        }
        .frame(width: bezelWidth, height: PrinterSlotMetrics.slotCenterY, alignment: .top)
    }
}
