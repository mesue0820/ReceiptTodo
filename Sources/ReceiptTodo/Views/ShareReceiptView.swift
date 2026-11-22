import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ShareBackdropStyle: String, CaseIterable, Identifiable {
    case warmGray
    case darkDesk
    case transparent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .warmGray: return "浅灰桌面"
        case .darkDesk: return "深色桌面"
        case .transparent: return "纯纸条"
        }
    }
}

/// Pure, gallery-grade torn thermal receipt artwork rendered at 3x for WeChat / Moments / AirDrop sharing.
/// Contains zero working input controls — only the crisp double-serrated check-in slip.
struct ShareableReceiptArtwork: View {
    let receipt: DailyReceipt
    let streakDays: Int
    let backdrop: ShareBackdropStyle
    let completedOnly: Bool

    private let paperWidth: CGFloat = 320

    private var visibleItems: [TodoItem] {
        completedOnly ? receipt.items.filter(\.isDone) : receipt.items
    }

    private var timedItems: [TodoItem] {
        visibleItems
            .filter { $0.scheduledMinutes != nil }
            .sorted { ($0.scheduledMinutes ?? 0) < ($1.scheduledMinutes ?? 0) }
    }

    private var untimedItems: [TodoItem] {
        visibleItems.filter { $0.scheduledMinutes == nil }
    }

    private var completionPercent: Int {
        guard receipt.totalCount > 0 else { return 0 }
        return Int(round(Double(receipt.doneCount) / Double(receipt.totalCount) * 100.0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Subtle check-in top seal
                HStack {
                    Text("CHECK-IN RECEIPT")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundColor(ReceiptTheme.inkMuted)
                    Spacer()
                    if streakDays > 0 {
                        Text("🔥 \(streakDays) DAYS")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(ReceiptTheme.accentWarm)
                    }
                }
                .padding(.top, 22)
                .padding(.bottom, 12)

                // Editorial title
                VStack(spacing: 5) {
                    Text("DAILY RECEIPT")
                        .font(.system(size: 21, weight: .black, design: .rounded))
                        .tracking(2.0)
                        .foregroundColor(ReceiptTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text("TODAY'S TO-DO LIST")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2.2)
                        .foregroundColor(ReceiptTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.bottom, 14)

                // Date & Receipt No.
                VStack(spacing: 3.5) {
                    HStack {
                        Text("DATE:")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(ReceiptTheme.inkMuted)
                        Text(DailyReceipt.displayDate(for: receipt.dateString))
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(ReceiptTheme.inkSecondary)
                        Spacer()
                    }

                    HStack {
                        Text("RECEIPT NO.:")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(ReceiptTheme.inkMuted)
                        Text(receipt.receiptNo)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(ReceiptTheme.inkSecondary)
                        Spacer()
                        if completedOnly {
                            Text("DONE ONLY")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .tracking(0.8)
                                .foregroundColor(ReceiptTheme.inkMuted)
                        }
                    }
                }
                .padding(.bottom, 14)

                // ITEM / TIME rules
                VStack(spacing: 6) {
                    Rectangle()
                        .fill(ReceiptTheme.ink.opacity(0.78))
                        .frame(height: 1.0)
                    HStack {
                        Text("ITEM")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundColor(ReceiptTheme.ink)
                        Spacer()
                        Text("TIME")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundColor(ReceiptTheme.ink)
                    }
                    Rectangle()
                        .fill(ReceiptTheme.ink.opacity(0.78))
                        .frame(height: 1.0)
                }
                .padding(.bottom, 8)

                // Pure tasks list
                if visibleItems.isEmpty {
                    Text(completedOnly ? "* 暂无已完成事项 *" : "* NO ITEMS *")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(ReceiptTheme.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(timedItems.enumerated()), id: \.element.id) { idx, item in
                            shareTaskRow(item)
                            if idx < timedItems.count - 1 {
                                DashedDivider()
                                    .opacity(0.24)
                                    .padding(.vertical, 1)
                            }
                        }

                        if !timedItems.isEmpty && !untimedItems.isEmpty {
                            DashedDivider()
                                .opacity(0.60)
                                .padding(.vertical, 7)
                        }

                        ForEach(Array(untimedItems.enumerated()), id: \.element.id) { idx, item in
                            shareTaskRow(item)
                            if idx < untimedItems.count - 1 {
                                DashedDivider()
                                    .opacity(0.24)
                                    .padding(.vertical, 1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                DashedDivider()
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                // Summary totals + completion stamp
                VStack(spacing: 10) {
                    HStack {
                        Text("TOTAL")
                            .font(.system(size: 11.5, weight: .black, design: .monospaced))
                            .foregroundColor(ReceiptTheme.ink)
                        Spacer()
                        Text("\(receipt.doneCount) / \(receipt.totalCount) DONE · \(completionPercent)%")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(receipt.isAllDone ? ReceiptTheme.stampRed : ReceiptTheme.inkSecondary)
                    }

                    if receipt.isAllDone {
                        StampBadgeView()
                            .padding(.vertical, 3)
                    } else if receipt.doneCount > 0 {
                        CheckInArchivedStampView(percent: completionPercent)
                            .padding(.vertical, 3)
                    }

                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(spacing: 3) {
                            DecorativeBarcodeView(
                                seed: "\(receipt.dateString)-\(receipt.totalCount)-\(receipt.doneCount)",
                                height: 32,
                                barCount: 32
                            )
                            .frame(width: 104)

                            Text(receipt.dateString.replacingOccurrences(of: "-", with: " "))
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .tracking(1.2)
                                .foregroundColor(ReceiptTheme.inkSecondary)
                                .fixedSize()
                        }

                        Spacer(minLength: 4)

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("HAVE A GOOD DAY")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .tracking(0.9)
                                .foregroundColor(ReceiptTheme.inkSecondary)
                                .fixedSize()

                            Text("RECEIPT TODO")
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .tracking(1.4)
                                .foregroundColor(ReceiptTheme.inkMuted.opacity(0.75))
                                .fixedSize()
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.bottom, 22)
            }
            .padding(.horizontal, 24)
            .frame(width: paperWidth)
            .background(
                ThermalPaperSurface()
                    .clipShape(
                        DoubleSerratedReceiptShape(
                            topPinch: 0.8,
                            toothWidth: 13.5,
                            toothHeight: 6.5,
                            topToothHeight: 5.2,
                            topTearProgress: 1.0
                        )
                    )
                    .shadow(
                        color: backdrop == .darkDesk ? Color.black.opacity(0.55) : Color.black.opacity(0.22),
                        radius: 18,
                        x: 0,
                        y: 10
                    )
                    .shadow(color: Color.black.opacity(0.10), radius: 3, x: 0, y: 2)
            )
            .overlay(
                DoubleSerratedReceiptShape(
                    topPinch: 0.8,
                    toothWidth: 13.5,
                    toothHeight: 6.5,
                    topToothHeight: 5.2,
                    topTearProgress: 1.0
                )
                .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
            )
        .padding(.horizontal, 34)
        .padding(.vertical, 34)
        .background(backdropLayer)
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var backdropLayer: some View {
        switch backdrop {
        case .warmGray:
            LinearGradient(
                colors: [
                    Color(red: 0.92, green: 0.915, blue: 0.90),
                    Color(red: 0.85, green: 0.845, blue: 0.83)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .darkDesk:
            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.145, blue: 0.16),
                    Color(red: 0.08, green: 0.085, blue: 0.095)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .transparent:
            Color.clear
        }
    }

    private func shareTaskRow(_ item: TodoItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.isDone ? "[×]" : "[ ]")
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundColor(item.isDone ? ReceiptTheme.stampRed : ReceiptTheme.ink)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: item.isDone ? .regular : .medium))
                    .foregroundColor(item.isDone ? ReceiptTheme.inkSecondary : ReceiptTheme.ink)
                    .strikethrough(item.isDone, color: ReceiptTheme.stampRed.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                if let timeLabel = item.displayTimeLabel {
                    DottedLeaderLine()
                    Text(timeLabel)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundColor(ReceiptTheme.inkMuted)
                        .fixedSize()
                } else {
                    Spacer(minLength: 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7.5)
    }
}

private struct CheckInArchivedStampView: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
            Text("CHECKED IN · 完成 \(percent)%")
                .font(.system(size: 10, weight: .black, design: .monospaced))
        }
        .foregroundColor(ReceiptTheme.ink.opacity(0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 3.5)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(ReceiptTheme.ink.opacity(0.75), lineWidth: 1.4)
        )
        .rotationEffect(.degrees(-4))
    }
}

// MARK: - 3x Retina PNG Renderer & Export Helpers

@MainActor
enum ShareReceiptRenderer {
    static func renderPNG(
        receipt: DailyReceipt,
        streakDays: Int,
        backdrop: ShareBackdropStyle,
        completedOnly: Bool,
        scale: CGFloat = 3.0
    ) -> (image: NSImage, pngData: Data)? {
        let artwork = ShareableReceiptArtwork(
            receipt: receipt,
            streakDays: streakDays,
            backdrop: backdrop,
            completedOnly: completedOnly
        )
        let renderer = ImageRenderer(content: artwork)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        return (nsImage, pngData)
    }

    static func writeTempPNG(pngData: Data, dateString: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("ReceiptTodo-\(dateString).png")
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Frameless Direct-Display Floating Share Poster (Zero Dialog Chrome!)

struct ShareReceiptWindowView: View {
    let receipt: DailyReceipt
    let streakDays: Int
    let canUndoTearOff: Bool
    var isStaticPreview: Bool = false
    let onUndoTearOff: () -> Void
    let onClose: () -> Void

    @State private var backdrop: ShareBackdropStyle = .warmGray
    @State private var completedOnly: Bool = false
    @State private var isHoveringCard: Bool = false
    @State private var copiedState: Bool = false
    @State private var savedState: Bool = false
    @State private var appeared: Bool = false
    @State private var resetFeedbackTask: Task<Void, Never>?

    private var renderedPoster: (image: NSImage, pngData: Data)? {
        ShareReceiptRenderer.renderPNG(
            receipt: receipt,
            streakDays: streakDays,
            backdrop: backdrop,
            completedOnly: completedOnly,
            scale: isStaticPreview ? 2.0 : 3.0
        )
    }

    var body: some View {
        let rendered = renderedPoster
        return VStack(spacing: 14) {
            // 1. Direct, pure, frameless gallery check-in image — 100% WYSIWYG, shown in one full glance!
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = rendered?.image {
                        let fitScale = min(1.0, min(388.0 / max(1.0, img.size.width), 610.0 / max(1.0, img.size.height)))
                        let fittedW = img.size.width * fitScale
                        let fittedH = img.size.height * fitScale
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fittedW, height: fittedH)
                            .background {
                                if backdrop == .transparent {
                                    CheckerboardPreviewBackground()
                                }
                            }
                    } else {
                        ShareableReceiptArtwork(
                            receipt: receipt,
                            streakDays: streakDays,
                            backdrop: backdrop,
                            completedOnly: completedOnly
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            backdrop == .darkDesk ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: Color.black.opacity(0.32), radius: 22, x: 0, y: 12)
                .shadow(color: Color.black.opacity(0.14), radius: 4, x: 0, y: 2)

                // Whisper-subtle close circle (only brightens on hover)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(backdrop == .darkDesk ? .white.opacity(0.88) : Color.black.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(backdrop == .darkDesk ? Color.white.opacity(0.16) : Color.black.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .padding(12)
                .opacity(isHoveringCard ? 1.0 : 0.32)
                .animation(.easeOut(duration: 0.16), value: isHoveringCard)
                .help("关闭 (Esc)")
            }
            .onHover { hovering in
                isHoveringCard = hovering
            }

            // 2. Detached ultra-sleek floating dark glass HUD pill (zero form chrome!)
            HStack(spacing: 10) {
                // 3 tactile backdrop color dots
                HStack(spacing: 6) {
                    backdropDot(.warmGray, fill: Color(red: 0.89, green: 0.88, blue: 0.86), helpText: "浅灰桌面")
                    backdropDot(.darkDesk, fill: Color(red: 0.16, green: 0.17, blue: 0.19), helpText: "深色桌面")
                    backdropDot(.transparent, fill: Color.clear, isTransparent: true, helpText: "透明纯纸条")
                }

                // Privacy filter toggle: only completed items
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        completedOnly.toggle()
                    }
                } label: {
                    Image(systemName: completedOnly ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(completedOnly ? Color(red: 0.34, green: 0.88, blue: 0.56) : .white.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(completedOnly ? "当前：仅展示已完成事项（点击显示全部）" : "点击切换为仅展示已完成事项")

                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 15)

                // Primary 1-click Copy Image pill
                Button {
                    copyImageToClipboard()
                } label: {
                    HStack(spacing: 4.5) {
                        Image(systemName: copiedState ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .bold))
                        Text(copiedState ? "已复制" : "复制图片")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundColor(copiedState ? .white : ReceiptTheme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 27)
                    .background(copiedState ? Color(red: 0.16, green: 0.68, blue: 0.38) : Color.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("复制高清图片，直接 ⌘V 粘贴到微信/朋友圈")

                // Save PNG icon
                Button {
                    savePNGToDisk()
                } label: {
                    Image(systemName: savedState ? "checkmark" : "arrow.down.to.line")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(savedState ? Color(red: 0.34, green: 0.88, blue: 0.56) : .white.opacity(0.88))
                        .frame(width: 27, height: 27)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("保存为 3x 高清 PNG")

                // Native macOS Share / AirDrop icon
                if isStaticPreview {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                        .frame(width: 27, height: 27)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                } else {
                    NativeShareIconButton {
                        guard let rendered = ShareReceiptRenderer.renderPNG(
                            receipt: receipt,
                            streakDays: streakDays,
                            backdrop: backdrop,
                            completedOnly: completedOnly
                        ),
                        let fileURL = ShareReceiptRenderer.writeTempPNG(pngData: rendered.pngData, dateString: receipt.dateString) else {
                            return []
                        }
                        return [fileURL]
                    }
                    .frame(width: 27, height: 27)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
                    .help("隔空投送 / 系统分享")
                }

                if canUndoTearOff {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: 15)

                    Button {
                        onUndoTearOff()
                        onClose()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("撤销撕下，恢复今日小票")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color(red: 0.11, green: 0.115, blue: 0.13).opacity(0.92))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.75)
                    )
                    .shadow(color: Color.black.opacity(0.32), radius: 14, x: 0, y: 6)
            )
        }
        .padding(24) // Generous transparent shadow padding so floating drop shadows never clip
        .scaleEffect(isStaticPreview || appeared ? 1.0 : 0.94)
        .opacity(isStaticPreview || appeared ? 1.0 : 0.0)
        .onAppear {
            guard !isStaticPreview else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) {
                appeared = true
            }
        }
    }

    private func backdropDot(
        _ style: ShareBackdropStyle,
        fill: Color,
        isTransparent: Bool = false,
        helpText: String
    ) -> some View {
        let selected = backdrop == style
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                backdrop = style
            }
        } label: {
            ZStack {
                if isTransparent {
                    CheckerboardPreviewBackground()
                        .frame(width: 14, height: 14)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(fill)
                        .frame(width: 14, height: 14)
                }

                Circle()
                    .stroke(selected ? Color.white : Color.white.opacity(0.35), lineWidth: selected ? 1.8 : 0.8)
                    .frame(width: selected ? 17 : 14, height: selected ? 17 : 14)
            }
            .frame(width: 19, height: 19)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private func copyImageToClipboard() {
        guard let rendered = ShareReceiptRenderer.renderPNG(
            receipt: receipt,
            streakDays: streakDays,
            backdrop: backdrop,
            completedOnly: completedOnly
        ) else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(rendered.pngData, forType: .png)
        if let tiff = rendered.image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        flashFeedback(copied: true)
    }

    private func savePNGToDisk() {
        guard let rendered = ShareReceiptRenderer.renderPNG(
            receipt: receipt,
            streakDays: streakDays,
            backdrop: backdrop,
            completedOnly: completedOnly
        ) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "ReceiptTodo-\(receipt.dateString).png"
        panel.title = "保存今日打卡小票"
        panel.canCreateDirectories = true

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? rendered.pngData.write(to: url, options: .atomic)
            flashFeedback(copied: false)
        }
    }

    private func flashFeedback(copied: Bool) {
        resetFeedbackTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            copiedState = copied
            savedState = !copied
        }
        resetFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.22)) {
                    copiedState = false
                    savedState = false
                }
            }
        }
    }
}

private struct CheckerboardPreviewBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 6
            let rows = Int(ceil(size.height / cell))
            let cols = Int(ceil(size.width / cell))
            for r in 0..<rows {
                for c in 0..<cols {
                    let isDark = (r + c) % 2 == 0
                    ctx.fill(
                        Path(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell)),
                        with: .color(isDark ? Color.black.opacity(0.14) : Color.white.opacity(0.82))
                    )
                }
            }
        }
    }
}

/// Borderless icon-only macOS `NSSharingServicePicker` trigger so AirDrop / Messages opens right from the floating HUD pill.
private struct NativeShareIconButton: NSViewRepresentable {
    let itemsProvider: () -> [Any]

    func makeCoordinator() -> Coordinator {
        Coordinator(itemsProvider: itemsProvider)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.title = ""
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "分享")
        button.contentTintColor = NSColor.white.withAlphaComponent(0.90)
        button.target = context.coordinator
        button.action = #selector(Coordinator.showPicker(_:))
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.itemsProvider = itemsProvider
    }

    @MainActor
    final class Coordinator: NSObject {
        var itemsProvider: () -> [Any]

        init(itemsProvider: @escaping () -> [Any]) {
            self.itemsProvider = itemsProvider
        }

        @objc func showPicker(_ sender: NSButton) {
            let items = itemsProvider()
            guard !items.isEmpty else { return }
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
