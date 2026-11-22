import SwiftUI

/// Collapsed state (Option A): compact brushed-silver metallic printer slot,
/// with a serrated thermal paper stub emerging directly out of the CENTER dark slit.
struct CollapsedPillView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var speech: SpeechService
    @State private var isHovering = false

    private let bezelWidth = PrinterSlotMetrics.collapsedBezelWidth
    private let slotWidth = PrinterSlotMetrics.collapsedSlotWidth
    private let paperWidth = PrinterSlotMetrics.collapsedPaperWidth

    var body: some View {
        ZStack(alignment: .top) {
            PrinterSlotBackLayer(bezelWidth: bezelWidth, slotWidth: slotWidth)
                .zIndex(1)

            Button {
                store.expandFromSlot()
            } label: {
                ZStack(alignment: .top) {
                    ZStack(alignment: .top) {
                        ThermalPaperSurface()

                        if store.isTodayTornOff {
                            HStack(spacing: 6) {
                                Text("TOMORROW")
                                    .font(.system(size: 9.5, weight: .black, design: .monospaced))
                                    .tracking(0.4)
                                    .foregroundColor(ReceiptTheme.ink)
                                Text("\(store.receipt.doneCount)/\(store.receipt.totalCount)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(ReceiptTheme.inkSecondary)
                                Spacer(minLength: 2)
                                Image(systemName: "chevron.compact.down")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(ReceiptTheme.inkMuted)
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, isHovering ? 13 : 9)
                        } else {
                            HStack(spacing: 6) {
                                Text("TODAY")
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                                    .foregroundColor(ReceiptTheme.ink)
                                Text("\(store.receipt.doneCount)/\(store.receipt.totalCount)")
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                                    .foregroundColor(
                                        store.receipt.isAllDone ? ReceiptTheme.stampRed : ReceiptTheme.inkSecondary
                                    )
                                Spacer(minLength: 2)
                                if let nextTimed = store.nextUpcomingTimedItem, let label = nextTimed.displayTimeLabel {
                                    Text(label)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(store.isItemDue(nextTimed) ? ReceiptTheme.stampRed : ReceiptTheme.inkSecondary)
                                } else {
                                    Image(systemName: "chevron.compact.down")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(ReceiptTheme.inkMuted)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, isHovering ? 13 : 9)
                        }

                        SlotContactShadow()
                    }
                    .frame(width: paperWidth, height: isHovering ? 40 : (store.isTodayTornOff ? 30 : 32))
                    .clipShape(ThermalReceiptShape(topPinch: 1.5, toothWidth: 10.5, toothHeight: 4.5))
                    .overlay(
                        ThermalReceiptShape(topPinch: 1.5, toothWidth: 10.5, toothHeight: 4.5)
                            .stroke(Color.black.opacity(0.07), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.24), radius: 6, x: 0, y: 4)
                    .shadow(color: Color.black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                    .padding(.bottom, 10)
                    .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isHovering)
                }
                .frame(width: bezelWidth, alignment: .top)
                .clipped()
            }
            .buttonStyle(.plain)
            .padding(.top, PrinterSlotMetrics.slotCenterY)
            .zIndex(5)
            .help(store.isTodayTornOff ? "点击吐出明日预备小票" : "点击吐出今日待办小票")

            PrinterSlotUpperOverlay(
                bezelWidth: bezelWidth,
                isRecording: speech.isRecording,
                isPrinting: store.isPrinting,
                hasReminder: store.activeReminderItem != nil && !store.isTodayTornOff,
                isExpanded: false,
                isHoveringBezel: isHovering,
                isClosedForDay: false,
                onToggleExpand: { store.expandFromSlot() },
                onToggleVoice: { store.toggleVoiceRecording() },
                onOpenSettings: { store.openSettings() }
            )
            .zIndex(10)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
