import AppKit
import SwiftUI

@main
struct ReceiptTodoMain {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--render-preview"), idx + 1 < args.count {
            let outDir = args[idx + 1]
            MainActor.assumeIsolated {
                PreviewRenderer.renderAll(to: outDir)
            }
            return
        }
        if let idx = args.firstIndex(of: "--render-showcase"), idx + 1 < args.count {
            let outDir = args[idx + 1]
            MainActor.assumeIsolated {
                PreviewRenderer.renderShowcaseBanners(to: outDir)
            }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
private enum PreviewRenderer {
    static func renderAll(to dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let store = TodoStore()
        store.isRenderingStaticPreview = true
        let lunchID = UUID()
        store.receipt = DailyReceipt(
            dateString: "2026-11-22",
            receiptNo: "NO.20261122",
            items: [
                TodoItem(title: "晨会同步本周排期", timeHint: "09:30", scheduledMinutes: 9 * 60 + 30, isDone: true, source: .voice),
                TodoItem(id: lunchID, title: "约朋友吃午饭", timeHint: "12:00", scheduledMinutes: 12 * 60, isDone: false, source: .voice),
                TodoItem(title: "整理周报发给团队", timeHint: "15:30", scheduledMinutes: 15 * 60 + 30, isDone: false, source: .voice),
                TodoItem(title: "下班去健身房跑 5 公里", isDone: false, source: .voice),
                TodoItem(title: "买猫粮和冰美式咖啡", isDone: false, source: .voice)
            ]
        )
        store.currentMinutesOfDay = 12 * 60 + 25 // 12:25 so 12:00 shows +25m overdue!
        store.activeReminderItemID = lunchID
        store.streakDays = 7
        store.settings.pushUrgeEnabled = true
        store.settings.closingCountdownEnabled = true
        store.settings.closingMinutesOfDay = 18 * 60 + 30 // OPEN · 距打烊 6h5m

        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // 1. Expanded receipt with bezel OPEN/closing lamp, overdue +25m, progress bar & UNPAID stamp
        store.isTodayTornOff = false
        store.isExpanded = true
        store.paperReveal = 1.0
        store.isPrinting = false
        store.tearPullDistance = 0
        store.tearProgress = 0
        store.tearDriftProgress = 0
        save(
            view: ZStack {
                Color(red: 0.89, green: 0.89, blue: 0.90)
                ReceiptCardView(store: store, speech: store.speechService)
            }.frame(width: 420, height: 910),
            to: url.appendingPathComponent("preview_expanded.png")
        )

        // 1b. Focus Lock Mode (single-task giant countdown black thermal strip)
        store.focusedItemID = store.receipt.items[2].id
        store.focusTotalSeconds = 25 * 60
        store.focusRemainingSeconds = 4 * 60 + 38 // Last 5 mins urgent crimson countdown!
        store.isFocusPaused = false
        save(
            view: ZStack {
                Color(red: 0.89, green: 0.89, blue: 0.90)
                ReceiptCardView(store: store, speech: store.speechService)
            }.frame(width: 420, height: 310),
            to: url.appendingPathComponent("preview_focus_lock.png")
        )
        store.focusedItemID = nil

        // 2. Mid-tear progressive left-to-right unzip preview
        store.tearPullDistance = 74
        store.tearProgress = 0.62
        store.tearDriftProgress = 0
        save(
            view: ZStack {
                Color(red: 0.89, green: 0.89, blue: 0.90)
                ReceiptCardView(store: store, speech: store.speechService)
            }.frame(width: 420, height: 880),
            to: url.appendingPathComponent("preview_tearing.png")
        )

        // 3. Collapsed metallic slot stub (normal TODAY state)
        store.tearPullDistance = 0
        store.tearProgress = 0
        store.isTodayTornOff = false
        store.isExpanded = false
        store.isPrinting = false
        save(
            view: ZStack {
                Color(red: 0.89, green: 0.89, blue: 0.90)
                CollapsedPillView(store: store, speech: store.speechService)
            }.frame(width: 295, height: 125),
            to: url.appendingPathComponent("preview_collapsed.png")
        )

        // 4. Serene compact post-tear NEXT ROLL stub (right after tearing off today!)
        store.isTodayTornOff = true
        store.isPlanningTomorrow = false
        store.tornOffTodayDoneCount = 4
        store.tornOffTodayTotalCount = 4
        store.isExpanded = true
        store.paperReveal = 1.0
        store.activeReminderItemID = nil
        store.receipt = DailyReceipt(dateString: "2026-11-23", receiptNo: "NO.20261123", items: [])
        save(
            view: ZStack {
                Color(red: 0.89, green: 0.89, blue: 0.90)
                ReceiptCardView(store: store, speech: store.speechService)
            }.frame(width: 420, height: 290),
            to: url.appendingPathComponent("preview_post_tear_stub.png")
        )

        // 5. Frameless Direct-Display Floating Share Poster + Floating Dark Glass HUD
        let shareSample = DailyReceipt(
            dateString: "2026-11-22",
            receiptNo: "NO.20261122",
            items: [
                TodoItem(title: "晨会同步本周排期", timeHint: "09:30", scheduledMinutes: 9 * 60 + 30, isDone: true, source: .voice),
                TodoItem(title: "约朋友吃午饭", timeHint: "12:00", scheduledMinutes: 12 * 60, isDone: true, source: .voice),
                TodoItem(title: "整理周报发给团队", timeHint: "15:30", scheduledMinutes: 15 * 60 + 30, isDone: true, source: .voice),
                TodoItem(title: "下班去健身房跑 5 公里", isDone: true, source: .voice),
                TodoItem(title: "买猫粮和冰美式咖啡", isDone: true, source: .voice)
            ]
        )
        save(
            view: ZStack {
                LinearGradient(
                    colors: [Color(red: 0.78, green: 0.82, blue: 0.85), Color(red: 0.68, green: 0.72, blue: 0.76)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                ShareReceiptWindowView(
                    receipt: shareSample,
                    streakDays: 7,
                    canUndoTearOff: true,
                    isStaticPreview: true,
                    onUndoTearOff: {},
                    onClose: {}
                )
            }.frame(width: 470, height: 740),
            to: url.appendingPathComponent("preview_share_poster.png")
        )
    }

    /// Generates 4 cohesive, wide studio showcase banners (inspired by polished indie macOS landing pages)
    /// using relatable fictional to-dos for the public GitHub README.
    static func renderShowcaseBanners(to dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        func makeWorkingStore() -> TodoStore {
            let s = TodoStore()
            s.isRenderingStaticPreview = true
            let lunchID = UUID()
            s.receipt = DailyReceipt(
                dateString: "2026-11-22",
                receiptNo: "NO.20261122",
                items: [
                    TodoItem(title: "早会同步排期", timeHint: "09:30", scheduledMinutes: 9 * 60 + 30, isDone: true, source: .voice),
                    TodoItem(id: lunchID, title: "约朋友吃午饭", timeHint: "12:00", scheduledMinutes: 12 * 60, isDone: false, source: .voice),
                    TodoItem(title: "整理本周周报", timeHint: "15:30", scheduledMinutes: 15 * 60 + 30, isDone: false, source: .voice),
                    TodoItem(title: "下班去健身房跑 5 公里", isDone: false, source: .voice),
                    TodoItem(title: "买猫粮和冰美式咖啡", isDone: false, source: .voice)
                ]
            )
            s.currentMinutesOfDay = 12 * 60
            s.activeReminderItemID = lunchID
            s.streakDays = 7
            s.isTodayTornOff = false
            s.isExpanded = true
            s.paperReveal = 1.0
            s.isPrinting = false
            s.tearPullDistance = 0
            s.tearProgress = 0
            s.tearDriftProgress = 0
            return s
        }

        let completedSample = DailyReceipt(
            dateString: "2026-11-22",
            receiptNo: "NO.20261122",
            items: [
                TodoItem(title: "早会同步排期", timeHint: "09:30", scheduledMinutes: 9 * 60 + 30, isDone: true, source: .voice),
                TodoItem(title: "约朋友吃午饭", timeHint: "12:00", scheduledMinutes: 12 * 60, isDone: true, source: .voice),
                TodoItem(title: "整理本周周报", timeHint: "15:30", scheduledMinutes: 15 * 60 + 30, isDone: true, source: .voice),
                TodoItem(title: "下班去健身房跑 5 公里", isDone: true, source: .voice),
                TodoItem(title: "买猫粮和冰美式咖啡", isDone: true, source: .voice)
            ]
        )

        // 1. HERO BANNER (1160 x 540 @ 2x) — 100% razor-sharp native vector UI over lush mint-green Mac desktop aesthetic!
        let heroStore = makeWorkingStore()
        heroStore.activeReminderItemID = nil
        heroStore.streakDays = 7
        heroStore.receipt = DailyReceipt(
            dateString: "2026-11-22",
            receiptNo: "NO.20261122",
            items: [
                TodoItem(title: "早会同步排期", timeHint: "09:30", scheduledMinutes: 9 * 60 + 30, isDone: true, source: .voice),
                TodoItem(title: "和朋友共进晚餐", timeHint: "20:00", scheduledMinutes: 20 * 60, isDone: false, source: .voice),
                TodoItem(title: "整理本周周报", isDone: true, source: .voice),
                TodoItem(title: "下班去健身房跑 5 公里", isDone: false, source: .voice)
            ]
        )

        let heroCompletedSample = DailyReceipt(
            dateString: "2026-11-22",
            receiptNo: "NO.20261122",
            items: [
                TodoItem(title: "早会同步排期", timeHint: "09:30", scheduledMinutes: 9 * 60 + 30, isDone: true, source: .voice),
                TodoItem(title: "和朋友共进晚餐", timeHint: "20:00", scheduledMinutes: 20 * 60, isDone: true, source: .voice),
                TodoItem(title: "整理本周周报", isDone: true, source: .voice),
                TodoItem(title: "下班去健身房跑 5 公里", isDone: true, source: .voice)
            ]
        )

        let heroView = ZStack {
            // Silky sculptural mint-green macOS desktop backdrop (zero JPEG artifacts!)
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.42, green: 0.78, blue: 0.56),
                        Color(red: 0.22, green: 0.56, blue: 0.38),
                        Color(red: 0.14, green: 0.40, blue: 0.28)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Soft sculptural diagonal mint ribbons echoing Apple macOS green wallpaper
                HStack(spacing: 44) {
                    ForEach(0..<4, id: \.self) { idx in
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.76, green: 0.96, blue: 0.80).opacity(idx % 2 == 0 ? 0.52 : 0.34),
                                        Color(red: 0.10, green: 0.36, blue: 0.22).opacity(0.45)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 210, height: 820)
                            .blur(radius: 16)
                    }
                }
                .rotationEffect(.degrees(14))
                .offset(x: 40, y: 10)

                // Gentle dark vignette toward right for crisp white typography readability
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.02), location: 0.0),
                        .init(color: Color.black.opacity(0.14), location: 0.40),
                        .init(color: Color.black.opacity(0.32), location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .overlay(alignment: .top) {
                // Crisp native 2x macOS menu bar strip
                HStack(spacing: 16) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 12, weight: .semibold))
                    Text("ReceiptTodo")
                        .font(.system(size: 11.5, weight: .bold))
                    Text("文件").font(.system(size: 11.5))
                    Text("编辑").font(.system(size: 11.5))
                    Text("显示").font(.system(size: 11.5))
                    Spacer()
                    Image(systemName: "receipt").font(.system(size: 11, weight: .semibold))
                    Image(systemName: "wifi").font(.system(size: 11))
                    Text("周日 19:45").font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 18)
                .frame(height: 26)
                .background(Color.black.opacity(0.20))
            }

            HStack(spacing: 26) {
                // Left: 100% razor-sharp native 2x vector ReceiptCardView hanging straight off desktop corner!
                ReceiptCardView(store: heroStore, speech: heroStore.speechService)
                    .frame(width: 400, height: 740, alignment: .top)
                    .scaleEffect(0.67, anchor: .top)
                    .frame(width: 274, height: 492, alignment: .top)
                    .padding(.top, 28)

                // Center: Crisp white editorial product pitch
                VStack(alignment: .leading, spacing: 14) {
                    Text("MACOS 桌面小票待办")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundColor(.white.opacity(0.94))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.18))
                        .clipShape(Capsule())

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("ReceiptTodo")
                                .font(.system(size: 46, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                            Text("小票待办")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white.opacity(0.88))
                        }
                        .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 3)

                        Text("把每天要做的事，像小票一样挂在桌角")
                            .font(.system(size: 19.5, weight: .bold))
                            .foregroundColor(.white.opacity(0.96))
                            .padding(.top, 4)

                        Text("随口说出今天安排 · 到点反白提醒 · 晚上撕下变打卡图")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.86))
                            .padding(.top, 2)
                    }

                    HStack(spacing: 9) {
                        ForEach(["语音自动整理", "真实撕纸手感", "纯本地零上传"], id: \.self) { label in
                            Text(label)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.28))
                                .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 0.8))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(width: 448, alignment: .leading)

                // Right: 100% razor-sharp native 2x vector ShareableReceiptArtwork!
                ShareableReceiptArtwork(
                    receipt: heroCompletedSample,
                    streakDays: 7,
                    backdrop: .warmGray,
                    completedOnly: false
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.32), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.34), radius: 22, x: 0, y: 12)
                .scaleEffect(0.68)
                .rotationEffect(.degrees(3.2))
                .frame(width: 280, height: 420)
            }
            .padding(.horizontal, 32)
        }
        .frame(width: 1160, height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        save(view: heroView, to: url.appendingPathComponent("hero-banner.png"))

        // 2. FEATURE 1: VOICE -> CLEAN RECEIPT & REMINDER (1160 x 540)
        let f1Store = makeWorkingStore()
        let feature1 = ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.94, green: 0.95, blue: 0.965),
                            Color(red: 0.885, green: 0.90, blue: 0.925)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

            HStack(spacing: 28) {
                // Left: natural spoken quote card
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(ReceiptTheme.stampRed)
                            .frame(width: 9, height: 9)
                        Text("按下 Option + Space，随口说就行")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundColor(ReceiptTheme.stampRed)
                        Spacer()
                        HStack(spacing: 3) {
                            ForEach([6.0, 14.0, 20.0, 11.0, 18.0, 9.0, 15.0], id: \.self) { h in
                                Capsule()
                                    .fill(ReceiptTheme.stampRed.opacity(0.75))
                                    .frame(width: 3, height: h)
                            }
                        }
                    }

                    Text("「上午九点半开早会同步排期，中午十二点约朋友吃午饭，下午三点半整理本周周报，下班去健身房跑五公里，顺便买猫粮和冰美式。」")
                        .font(.system(size: 16.5, weight: .medium))
                        .lineSpacing(6)
                        .foregroundColor(ReceiptTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    DashedDivider()
                        .opacity(0.45)

                    VStack(alignment: .leading, spacing: 8) {
                        voiceCheckRow("自动去掉口语废话、纠正同音错别字")
                        voiceCheckRow("自动拆分多件事，并按时间先后排好队")
                        voiceCheckRow("到点自动弹出黑条提醒，一眼就能划掉或推迟")
                    }
                }
                .padding(28)
                .frame(width: 470)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.92))
                        .shadow(color: Color.black.opacity(0.09), radius: 16, x: 0, y: 8)
                )

                // Middle arrow
                VStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(ReceiptTheme.inkSecondary)
                    Text("自动打印")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(ReceiptTheme.inkMuted)
                }

                // Right: printed live receipt
                ReceiptCardView(store: f1Store, speech: f1Store.speechService)
                    .frame(width: 410, height: 830, alignment: .top)
                    .scaleEffect(0.58)
                    .frame(width: 260, height: 490)
            }
            .padding(.horizontal, 48)
        }
        .frame(width: 1160, height: 540)
        save(view: feature1, to: url.appendingPathComponent("feature-voice-reminder.png"))

        // 3. FEATURE 2: TEAR -> DIRECT SHARE POSTER -> NEXT ROLL STUB (1160 x 560)
        let tearStore = makeWorkingStore()
        tearStore.tearPullDistance = 74
        tearStore.tearProgress = 0.62

        let stubStore = makeWorkingStore()
        stubStore.isTodayTornOff = true
        stubStore.isPlanningTomorrow = false
        stubStore.tornOffTodayDoneCount = 5
        stubStore.tornOffTodayTotalCount = 5
        stubStore.activeReminderItemID = nil
        stubStore.receipt = DailyReceipt(dateString: "2026-11-23", receiptNo: "NO.20261123", items: [])

        let feature2 = ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.955, green: 0.94, blue: 0.915),
                            Color(red: 0.905, green: 0.885, blue: 0.85)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

            HStack(alignment: .bottom, spacing: 26) {
                // Step 1: Pulling down & progressive tear
                VStack(spacing: 12) {
                    ReceiptCardView(store: tearStore, speech: tearStore.speechService)
                        .frame(width: 410, height: 850, alignment: .top)
                        .scaleEffect(0.54)
                        .frame(width: 250, height: 465)

                    stepCaption("① 沿齿线轻轻下拉", sub: "伴随真实同步撕纸声")
                }

                // Step 2: Direct frameless 3x share poster + floating HUD
                VStack(spacing: 12) {
                    ShareReceiptWindowView(
                        receipt: completedSample,
                        streakDays: 7,
                        canUndoTearOff: true,
                        isStaticPreview: true,
                        onUndoTearOff: {},
                        onClose: {}
                    )
                    .frame(width: 450, height: 700)
                    .scaleEffect(0.66)
                    .frame(width: 315, height: 465)

                    stepCaption("② 直接弹出高清打卡图", sub: "一键复制发微信 / 隔空投送")
                }

                // Step 3: Clean short NEXT ROLL stub
                VStack(spacing: 12) {
                    VStack {
                        Spacer()
                        ReceiptCardView(store: stubStore, speech: stubStore.speechService)
                            .frame(width: 410, height: 270, alignment: .top)
                            .scaleEffect(0.76)
                            .frame(width: 310, height: 215)
                        Spacer()
                    }
                    .frame(width: 310, height: 465)

                    stepCaption("③ 切出清爽明日新纸头", sub: "桌面瞬间干净，随时可复原")
                }
            }
            .padding(.horizontal, 42)
            .padding(.vertical, 24)
        }
        .frame(width: 1160, height: 560)
        save(view: feature2, to: url.appendingPathComponent("feature-tear-share.png"))

        // 4. FEATURE 3: CORNER COLLAPSED MODE + CARRY-OVER (1160 x 460)
        let cornerStore = makeWorkingStore()
        cornerStore.isExpanded = false

        let tomorrowStore = makeWorkingStore()
        tomorrowStore.isTodayTornOff = true
        tomorrowStore.isPlanningTomorrow = true
        tomorrowStore.activeReminderItemID = nil
        tomorrowStore.carryOverSourceDate = "2026-11-22"
        tomorrowStore.carryOverCandidates = [
            TodoItem(title: "整理本周周报", isDone: false, source: .voice),
            TodoItem(title: "买猫粮和冰美式咖啡", isDone: false, source: .voice)
        ]
        tomorrowStore.selectedCarryOverIDs = Set(tomorrowStore.carryOverCandidates.map(\.id))
        tomorrowStore.isCarryOverPickerOpen = true
        tomorrowStore.receipt = DailyReceipt(dateString: "2026-11-23", receiptNo: "NO.20261123", items: [])

        let feature3 = ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.93, green: 0.94, blue: 0.955),
                            Color(red: 0.875, green: 0.89, blue: 0.915)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

            HStack(spacing: 36) {
                // Left: Simulated macOS desktop corner with collapsed brushed-metal slot
                VStack(spacing: 14) {
                    ZStack(alignment: .topTrailing) {
                        // Simulated calm macOS desktop wallpaper corner
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.20, green: 0.27, blue: 0.36),
                                        Color(red: 0.34, green: 0.44, blue: 0.52),
                                        Color(red: 0.55, green: 0.62, blue: 0.66)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(alignment: .top) {
                                // Subtle macOS menu bar strip
                                HStack(spacing: 12) {
                                    Spacer()
                                    Image(systemName: "receipt")
                                        .font(.system(size: 11, weight: .semibold))
                                    Image(systemName: "wifi")
                                        .font(.system(size: 11))
                                    Text("周日 11:45")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(.white.opacity(0.92))
                                .padding(.horizontal, 14)
                                .frame(height: 26)
                                .background(Color.black.opacity(0.24))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        // Real collapsed metallic slot perched naturally in top-right corner
                        CollapsedPillView(store: cornerStore, speech: cornerStore.speechService)
                            .padding(.top, 36)
                            .padding(.trailing, 18)

                        // Subtle ghost desktop card on left for real workspace scale
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 5) {
                                Circle().fill(Color.white.opacity(0.35)).frame(width: 7, height: 7)
                                Circle().fill(Color.white.opacity(0.25)).frame(width: 7, height: 7)
                                Circle().fill(Color.white.opacity(0.20)).frame(width: 7, height: 7)
                            }
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.22)).frame(width: 110, height: 8)
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.14)).frame(width: 160, height: 8)
                            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.14)).frame(width: 135, height: 8)
                            Spacer()
                        }
                        .padding(14)
                        .frame(width: 210, height: 155)
                        .background(Color.white.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.14), lineWidth: 0.7))
                        .cornerRadius(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(18)
                    }
                    .frame(width: 490, height: 320)
                    .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 8)

                    stepCaption("收起后只占桌面一角", sub: "置顶不抢焦点，扫一眼就知进度与下场提醒")
                }

                // Right: Cross-weekend carry-over picker preview (top-aligned so metal slot + date + checklist show cleanly!)
                VStack(spacing: 14) {
                    Color(red: 0.90, green: 0.905, blue: 0.915)
                        .frame(width: 490, height: 320)
                        .overlay(alignment: .top) {
                            ReceiptCardView(store: tomorrowStore, speech: tomorrowStore.speechService)
                                .frame(width: 410, height: 760, alignment: .top)
                                .scaleEffect(0.78, anchor: .top)
                                .padding(.top, 10)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.black.opacity(0.06), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 6)

                    stepCaption("没做完的，明天接得住", sub: "跨周末也能一键挑选顺延，也可随时翻看往日小票")
                }
            }
            .padding(.horizontal, 44)
        }
        .frame(width: 1160, height: 460)
        save(view: feature3, to: url.appendingPathComponent("feature-corner-carryover.png"))
    }

    private static func heroTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(ReceiptTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.82))
            .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.8))
            .clipShape(Capsule())
    }

    private static func voiceCheckRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(ReceiptTheme.ink)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ReceiptTheme.inkSecondary)
        }
    }

    private static func stepCaption(_ title: String, sub: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(ReceiptTheme.ink)
            Text(sub)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ReceiptTheme.inkSecondary)
        }
    }

    private static func save<V: View>(view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let cgImage = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: TodoStore!
    private var panelController: FloatingPanelController!
    private var statusItem: NSStatusItem!
    private var voiceMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        store = TodoStore()
        panelController = FloatingPanelController(store: store)
        setupMenuBar()
        setupGlobalHotkey()
        panelController.show()
        // Play a crisp welcoming paper feed out of the metallic slot on launch
        store.playThermalPrintFeed(steps: 6, startReveal: 0.04)
    }

    private func setupGlobalHotkey() {
        let handler: () -> Void = { [weak self] in
            guard let self else { return }
            self.panelController.show()
            self.store.toggleVoiceRecording()
        }
        GlobalHotkeyManager.shared.configure(
            enabled: store.settings.globalHotkeyEnabled,
            config: store.settings.globalHotkey,
            onTrigger: handler
        )
        store.onGlobalHotkeyChange = { [weak self] enabled, config in
            GlobalHotkeyManager.shared.configure(enabled: enabled, config: config, onTrigger: handler)
            self?.refreshVoiceMenuItemTitle(enabled: enabled, config: config)
        }
    }

    private func refreshVoiceMenuItemTitle(enabled: Bool, config: GlobalHotkeyConfig) {
        if enabled {
            voiceMenuItem?.title = "语音记录今日待办 (\(config.displaySymbols))"
        } else {
            voiceMenuItem?.title = "语音记录今日待办"
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyManager.shared.unregister()
    }

    /// Provides standard Edit shortcuts (Cmd+C/V/X/A/Z) for TextField & SecureField
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出小票待办", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "receipt", accessibilityDescription: "今日小票")
                ?? NSImage(systemSymbolName: "list.bullet.rectangle.portrait", accessibilityDescription: "今日小票")
            if let image {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "🧾"
            }
            button.toolTip = "小票待办 ReceiptTodo"
        }

        let menu = NSMenu()

        let toggleExpandItem = NSMenuItem(title: "展开 / 收起小票", action: #selector(toggleExpand), keyEquivalent: "e")
        toggleExpandItem.target = self
        menu.addItem(toggleExpandItem)

        let voiceTitle = store.settings.globalHotkeyEnabled
            ? "语音记录今日待办 (\(store.settings.globalHotkey.displaySymbols))"
            : "语音记录今日待办"
        let voiceItem = NSMenuItem(title: voiceTitle, action: #selector(triggerVoice), keyEquivalent: "v")
        voiceItem.target = self
        self.voiceMenuItem = voiceItem
        menu.addItem(voiceItem)

        let copyItem = NSMenuItem(title: "复制今日已完成 (日报)", action: #selector(copyCompleted), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        let reprintItem = NSMenuItem(title: "重新吐纸打印效果", action: #selector(replayPrint), keyEquivalent: "p")
        reprintItem.target = self
        menu.addItem(reprintItem)

        let shareItem = NSMenuItem(title: "生成打卡分享图...", action: #selector(openShareCard), keyEquivalent: "s")
        shareItem.target = self
        menu.addItem(shareItem)

        let tearOffItem = NSMenuItem(title: "结束今日 · 撕下小票", action: #selector(tearOffToday), keyEquivalent: "")
        tearOffItem.target = self
        menu.addItem(tearOffItem)

        let showHideItem = NSMenuItem(title: "显示 / 隐藏浮窗", action: #selector(toggleWindowVisibility), keyEquivalent: "h")
        showHideItem.target = self
        menu.addItem(showHideItem)

        menu.addItem(.separator())

        let resetPosItem = NSMenuItem(title: "回到右上角默认位置", action: #selector(resetPosition), keyEquivalent: "")
        resetPosItem.target = self
        menu.addItem(resetPosItem)

        let settingsItem = NSMenuItem(title: "设置 API Key 与偏好...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出小票待办", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleExpand() {
        panelController.show()
        store.toggleExpanded()
    }

    @objc private func replayPrint() {
        panelController.show()
        store.replayPrintAnimation()
    }

    @objc private func tearOffToday() {
        panelController.show()
        store.triggerAnimatedTearOff()
    }

    @objc private func openShareCard() {
        panelController.show()
        store.openShareCardForCurrentReceipt()
    }

    @objc private func triggerVoice() {
        panelController.show()
        store.toggleVoiceRecording()
    }

    @objc private func copyCompleted() {
        store.copyCompletedToClipboard()
    }

    @objc private func toggleWindowVisibility() {
        panelController.toggleVisibility()
    }

    @objc private func resetPosition() {
        panelController.show()
        panelController.resetToDefaultCorner()
    }

    @objc private func openSettings() {
        panelController.showSettingsWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
