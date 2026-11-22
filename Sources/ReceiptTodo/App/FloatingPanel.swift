import AppKit
import SwiftUI

final class FloatingReceiptPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Borderless transparent floating panel that presents the torn-off shareable check-in poster directly on screen.
final class SharePosterPanel: NSPanel {
    var onEscapeClose: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscapeClose?()
    }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    let panel: FloatingReceiptPanel
    private let store: TodoStore
    private var hostingView: NSHostingView<RootWidgetView>
    private var settingsWindow: NSWindow?
    private var shareWindow: NSWindow?

    private let anchorEdgeXKey = "ReceiptTodo.AnchorEdgeX"
    private let anchorTopYKey = "ReceiptTodo.AnchorTopY"
    private let anchorLeftKey = "ReceiptTodo.AnchorIsLeft"

    private let collapsedSize = CGSize(width: 266, height: 96)
    private let expandedWidth: CGFloat = 394
    private var isProgrammaticResize = false

    init(store: TodoStore) {
        self.store = store
        let rootView = RootWidgetView(store: store, speech: store.speechService)
        self.hostingView = NSHostingView(rootView: rootView)
        self.hostingView.wantsLayer = true
        self.hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let initialSize = CGSize(width: 394, height: 560)
        let initialFrame = Self.defaultFrame(for: initialSize)
        self.panel = FloatingReceiptPanel(contentRect: initialFrame)
        self.panel.contentView = hostingView

        super.init()

        self.panel.delegate = self
        self.panel.level = store.settings.alwaysOnTop ? .floating : .normal

        store.onWindowLayoutChange = { [weak self] animated in
            self?.updatePanelSize(animated: animated)
        }
        store.onAlwaysOnTopChange = { [weak self] alwaysOnTop in
            self?.panel.level = alwaysOnTop ? .floating : .normal
        }
        store.onOpenSettings = { [weak self] in
            self?.showSettingsWindow()
        }
        store.onResetPosition = { [weak self] in
            self?.resetToDefaultCorner()
        }
        store.onShowShareCard = { [weak self] receipt, streak, canUndo in
            self?.showShareWindow(receipt: receipt, streakDays: streak, canUndoTearOff: canUndo)
        }
        store.onCloseShareCard = { [weak self] in
            self?.shareWindow?.close()
            self?.shareWindow = nil
        }

        restoreAnchorOrDefault()
        updatePanelSize(animated: false)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func toggleVisibility() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func resetToDefaultCorner() {
        UserDefaults.standard.removeObject(forKey: anchorEdgeXKey)
        UserDefaults.standard.removeObject(forKey: anchorTopYKey)
        UserDefaults.standard.removeObject(forKey: anchorLeftKey)
        store.isAnchoredLeft = false

        let targetSize = desiredSize()
        let frame = Self.defaultFrame(for: targetSize)
        setPanelFrame(frame, animated: true)
        saveAnchor(from: frame, isLeft: false)
    }

    func updatePanelSize(animated: Bool) {
        let newSize = desiredSize()
        let oldFrame = panel.frame
        let topY = oldFrame.maxY

        // Pin LEFT edge when positioned on the left half of the screen;
        // pin RIGHT edge when positioned on the right half of the screen!
        let newOriginX: CGFloat = store.isAnchoredLeft
            ? oldFrame.minX
            : (oldFrame.maxX - newSize.width)

        var newFrame = NSRect(
            x: newOriginX,
            y: topY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
        newFrame = clampFrameToVisibleScreen(newFrame)

        guard abs(newFrame.width - oldFrame.width) > 0.5
            || abs(newFrame.height - oldFrame.height) > 0.5
            || abs(newFrame.origin.x - oldFrame.origin.x) > 0.5
            || abs(newFrame.origin.y - oldFrame.origin.y) > 0.5 else {
            return
        }

        setPanelFrame(newFrame, animated: animated)
    }

    private func setPanelFrame(_ frame: NSRect, animated: Bool) {
        isProgrammaticResize = true
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isProgrammaticResize = false
                }
            })
        } else {
            panel.setFrame(frame, display: true)
            isProgrammaticResize = false
        }
    }

    private func desiredSize() -> CGSize {
        if !store.isExpanded {
            return collapsedSize
        }

        // Single-task Focus Lock Mode: high-urgency giant countdown black slip hanging from the metal slot!
        if store.focusedItem != nil {
            return CGSize(width: expandedWidth, height: 280)
        }

        // Right after tearing off today: compact serene NEXT ROLL stub (~252pt) instead of a huge blank form!
        if store.isShowingPostTearStub {
            return CGSize(width: expandedWidth, height: 252)
        }

        // Generous airy receipt layout + optional reminder strip + carry-over picker + comfortable input area
        // + 72pt transparent bottom runway (click-through on macOS) so gentle pull-down & drift-away tear never clips!
        let baseHeight: CGFloat = (store.isViewingActiveDay ? 476 : 436) + 72
        let itemsCount = store.receipt.items.count
        let listHeight: CGFloat = itemsCount == 0 ? 86 : min(CGFloat(itemsCount) * 44 + 22, 268)
        let reminderHeight: CGFloat = store.activeReminderItem == nil ? 0 : 114
        let rolloverHeight: CGFloat = {
            guard store.isViewingActiveDay, !store.carryOverCandidates.isEmpty else { return 0 }
            if store.isCarryOverPickerOpen {
                return min(CGFloat(store.carryOverCandidates.count) * 26 + 76, 190)
            }
            return 48
        }()
        let recordingHeight: CGFloat = (store.speechService.isRecording || store.isParsingVoice) ? 112 : 0
        let aiErrorHeight: CGFloat = store.aiErrorBanner == nil ? 0 : 122
        let toastHeight: CGFloat = store.toastMessage == nil ? 0 : 40
        let pushFooterHeight: CGFloat = {
            if store.receipt.isAllDone { return 48 }
            if store.settings.pushUrgeEnabled && store.isViewingActiveDay && !store.receipt.items.isEmpty {
                return 22
            }
            return 0
        }()

        let totalHeight = min(
            max(baseHeight + listHeight + reminderHeight + rolloverHeight + recordingHeight + aiErrorHeight + toastHeight + pushFooterHeight, 560),
            960
        )
        return CGSize(width: expandedWidth, height: totalHeight)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticResize else { return }
        let frame = panel.frame
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let isLeft: Bool
        if let visible = screen?.visibleFrame {
            isLeft = frame.midX < visible.midX
        } else {
            isLeft = false
        }
        if store.isAnchoredLeft != isLeft {
            store.isAnchoredLeft = isLeft
        }
        saveAnchor(from: frame, isLeft: isLeft)
    }

    private func saveAnchor(from frame: NSRect, isLeft: Bool) {
        let edgeX = isLeft ? frame.minX : frame.maxX
        UserDefaults.standard.set(Double(edgeX), forKey: anchorEdgeXKey)
        UserDefaults.standard.set(Double(frame.maxY), forKey: anchorTopYKey)
        UserDefaults.standard.set(isLeft, forKey: anchorLeftKey)
    }

    private func restoreAnchorOrDefault() {
        let defaults = UserDefaults.standard
        let size = desiredSize()
        if defaults.object(forKey: anchorEdgeXKey) != nil,
           defaults.object(forKey: anchorTopYKey) != nil {
            let isLeft = defaults.bool(forKey: anchorLeftKey)
            let edgeX = CGFloat(defaults.double(forKey: anchorEdgeXKey))
            let topY = CGFloat(defaults.double(forKey: anchorTopYKey))
            store.isAnchoredLeft = isLeft

            let originX = isLeft ? edgeX : (edgeX - size.width)
            var frame = NSRect(
                x: originX,
                y: topY - size.height,
                width: size.width,
                height: size.height
            )
            frame = clampFrameToVisibleScreen(frame)
            panel.setFrame(frame, display: false)
        } else {
            store.isAnchoredLeft = false
            let frame = Self.defaultFrame(for: size)
            panel.setFrame(frame, display: false)
        }
    }

    private func clampFrameToVisibleScreen(_ frame: NSRect) -> NSRect {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return frame }
        var clamped = frame
        let margin: CGFloat = 8
        if clamped.maxX > visible.maxX - margin {
            clamped.origin.x = visible.maxX - margin - clamped.width
        }
        if clamped.minX < visible.minX + margin {
            clamped.origin.x = visible.minX + margin
        }
        if clamped.maxY > visible.maxY - margin {
            clamped.origin.y = visible.maxY - margin - clamped.height
        }
        if clamped.minY < visible.minY + margin {
            clamped.origin.y = visible.minY + margin
        }
        return clamped
    }

    private static func defaultFrame(for size: CGSize) -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 18
        return NSRect(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Settings Window

    func showSettingsWindow() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(store: store) { [weak self] in
            self?.settingsWindow?.close()
        }
        let hosting = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "小票待办 · 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ReceiptTodoSettingsWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    // MARK: - Frameless Direct-Display Torn-Off Check-In Poster

    func showShareWindow(receipt: DailyReceipt, streakDays: Int, canUndoTearOff: Bool) {
        shareWindow?.close()
        shareWindow = nil

        let view = ShareReceiptWindowView(
            receipt: receipt,
            streakDays: streakDays,
            canUndoTearOff: canUndoTearOff,
            onUndoTearOff: { [weak self] in
                self?.store.undoTearOffToday()
            },
            onClose: { [weak self] in
                self?.shareWindow?.close()
                self?.shareWindow = nil
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        let fitSize = hosting.fittingSize
        let width = max(436, fitSize.width)
        let height = min(736, max(440, fitSize.height))

        // Place gracefully right beside the receipt printer so it feels like the torn sheet landed beside it!
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let widgetFrame = panel.frame
        let preferredX: CGFloat = store.isAnchoredLeft
            ? (widgetFrame.maxX + 16)
            : (widgetFrame.minX - width - 16)
        var targetFrame = NSRect(
            x: preferredX,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
        // Clamp neatly inside screen bounds
        let margin: CGFloat = 18
        if targetFrame.minX < visible.minX + margin || targetFrame.maxX > visible.maxX - margin {
            targetFrame.origin.x = visible.midX - width / 2
        }
        if targetFrame.maxY > visible.maxY - margin {
            targetFrame.origin.y = visible.maxY - margin - height
        }
        if targetFrame.minY < visible.minY + margin {
            targetFrame.origin.y = visible.minY + margin
        }

        let posterPanel = SharePosterPanel(contentRect: targetFrame)
        posterPanel.contentView = hosting
        posterPanel.onEscapeClose = { [weak self] in
            self?.shareWindow?.close()
            self?.shareWindow = nil
        }
        posterPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.shareWindow = posterPanel
    }
}
