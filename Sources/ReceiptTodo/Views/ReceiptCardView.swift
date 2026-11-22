import AppKit
import SwiftUI

struct RootWidgetView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var speech: SpeechService

    private var anchorAlignment: Alignment {
        store.isAnchoredLeft ? .topLeading : .topTrailing
    }

    var body: some View {
        ZStack(alignment: anchorAlignment) {
            if store.isExpanded {
                ReceiptCardView(store: store, speech: speech)
            } else {
                CollapsedPillView(store: store, speech: speech)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchorAlignment)
        .background(Color.clear)
        .contextMenu {
            Button(store.isExpanded ? "收起小票" : "展开小票") {
                store.toggleExpanded()
            }
            Button(
                speech.isRecording
                    ? "停止录音并打印"
                    : (store.settings.globalHotkeyEnabled
                        ? "语音输入今日待办 (\(store.settings.globalHotkey.displaySymbols))"
                        : "语音输入今日待办")
            ) {
                store.toggleVoiceRecording()
            }
            Button("AI 一键整理当前待办") {
                Task { await store.reorganizePendingWithAI() }
            }
            if store.receipt.doneCount > 0 {
                Button("复制已完成事项 (日报/周报)") {
                    store.copyCompletedToClipboard()
                }
            }
            if !store.receipt.items.isEmpty {
                Button("生成打卡分享图...") {
                    store.openShareCardForCurrentReceipt()
                }
            }
            Button("重新吐纸打印效果") {
                store.replayPrintAnimation()
            }
            if store.canTearOffCurrentReceipt {
                Button("结束今日 · 撕下小票") {
                    store.triggerAnimatedTearOff()
                }
            }
            if store.isTodayTornOff {
                Button("撤销撕下 · 恢复今日小票") {
                    store.undoTearOffToday()
                }
            }
            Divider()
            Button("设置语音引擎与 API Key...") {
                store.openSettings()
            }
            Button("回到右上角默认位置") {
                store.resetWindowPosition()
            }
            Divider()
            Button("退出小票待办") {
                NSApp.terminate(nil)
            }
        }
    }
}

private struct PaperHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 520
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ReceiptCardView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var speech: SpeechService

    @State private var newTaskTitle: String = ""
    @State private var editingItemID: UUID?
    @State private var editingDraft: String = ""
    @State private var measuredPaperHeight: CGFloat = 520
    @State private var isHoveringBezel: Bool = false
    @State private var isHoveringTearHandle: Bool = false
    @State private var isActivelyDraggingTear: Bool = false

    private let bezelWidth = PrinterSlotMetrics.expandedBezelWidth
    private let slotWidth = PrinterSlotMetrics.expandedSlotWidth
    private let paperWidth = PrinterSlotMetrics.expandedPaperWidth

    private var verticalFeedOffset: CGFloat {
        let clamped = max(0.0, min(1.02, store.paperReveal))
        return -(1.0 - clamped) * measuredPaperHeight
    }

    /// Gentle, non-violent physical downward travel:
    /// right-hand untorn corner stays closely anchored to the cutter slit until detachment,
    /// while the torn left edge opens cleanly downward; after full tear, drifts peacefully down.
    private var tearVerticalOffset: CGFloat {
        let tension = min(store.tearPullDistance, 22.0) * 0.16
        let peelDrop = store.tearProgress * 5.5
        let driftDrop = store.tearDriftProgress * 78.0
        return tension + peelDrop + driftDrop
    }

    /// Subtle leftward compensation while tilting so the bottom-right serrated corner never clips the viewport
    private var tearHorizontalOffset: CGFloat {
        -(store.tearProgress * 11.0 + store.tearDriftProgress * 8.0)
    }

    /// Gentle hinge pivot around the still-attached top-right cutter edge
    private var tearTiltDegrees: Double {
        -(Double(store.tearProgress) * 2.8 + Double(store.tearDriftProgress) * 2.6)
    }

    private var paperOpacity: Double {
        max(0.0, 1.0 - Double(store.tearDriftProgress))
    }

    private var remnantStubOpacity: Double {
        guard store.tearProgress > 0.03 else { return 0.0 }
        return max(0.0, 1.0 - Double(store.tearDriftProgress) * 1.55)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // LAYER 1 (Back): Complete brushed-silver printer bezel + center black slot + lower lip
            PrinterSlotBackLayer(bezelWidth: bezelWidth, slotWidth: slotWidth)
                .zIndex(1)

            // LAYER 2 (Middle): Paper Viewport anchored at EXACT center of the dark slit
            ZStack(alignment: .top) {
                // Matching tiny serrated remnant stub staying inside the cutter slit as the receipt peels away
                if store.tearProgress > 0.03 {
                    SlotRemnantStubView(width: paperWidth, tearProgress: store.tearProgress)
                        .offset(y: -store.tearDriftProgress * 11.0)
                        .opacity(remnantStubOpacity)
                        .zIndex(1)
                }

                Group {
                    if let focused = store.focusedItem {
                        focusLockPaperStrip(focused)
                    } else if store.isShowingPostTearStub {
                        postTearRestStubPaper
                    } else {
                        paperStripContent
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: PaperHeightKey.self, value: geo.size.height)
                    }
                )
                .rotationEffect(.degrees(store.paperNudgeAngle), anchor: .top)
                .rotationEffect(.degrees(tearTiltDegrees), anchor: .topTrailing)
                .offset(x: tearHorizontalOffset, y: verticalFeedOffset + tearVerticalOffset)
                .opacity(paperOpacity)
                .rotation3DEffect(
                    .degrees(store.isPrinting ? 3.0 : 0.0),
                    axis: (x: 1, y: 0, z: 0),
                    anchor: .top,
                    perspective: 0.45
                )
                .animation(.spring(response: 0.34, dampingFraction: 0.64), value: store.isPrinting)
                .padding(.bottom, (store.isShowingPostTearStub || store.focusedItem != nil) ? 16 : 76)
                .zIndex(2)

                SlotContactShadow()
                    .frame(width: paperWidth - 4)
                    .opacity(store.paperReveal > 0.01 ? max(0.0, 1.0 - Double(store.tearDriftProgress) * 1.4) : 0.0)
                    .zIndex(3)
            }
            .frame(width: bezelWidth, alignment: .top)
            .clipped()
            .padding(.top, PrinterSlotMetrics.slotCenterY)
            .zIndex(5)
            .onPreferenceChange(PaperHeightKey.self) { height in
                if height > 80 {
                    measuredPaperHeight = height
                }
            }

            // LAYER 3 (Front, upper half only): Hardware LED & discreet rim controls
            PrinterSlotUpperOverlay(
                bezelWidth: bezelWidth,
                isRecording: speech.isRecording,
                isPrinting: store.isPrinting,
                hasReminder: store.activeReminderItem != nil,
                isExpanded: true,
                isHoveringBezel: isHoveringBezel,
                isClosedForDay: store.isTodayTornOff,
                isFocusing: store.focusedItem != nil,
                lampStyle: store.bezelLampStyle,
                statusLabel: nil,
                onToggleExpand: {
                    if store.focusedItem != nil {
                        store.exitFocusMode()
                    } else {
                        store.collapseToSlot()
                    }
                },
                onToggleVoice: { store.toggleVoiceRecording() },
                onOpenSettings: { store.openSettings() }
            )
            .onHover { hovering in
                isHoveringBezel = hovering
            }
            .zIndex(10)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Physical Hanging Thermal Paper Strip (Airy Editorial Receipt Layout + Serrated Hem)

    private var paperStripContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Design A: Inverted carbon-black thermal reminder strip (only when a scheduled task is due!)
            if let reminder = store.activeReminderItem {
                InvertedThermalReminderStrip(
                    item: reminder,
                    onComplete: { store.completeActiveReminder() },
                    onSnooze: { store.snoozeActiveReminder(minutes: 10) },
                    onDismiss: { store.dismissActiveReminder() }
                )
                .padding(.top, 18)
                .padding(.bottom, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Generous airy breathing room below the slot contact shadow
            receiptHeaderSection
                .padding(.top, store.activeReminderItem == nil ? 22 : 2)
                .padding(.bottom, 14)

            // Clean structured receipt metadata block
            metadataSection
                .padding(.bottom, 14)

            // Editorial column header: ITEM / TIME framed by crisp thin rules
            columnHeaderSection
                .padding(.bottom, 6)

            if store.isViewingActiveDay && !store.carryOverCandidates.isEmpty {
                carryOverSection
                    .padding(.vertical, 8)
            }

            // Breathable todo items list
            todoListSection
                .padding(.vertical, 4)

            // Live voice recording or AI parsing status tray
            if speech.isRecording {
                recordingTray
                    .padding(.top, 12)
            } else if store.isParsingVoice {
                parsingTray
                    .padding(.top, 12)
            }

            if let err = store.aiErrorBanner {
                aiErrorCard(err)
                    .padding(.top, 10)
            }

            if let toast = store.toastMessage {
                toastBanner(toast)
                    .padding(.top, 10)
            }

            // Active day (Today or Tomorrow): spacious input & voice bar; Archive: share card + restore + return
            if store.isViewingActiveDay {
                composerSection
                    .padding(.top, 14)
            } else {
                archiveReturnSection
                    .padding(.top, 14)
            }

            DashedDivider()
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Airy footer with totals, barcode + serial digits, and breathing room above sawtooth hem
            let showBottomTearCue = store.isViewingToday && !store.isTodayTornOff && !store.receipt.items.isEmpty
            footerSection
                .padding(.bottom, (showBottomTearCue || store.isViewingTomorrow) ? 10 : 22)

            // Active today: discreet tactile bottom-hem pull-to-tear handle
            if showBottomTearCue {
                tearOffHandleSection
                    .padding(.bottom, 10)
            } else if store.isViewingTomorrow {
                tomorrowFooterNote
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 24) // Wide editorial margins for real receipt breathing room!
        .frame(width: paperWidth)
        .background(
            ThermalPaperSurface()
                .clipShape(
                    DoubleSerratedReceiptShape(
                        topPinch: 1.6,
                        toothWidth: 13.5,
                        toothHeight: 6.5,
                        topToothHeight: 4.8,
                        topTearProgress: store.tearProgress
                    )
                )
                .shadow(color: Color.black.opacity(0.28), radius: 13, x: 0, y: 8)
                .shadow(color: Color.black.opacity(0.14), radius: 2.5, x: 0, y: 2)
        )
        .overlay(
            DoubleSerratedReceiptShape(
                topPinch: 1.6,
                toothWidth: 13.5,
                toothHeight: 6.5,
                topToothHeight: 4.8,
                topTearProgress: store.tearProgress
            )
            .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
        )
        .overlay(alignment: .top) {
            if store.tearPullDistance > 2 && store.tearProgress < 0.99 {
                PerforationSeamLine(
                    tearProgress: store.tearProgress,
                    tensionOpacity: min(1.0, Double(store.tearPullDistance) / 18.0)
                )
                .padding(.horizontal, 2)
                .padding(.top, 1)
            }
        }
        .padding(.bottom, 18) // Space inside viewport so serrated shadow never clips
    }

    // MARK: - Subtle Tactile Bottom-Hem Pull-to-Tear Handle

    private var tearHandleLabel: String {
        if isActivelyDraggingTear || store.tearPullDistance > 2 {
            if store.tearProgress >= 0.70 {
                return "松手即可撕下归档"
            } else if store.tearProgress > 0.05 {
                return "正在沿齿线撕开 · \(Int(store.tearProgress * 100))%"
            } else {
                return "继续轻拉 · 沿齿线撕开"
            }
        }
        return "下拉撕下今日小票"
    }

    private var tearOffHandleSection: some View {
        let active = isActivelyDraggingTear || store.tearPullDistance > 2
        let ready = store.tearProgress >= 0.70

        return ZStack {
            VStack(spacing: 4) {
                // Delicate grip bar / progressive hairline indicator
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ReceiptTheme.ink.opacity(active ? 0.14 : (isHoveringTearHandle ? 0.24 : 0.12)))
                        .frame(width: active ? 64 : 26, height: 2.5)

                    if active && store.tearProgress > 0.01 {
                        Capsule()
                            .fill(ready ? ReceiptTheme.ink : ReceiptTheme.inkSecondary)
                            .frame(width: 64 * max(0.05, min(1.0, store.tearProgress)), height: 2.5)
                    }
                }
                .animation(.easeOut(duration: 0.16), value: active)

                HStack(spacing: 3.5) {
                    if !active {
                        Image(systemName: "chevron.compact.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(ReceiptTheme.inkMuted.opacity(isHoveringTearHandle ? 0.85 : 0.45))
                    }
                    Text(tearHandleLabel)
                        .font(.system(size: 9.5, weight: ready ? .bold : .medium, design: .monospaced))
                        .foregroundColor(
                            ready
                                ? ReceiptTheme.ink
                                : (active || isHoveringTearHandle ? ReceiptTheme.inkSecondary : ReceiptTheme.inkMuted.opacity(0.62))
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())

            // AppKit NSView capture layer: guarantees mouseDownCanMoveWindow = false so pulling NEVER drags the NSPanel!
            if !store.isRenderingStaticPreview {
                PullToTearMouseCaptureView(
                    isEnabled: store.canTearOffCurrentReceipt,
                    onHoverChanged: { hovering in
                        withAnimation(.easeOut(duration: 0.16)) {
                            isHoveringTearHandle = hovering
                        }
                    },
                    onActiveChanged: { dragging in
                        isActivelyDraggingTear = dragging
                    },
                    onPullChanged: { dy in
                        store.updateManualTear(pullDistance: dy)
                    },
                    onPullEnded: { dy in
                        store.finishManualTear(pullDistance: dy)
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            }
        }
        .padding(.horizontal, -8)
        .help("按住此处轻轻向下拉，可沿顶部齿线撕下今日小票")
    }

    // MARK: - Focus Lock Mode: High-Contrast Single-Task Black Thermal Strip

    private func focusLockPaperStrip(_ item: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: 0.90, green: 0.24, blue: 0.18))
                    .frame(width: 6.5, height: 6.5)

                Text("正在死磕")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(Color.white.opacity(0.75))

                if let timeLabel = item.displayTimeLabel {
                    Text("· \(timeLabel)")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(store.isItemDue(item) ? Color(red: 0.96, green: 0.36, blue: 0.30) : Color.white.opacity(0.60))
                }

                Spacer()

                Text(store.formattedFocusElapsed)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.top, 18)

            Text(item.title)
                .font(.system(size: 15.5, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)

            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(height: 1)
                .padding(.vertical, 11)

            HStack(spacing: 12) {
                Button {
                    store.completeFocusedItem()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10.5, weight: .black))
                        Text("划掉完成")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundColor(ReceiptTheme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 27)
                    .background(Color.white)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    store.exitFocusMode()
                } label: {
                    Text("退出专注")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.62))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 22)
        .frame(width: paperWidth)
        .background(
            Color(red: 0.085, green: 0.088, blue: 0.095)
                .clipShape(ThermalReceiptShape(topPinch: 1.6, toothWidth: 13.5, toothHeight: 6.5))
                .shadow(color: Color.black.opacity(0.34), radius: 14, x: 0, y: 8)
                .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 2)
        )
        .overlay(
            ThermalReceiptShape(topPinch: 1.6, toothWidth: 13.5, toothHeight: 6.5)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
        )
        .padding(.bottom, 12)
    }

    // MARK: - Post-Tear Serene Compact "NEXT ROLL" Stub (After Today Is Torn Off)

    private var postTearRestStubPaper: some View {
        let shortToday = store.todayDateString.suffix(5).replacingOccurrences(of: "-", with: ".")
        let allDone = store.tornOffTodayTotalCount > 0 && store.tornOffTodayDoneCount == store.tornOffTodayTotalCount

        return VStack(spacing: 0) {
            // Calm fresh-roll header
            VStack(spacing: 5) {
                Text("NEXT ROLL")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(2.2)
                    .foregroundColor(ReceiptTheme.inkMuted)

                HStack(spacing: 6) {
                    Button {
                        store.goToPreviousDate()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(store.canGoPreviousDate ? ReceiptTheme.inkSecondary : ReceiptTheme.inkMuted.opacity(0.3))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canGoPreviousDate)
                    .help("翻看今日已撕下的小票")

                    Text(DailyReceipt.displayDate(for: store.receipt.dateString))
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundColor(ReceiptTheme.ink)

                    Color.clear.frame(width: 16, height: 16)
                }
            }
            .padding(.top, 22)
            .padding(.bottom, 13)

            DashedDivider()
                .opacity(0.55)
                .padding(.bottom, 12)

            // Quiet single-line completion summary for today
            HStack {
                Text("今日已收官 · \(shortToday)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(ReceiptTheme.inkSecondary)
                Spacer()
                Text("\(store.tornOffTodayDoneCount) / \(store.tornOffTodayTotalCount) DONE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(allDone ? ReceiptTheme.stampRed : ReceiptTheme.inkSecondary)
            }
            .padding(.bottom, 14)

            // Quiet, balanced 3-action bar: Start Tomorrow / View Share Card / Restore Today
            HStack(spacing: 10) {
                Button {
                    store.startPlanningTomorrow()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("写明天")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(ReceiptTheme.ink)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("展开明日空白小票，提前规划明天安排")

                Spacer(minLength: 4)

                Button {
                    store.openShareCardForTornOffToday()
                } label: {
                    Text("[ 打卡图 ]")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(ReceiptTheme.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("再次展示今日打卡分享图")

                Button {
                    store.undoTearOffToday()
                } label: {
                    Text("[ 恢复今日 ]")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(ReceiptTheme.inkMuted)
                }
                .buttonStyle(.plain)
                .help("撤销撕下，恢复今日小票")
            }
            .padding(.bottom, 22)
        }
        .padding(.horizontal, 24)
        .frame(width: paperWidth)
        .background(
            ThermalPaperSurface()
                .clipShape(ThermalReceiptShape(topPinch: 1.6, toothWidth: 13.5, toothHeight: 6.5))
                .shadow(color: Color.black.opacity(0.24), radius: 11, x: 0, y: 6)
                .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1.5)
        )
        .overlay(
            ThermalReceiptShape(topPinch: 1.6, toothWidth: 13.5, toothHeight: 6.5)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
        )
        .padding(.bottom, 14)
    }

    // MARK: - Editorial Header

    private var receiptHeaderSection: some View {
        VStack(spacing: 6) {
            Text("DAILY RECEIPT")
                .font(.system(size: 21, weight: .black, design: .rounded))
                .tracking(2.0)
                .foregroundColor(ReceiptTheme.ink)
                .frame(maxWidth: .infinity, alignment: .center)

            if store.isViewingTomorrow {
                Text("TOMORROW · 明日预备")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(ReceiptTheme.ink)
                    .cornerRadius(2)
            } else {
                Text("TODAY'S TO-DO LIST")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.2)
                    .foregroundColor(ReceiptTheme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var tomorrowFooterNote: some View {
        HStack(spacing: 6) {
            Text("明日预备页 · 零点自动切为今日")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundColor(ReceiptTheme.inkMuted.opacity(0.72))
            Spacer()
            Button("恢复今日") {
                store.undoTearOffToday()
            }
            .buttonStyle(.plain)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(ReceiptTheme.inkSecondary)
            .help("撤销今日撕票，恢复今日小票")
        }
        .padding(.top, 2)
    }

    // MARK: - Metadata Block (Clean Spaced Receipt Info + History Paging)

    private var metadataSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Text("DATE:")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(ReceiptTheme.inkMuted)

                Button {
                    store.goToPreviousDate()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(store.canGoPreviousDate ? ReceiptTheme.ink : ReceiptTheme.inkMuted.opacity(0.35))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!store.canGoPreviousDate)
                .help("查看上一天小票")

                Text(DailyReceipt.displayDate(for: store.receipt.dateString))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(ReceiptTheme.inkSecondary)

                Button {
                    store.goToNextDate()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(store.canGoNextDate ? ReceiptTheme.ink : ReceiptTheme.inkMuted.opacity(0.35))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!store.canGoNextDate)
                .help("查看下一天小票")

                Spacer()

                if !store.isViewingActiveDay {
                    Button(store.isTodayTornOff ? "[ 明日 ]" : "[ 今日 ]") {
                        store.goToActiveDay()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(ReceiptTheme.ink)
                } else if store.streakDays > 0 {
                    Text("🔥 \(store.streakDays) DAYS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(ReceiptTheme.accentWarm)
                }
            }

            HStack {
                Text("RECEIPT NO.:")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(ReceiptTheme.inkMuted)
                Text(store.receipt.receiptNo)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(ReceiptTheme.inkSecondary)
                Spacer()
                if store.isViewingTomorrow {
                    Text("TOMORROW")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundColor(ReceiptTheme.inkSecondary)
                } else if store.isViewingTornOffTodayArchive {
                    Text("TORN OFF")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundColor(ReceiptTheme.inkMuted)
                } else if !store.isViewingActiveDay {
                    Text("ARCHIVE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundColor(ReceiptTheme.inkMuted)
                }
            }
        }
    }

    // MARK: - Column Header (ITEM / TIME)

    private var columnHeaderSection: some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(ReceiptTheme.ink.opacity(0.75))
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
                .fill(ReceiptTheme.ink.opacity(0.75))
                .frame(height: 1.0)
        }
    }

    // MARK: - Minimalist Carry-Over Card (Cross-Weekend + Selective Picker)

    private var carryOverSection: some View {
        let shortSource = (store.carryOverSourceDate ?? "").suffix(5).replacingOccurrences(of: "-", with: ".")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("结余 \(store.carryOverCandidates.count) 项")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundColor(ReceiptTheme.ink)
                    .fixedSize()
                if !shortSource.isEmpty {
                    Text(shortSource)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(ReceiptTheme.inkMuted)
                        .fixedSize()
                }
                Spacer(minLength: 4)

                if !store.isCarryOverPickerOpen {
                    Button("[全部顺延]") {
                        store.rolloverAllCarryOver()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(ReceiptTheme.ink)
                    .fixedSize()

                    Button("挑选") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.isCarryOverPickerOpen = true
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(ReceiptTheme.inkSecondary)
                    .fixedSize()
                }

                Button("放下") {
                    store.dismissCarryOver()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(ReceiptTheme.inkMuted)
                .fixedSize()
            }

            if store.isCarryOverPickerOpen {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.carryOverCandidates) { item in
                        let checked = store.selectedCarryOverIDs.contains(item.id)
                        Button {
                            store.toggleCarryOverSelection(item.id)
                        } label: {
                            HStack(spacing: 6) {
                                Text(checked ? "[×]" : "[ ]")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(checked ? ReceiptTheme.ink : ReceiptTheme.inkMuted)
                                Text(item.title)
                                    .font(.system(size: 12))
                                    .foregroundColor(checked ? ReceiptTheme.ink : ReceiptTheme.inkMuted)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)

                HStack {
                    Spacer()
                    Button("收起") {
                        withAnimation(.easeOut(duration: 0.18)) {
                            store.isCarryOverPickerOpen = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundColor(ReceiptTheme.inkMuted)

                    Button("顺延所选 (\(store.selectedCarryOverIDs.count))") {
                        store.confirmCarryOverSelected()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(ReceiptTheme.ink)
                    .cornerRadius(4)
                    .disabled(store.selectedCarryOverIDs.isEmpty)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.035))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(ReceiptTheme.dashLine.opacity(0.6), style: StrokeStyle(lineWidth: 0.9, dash: [3, 2.5]))
        )
    }

    private var archiveReturnSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.goToActiveDay()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.left")
                            .font(.system(size: 10.5, weight: .bold))
                        Text(store.isTodayTornOff ? "返回明日小票" : "返回今日小票")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(ReceiptTheme.ink)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)

                if !store.receipt.items.isEmpty {
                    Button {
                        store.openShareCardForCurrentReceipt()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("打卡图")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundColor(ReceiptTheme.ink)
                        .padding(.horizontal, 11)
                        .frame(height: 34)
                        .background(ReceiptTheme.paperSubtle)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help("生成该日小票的打卡分享图")
                }
            }

            if store.isViewingTornOffTodayArchive {
                Button {
                    store.undoTearOffToday()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("撤销撕下 · 恢复为今日小票")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundColor(ReceiptTheme.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Color.black.opacity(0.04))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Todo List (Generous Spacing + Delicate Dashed Hairlines)

    private var todoListSection: some View {
        Group {
            if store.receipt.items.isEmpty {
                VStack(spacing: 7) {
                    Text("* NO ITEMS YET *")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .tracking(1.0)
                        .foregroundColor(ReceiptTheme.inkSecondary)
                    Text("在下方输入新待办，或点「语音输入」直接说")
                        .font(.system(size: 11.5))
                        .foregroundColor(ReceiptTheme.inkMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else if store.receipt.items.count <= 6 {
                todoRowsStack
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        todoRowsStack
                    }
                    .frame(height: 260)
                    .onChange(of: store.receipt.items.count) { oldCount, newCount in
                        if newCount > oldCount, let targetID = store.newlyAddedIDs.first ?? store.receipt.items.last?.id {
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(targetID, anchor: .center)
                            }
                        }
                    }
                    .onAppear {
                        if let lastID = store.receipt.items.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var todoRowsStack: some View {
        let timed = store.timedItems
        let untimed = store.untimedItems

        return VStack(alignment: .leading, spacing: 0) {
            // Upper Zone: Timed schedule sorted chronologically with dotted leaders ("………… 12:00")
            ForEach(Array(timed.enumerated()), id: \.element.id) { idx, item in
                TodoRowView(
                    item: item,
                    isDue: store.isItemDue(item),
                    overdueLabel: store.overdueCompactLabel(for: item),
                    emphasizeCarryOver: store.settings.pushUrgeEnabled,
                    isViewingToday: store.isViewingActiveDay,
                    isHighlighted: store.newlyAddedIDs.contains(item.id),
                    isEditing: editingItemID == item.id,
                    editingDraft: $editingDraft,
                    onToggle: { store.toggleItem(item.id) },
                    onFocus: { store.startFocusing(on: item) },
                    onBeginEdit: {
                        editingItemID = item.id
                        if let t = item.displayTimeLabel {
                            editingDraft = "\(t) \(item.title)"
                        } else {
                            editingDraft = item.title
                        }
                    },
                    onCommitEdit: {
                        store.updateItemTitle(item.id, newTitle: editingDraft)
                        editingItemID = nil
                    },
                    onCancelEdit: {
                        editingItemID = nil
                    },
                    onClearTime: { store.clearItemSchedule(item.id) },
                    onBringToToday: { store.copyArchiveItemToToday(item) },
                    onDelete: { store.deleteItem(item.id) }
                )
                .id(item.id)

                if idx < timed.count - 1 {
                    DashedDivider()
                        .opacity(0.24)
                        .padding(.vertical, 1)
                }
            }

            // Clean dashed hairline separating timed schedule from untimed tasks
            if !timed.isEmpty && !untimed.isEmpty {
                DashedDivider()
                    .opacity(0.65)
                    .padding(.vertical, 8)
            }

            // Lower Zone: Untimed todos
            ForEach(Array(untimed.enumerated()), id: \.element.id) { idx, item in
                TodoRowView(
                    item: item,
                    isDue: false,
                    overdueLabel: nil,
                    emphasizeCarryOver: store.settings.pushUrgeEnabled,
                    isViewingToday: store.isViewingActiveDay,
                    isHighlighted: store.newlyAddedIDs.contains(item.id),
                    isEditing: editingItemID == item.id,
                    editingDraft: $editingDraft,
                    onToggle: { store.toggleItem(item.id) },
                    onFocus: { store.startFocusing(on: item) },
                    onBeginEdit: {
                        editingItemID = item.id
                        editingDraft = item.title
                    },
                    onCommitEdit: {
                        store.updateItemTitle(item.id, newTitle: editingDraft)
                        editingItemID = nil
                    },
                    onCancelEdit: {
                        editingItemID = nil
                    },
                    onClearTime: { store.clearItemSchedule(item.id) },
                    onBringToToday: { store.copyArchiveItemToToday(item) },
                    onDelete: { store.deleteItem(item.id) }
                )
                .id(item.id)

                if idx < untimed.count - 1 {
                    DashedDivider()
                        .opacity(0.24)
                        .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - Voice Recording & Parsing Trays

    private var recordingTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ReceiptTheme.stampRed)
                    .frame(width: 7, height: 7)
                Text(store.settings.speechEngine == .doubao ? "豆包语音聆听中..." : "正在聆听今日安排...")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(ReceiptTheme.stampRed)
                Spacer()
                HStack(alignment: .center, spacing: 2.2) {
                    ForEach(Array(speech.audioLevels.enumerated()), id: \.offset) { _, lvl in
                        Capsule()
                            .fill(ReceiptTheme.stampRed.opacity(0.85))
                            .frame(width: 2.4, height: max(3, lvl * 16))
                    }
                }
                .frame(height: 16)
                .animation(.easeOut(duration: 0.08), value: speech.audioLevels)
            }

            Text(speech.liveTranscript.isEmpty ? "请说出今天要做的事，说完点「整理并打印」..." : speech.liveTranscript)
                .font(.system(size: 12.5))
                .foregroundColor(speech.liveTranscript.isEmpty ? ReceiptTheme.inkMuted : ReceiptTheme.ink)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("取消") {
                    store.cancelVoiceRecording()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(ReceiptTheme.inkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.88))
                .cornerRadius(5)

                Spacer()

                Button {
                    Task { await store.finishVoiceAndOrganize() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "printer.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("整理并出纸打印")
                            .font(.system(size: 11.5, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ReceiptTheme.ink)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(11)
        .background(ReceiptTheme.stampRed.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(ReceiptTheme.stampRed.opacity(0.30), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    private var parsingTray: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
            Text(store.settings.hasAPIKey ? "AI 排版中，即将出纸..." : "正在整理，即将出纸...")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundColor(ReceiptTheme.inkSecondary)
            Spacer()
        }
        .padding(10)
        .background(ReceiptTheme.paperSubtle)
        .cornerRadius(6)
    }

    private func aiErrorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI 整理未成功")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(ReceiptTheme.stampRed)
                Spacer()
                Button("关闭") {
                    store.dismissAIError()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(ReceiptTheme.inkMuted)
            }

            Text(message)
                .font(.system(size: 10.5))
                .foregroundColor(ReceiptTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let raw = store.lastFailedTranscript, !raw.isEmpty {
                Text("已保留原文：\(raw)")
                    .font(.system(size: 10))
                    .foregroundColor(ReceiptTheme.inkSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Button("去设置检查") {
                    store.openSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(ReceiptTheme.ink)
                .cornerRadius(4)

                if store.lastFailedTranscript != nil {
                    Button("重试 AI 整理") {
                        Task { await store.retryLastFailedTranscript() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(ReceiptTheme.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.9))
                    .cornerRadius(4)
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(ReceiptTheme.stampRed.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(ReceiptTheme.stampRed.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(5)
    }

    private func toastBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(ReceiptTheme.ink)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReceiptTheme.highlightBg)
            .cornerRadius(5)
    }

    // MARK: - Spacious, Comfortable Input & Voice Composer

    private var composerSection: some View {
        let canSubmit = !newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 8) {
            // Full-width generous text input box (static "+" icon — zero @FocusState flicker!)
            HStack(spacing: 7) {
                Text("+")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(ReceiptTheme.inkMuted)

                if store.isRenderingStaticPreview {
                    Text(store.isViewingTomorrow ? "提前记一条明日待办，按回车添加..." : "输入一条新待办，按回车添加...")
                        .font(.system(size: 13.5))
                        .foregroundColor(ReceiptTheme.inkMuted.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                } else {
                    TextField(store.isViewingTomorrow ? "提前记一条明日待办，按回车添加..." : "输入一条新待办，按回车添加...", text: $newTaskTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .foregroundColor(ReceiptTheme.ink)
                        .onSubmit {
                            submitManualTask()
                        }
                }

                Button {
                    submitManualTask()
                } label: {
                    Text("添加")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(canSubmit ? .white : ReceiptTheme.inkMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(canSubmit ? ReceiptTheme.ink : ReceiptTheme.paperSubtle)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .help("添加待办并出纸")
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(Color.white.opacity(0.78))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.black.opacity(0.16), lineWidth: 1.0)
            )
            .cornerRadius(6)

            // Prominent comfortable Voice button bar
            Button {
                store.toggleVoiceRecording()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 11.5, weight: .bold))
                    Text(speech.isRecording ? "停止录音并整理打印" : (store.isViewingTomorrow ? "语音输入明日待办" : "语音输入今日待办"))
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(speech.isRecording ? ReceiptTheme.stampRed : ReceiptTheme.ink)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(store.isParsingVoice || store.isPrinting)
            .help(speech.isRecording ? "停止录音并打印待办" : "点击语音输入今日计划")
        }
    }

    // MARK: - Editorial Airy Footer (Inspired by Word Count Receipt's Side-by-Side Barcode Layout)

    private var footerSection: some View {
        VStack(spacing: 12) {
            // Totals row + optional retro thermal progress bar & UNPAID/PAID closure stamp
            VStack(spacing: 7) {
                HStack {
                    Text("TOTAL")
                        .font(.system(size: 11.5, weight: .black, design: .monospaced))
                        .foregroundColor(ReceiptTheme.ink)
                    Spacer()
                    Text("\(store.receipt.doneCount) / \(store.receipt.totalCount) DONE")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(store.receipt.isAllDone ? ReceiptTheme.stampRed : ReceiptTheme.inkSecondary)
                }

                if store.settings.pushUrgeEnabled && store.isViewingActiveDay && !store.receipt.items.isEmpty {
                    ThermalProgressBarView(done: store.receipt.doneCount, total: store.receipt.totalCount)
                }
            }

            if store.receipt.isAllDone {
                StampBadgeView()
                    .padding(.vertical, 2)
            }

            // Side-by-side Barcode + Editorial Footer Info (generous breathing room, zero wrapping!)
            HStack(alignment: .bottom, spacing: 10) {
                VStack(spacing: 3) {
                    DecorativeBarcodeView(
                        seed: "\(store.receipt.dateString)-\(store.receipt.totalCount)-\(store.receipt.doneCount)",
                        height: 32,
                        barCount: 32
                    )
                    .frame(width: 102)

                    Text(store.receipt.dateString.replacingOccurrences(of: "-", with: " "))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .tracking(1.2)
                        .foregroundColor(ReceiptTheme.inkSecondary)
                        .fixedSize()
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 9) {
                        if store.isViewingActiveDay && store.receipt.items.contains(where: { !$0.isDone }) {
                            Button {
                                Task { await store.reorganizePendingWithAI() }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 9.5, weight: .semibold))
                                    Text("整理")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .fixedSize()
                                .foregroundColor(store.settings.hasAPIKey ? ReceiptTheme.ink : ReceiptTheme.accentWarm)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isParsingVoice || store.isPrinting)
                            .help("AI 一键整理当前待办（去水话、纠错、拆分、去重）")
                        }

                        if store.receipt.doneCount > 0 {
                            Button {
                                store.copyCompletedToClipboard()
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(ReceiptTheme.inkSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("复制已完成事项（日报/周报）")
                        }

                        if !store.receipt.items.isEmpty {
                            Button {
                                store.replayPrintAnimation()
                            } label: {
                                Image(systemName: "printer")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(ReceiptTheme.inkSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("重新演示出纸打印效果")
                        }

                        if store.isViewingActiveDay && store.receipt.doneCount > 0 {
                            Button("清理") {
                                store.clearCompleted()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .fixedSize()
                            .foregroundColor(ReceiptTheme.inkSecondary)
                        }
                    }

                    Text("HAVE A GOOD DAY")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundColor(ReceiptTheme.inkMuted)
                        .fixedSize()
                }
            }
            .padding(.top, 2)
        }
    }

    private func submitManualTask() {
        let trimmed = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.addManualItem(title: trimmed)
        newTaskTitle = ""
    }
}

// MARK: - Design A: Inverted Carbon-Black Thermal Reminder Strip

private struct InvertedThermalReminderStrip: View {
    let item: TodoItem
    let onComplete: () -> Void
    let onSnooze: () -> Void
    let onDismiss: () -> Void

    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(Color(red: 0.88, green: 0.22, blue: 0.18))
                    .frame(width: 6.5, height: 6.5)
                    .opacity(pulse ? 1.0 : 0.30)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }

                Text("\(item.displayTimeLabel ?? "") NOW")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(.white)

                Spacer()

                Text("REMINDER")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(Color.white.opacity(0.55))
            }

            Text(item.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .padding(.top, 7)

            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(height: 1)
                .padding(.vertical, 9)

            HStack(spacing: 14) {
                Button(action: onComplete) {
                    Text("[ 划掉 ]")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Button(action: onSnooze) {
                    Text("+10m")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.82))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onDismiss) {
                    Text("忽略")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Color(red: 0.08, green: 0.08, blue: 0.08))
        .cornerRadius(2)
        .padding(.horizontal, -4)
    }
}

// MARK: - Breathable Todo Row (Swiss Receipt Dotted Leaders + Monospace Time)

private struct TodoRowView: View {
    let item: TodoItem
    let isDue: Bool
    let overdueLabel: String?
    let emphasizeCarryOver: Bool
    let isViewingToday: Bool
    let isHighlighted: Bool
    let isEditing: Bool
    @Binding var editingDraft: String

    let onToggle: () -> Void
    let onFocus: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onClearTime: () -> Void
    let onBringToToday: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @FocusState private var isEditFieldFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onToggle) {
                Text(item.isDone ? "[×]" : "[ ]")
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundColor(item.isDone ? ReceiptTheme.stampRed : ReceiptTheme.ink)
            }
            .buttonStyle(.plain)

            if isEditing {
                HStack(spacing: 5) {
                    TextField("修改待办内容或时间...", text: $editingDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .foregroundColor(ReceiptTheme.ink)
                        .focused($isEditFieldFocused)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(ReceiptTheme.ink.opacity(0.32), lineWidth: 0.9)
                        )
                        .cornerRadius(4)
                        .onSubmit(onCommitEdit)
                        .onExitCommand(perform: onCancelEdit)
                        .onAppear {
                            DispatchQueue.main.async {
                                isEditFieldFocused = true
                            }
                        }

                    Button(action: onCommitEdit) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(ReceiptTheme.ink)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("保存修改 (Enter)")

                    Button(action: onCancelEdit) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(ReceiptTheme.inkMuted)
                            .frame(width: 18, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("取消 (Esc)")
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: item.isDone ? .regular : .medium))
                        .foregroundColor(item.isDone ? ReceiptTheme.inkMuted : ReceiptTheme.ink)
                        .strikethrough(item.isDone, color: ReceiptTheme.stampRed.opacity(0.88))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    if let timeLabel = item.displayTimeLabel {
                        DottedLeaderLine()
                            .layoutPriority(0)
                        HStack(spacing: 3.5) {
                            Text(timeLabel)
                                .font(.system(size: 11.5, weight: (isDue && !item.isDone) ? .bold : .medium, design: .monospaced))
                                .foregroundColor(
                                    item.isDone
                                        ? ReceiptTheme.inkMuted
                                        : (isDue ? ReceiptTheme.stampRed : ReceiptTheme.inkSecondary)
                                )
                            if let overdue = overdueLabel, !item.isDone {
                                Text(overdue)
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(ReceiptTheme.stampRed)
                            }
                        }
                        .fixedSize()
                        .layoutPriority(2)
                        .help("悬停点编辑可修改时间，或移除时间")
                    } else if item.carryOverDays > 0 && !item.isDone {
                        Spacer(minLength: 4)
                        Text("+\(item.carryOverDays)D")
                            .font(.system(size: 9.5, weight: emphasizeCarryOver ? .bold : .semibold, design: .monospaced))
                            .foregroundColor(emphasizeCarryOver ? ReceiptTheme.accentWarm : ReceiptTheme.inkMuted)
                            .help("从前 \(item.carryOverDays) 天顺延过来的待办")
                    } else {
                        Spacer(minLength: 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    onBeginEdit()
                }
                .onTapGesture(count: 1) {
                    onToggle()
                }
            }

            if isHovering && !isEditing {
                HStack(spacing: 5) {
                    if !isViewingToday && !item.isDone {
                        Button(action: onBringToToday) {
                            Image(systemName: "arrow.uturn.right")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(ReceiptTheme.inkSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("顺延到今日小票")
                    }
                    if isViewingToday && !item.isDone {
                        Button(action: onFocus) {
                            Image(systemName: "scope")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(ReceiptTheme.inkSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("盯紧这项（进入单条黑条死磕模式）")
                    }
                    if item.displayTimeLabel != nil {
                        Button(action: onClearTime) {
                            Image(systemName: "clock.badge.xmark")
                                .font(.system(size: 10.5))
                                .foregroundColor(ReceiptTheme.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .help("移除该条时间")
                    }
                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        onBeginEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(ReceiptTheme.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .help("编辑此项内容或时间")
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(ReceiptTheme.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .help("删除此项")
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8.5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHighlighted ? ReceiptTheme.highlightBg : (isHovering ? Color.black.opacity(0.035) : Color.clear))
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - AppKit Pull-to-Tear Capture Layer (Zero Window-Drag Conflict)

private struct PullToTearMouseCaptureView: NSViewRepresentable {
    let isEnabled: Bool
    let onHoverChanged: (Bool) -> Void
    let onActiveChanged: (Bool) -> Void
    let onPullChanged: (CGFloat) -> Void
    let onPullEnded: (CGFloat) -> Void

    func makeNSView(context: Context) -> TearPullHandleNSView {
        let view = TearPullHandleNSView()
        updateCallbacks(on: view)
        return view
    }

    func updateNSView(_ nsView: TearPullHandleNSView, context: Context) {
        updateCallbacks(on: nsView)
    }

    private func updateCallbacks(on view: TearPullHandleNSView) {
        view.isTearEnabled = isEnabled
        view.onHoverChanged = onHoverChanged
        view.onActiveChanged = onActiveChanged
        view.onPullChanged = onPullChanged
        view.onPullEnded = onPullEnded
    }
}

private final class TearPullHandleNSView: NSView {
    var isTearEnabled: Bool = true
    var onHoverChanged: ((Bool) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?
    var onPullChanged: ((CGFloat) -> Void)?
    var onPullEnded: ((CGFloat) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isDragging = false
    private var dragStartScreenY: CGFloat = 0
    private var latestPullDistance: CGFloat = 0

    /// Crucial: prevents NSPanel.isMovableByWindowBackground from hijacking the downward tear pull!
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        discardCursorRects()
        if isTearEnabled {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard isTearEnabled else { return }
        onHoverChanged?(true)
        if !isDragging {
            NSCursor.openHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
        if !isDragging {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isTearEnabled else {
            super.mouseDown(with: event)
            return
        }
        isDragging = true
        dragStartScreenY = NSEvent.mouseLocation.y
        latestPullDistance = 0
        NSCursor.closedHand.push()
        onActiveChanged?(true)
        onPullChanged?(0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        // macOS screen Y grows upward, so pulling down lowers mouseLocation.y -> positive pullDistance
        let dy = max(0, dragStartScreenY - NSEvent.mouseLocation.y)
        latestPullDistance = dy
        onPullChanged?(dy)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        let finalDy = max(0, dragStartScreenY - NSEvent.mouseLocation.y)
        latestPullDistance = finalDy
        onActiveChanged?(false)
        onPullEnded?(finalDy)
    }
}
