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
        let soccerID = UUID()
        store.receipt = DailyReceipt(
            dateString: "2026-11-22",
            receiptNo: "NO.20261122",
            items: [
                TodoItem(title: "早会同步", timeHint: "09:30", scheduledMinutes: 9 * 60 + 30, isDone: true, source: .voice),
                TodoItem(id: soccerID, title: "去踢足球", timeHint: "12:00", scheduledMinutes: 12 * 60, isDone: false, source: .voice),
                TodoItem(title: "回复封面反馈", timeHint: "15:30", scheduledMinutes: 15 * 60 + 30, isDone: false, source: .voice),
                TodoItem(title: "完成小红书校招脚本", isDone: false, source: .voice),
                TodoItem(title: "跟进 GLM 视频进度", isDone: false, source: .voice)
            ]
        )
        store.currentMinutesOfDay = 12 * 60
        store.activeReminderItemID = soccerID
        store.streakDays = 5

        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // 1. Expanded receipt with Design A inverted thermal reminder strip + subtle bottom-hem pull cue
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
            }.frame(width: 420, height: 860),
            to: url.appendingPathComponent("preview_expanded.png")
        )

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
                TodoItem(title: "早会同步", timeHint: "09:30", scheduledMinutes: 9 * 60 + 30, isDone: true, source: .voice),
                TodoItem(title: "去踢足球", timeHint: "12:00", scheduledMinutes: 12 * 60, isDone: true, source: .voice),
                TodoItem(title: "完成小红书校招脚本", isDone: true, source: .voice),
                TodoItem(title: "跟进 GLM 视频进度", isDone: true, source: .voice)
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
                    streakDays: 5,
                    canUndoTearOff: true,
                    isStaticPreview: true,
                    onUndoTearOff: {},
                    onClose: {}
                )
            }.frame(width: 470, height: 740),
            to: url.appendingPathComponent("preview_share_poster.png")
        )
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
        GlobalHotkeyManager.shared.setEnabled(store.settings.globalHotkeyEnabled, onTrigger: handler)
        store.onGlobalHotkeyChange = { enabled in
            GlobalHotkeyManager.shared.setEnabled(enabled, onTrigger: handler)
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

        let voiceItem = NSMenuItem(title: "语音记录今日待办 (⌥Space)", action: #selector(triggerVoice), keyEquivalent: "v")
        voiceItem.target = self
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
