import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class TodoStore: ObservableObject {
    @Published var receipt: DailyReceipt
    @Published var settings: AppSettings
    @Published var isExpanded: Bool = true
    @Published var isAnchoredLeft: Bool = false
    @Published var paperReveal: CGFloat = 1.0
    @Published var isPrinting: Bool = false
    @Published var isParsingVoice: Bool = false {
        didSet {
            if oldValue != isParsingVoice {
                onWindowLayoutChange?(true)
            }
        }
    }
    @Published var toastMessage: String?
    @Published var aiErrorBanner: String? {
        didSet {
            if oldValue != aiErrorBanner {
                onWindowLayoutChange?(true)
            }
        }
    }
    @Published var lastFailedTranscript: String?

    // Cross-weekend / selective Carry-Over state
    @Published var carryOverSourceDate: String?
    @Published var carryOverCandidates: [TodoItem] = []
    @Published var selectedCarryOverIDs: Set<UUID> = []
    @Published var isCarryOverPickerOpen: Bool = false {
        didSet {
            if oldValue != isCarryOverPickerOpen {
                onWindowLayoutChange?(true)
            }
        }
    }

    // History receipt paging
    @Published var availableDates: [String] = []
    @Published var streakDays: Int = 0
    @Published var newlyAddedIDs: Set<UUID> = []

    // End-of-day gentle physical pull-to-tear state (Option A: tear today -> frameless share poster + serene NEXT ROLL stub)
    @Published var isTodayTornOff: Bool = false
    @Published var isPlanningTomorrow: Bool = false {
        didSet {
            if oldValue != isPlanningTomorrow {
                onWindowLayoutChange?(true)
            }
        }
    }
    @Published var tornOffTodayDoneCount: Int = 0
    @Published var tornOffTodayTotalCount: Int = 0
    @Published var tearPullDistance: CGFloat = 0.0
    @Published var tearProgress: CGFloat = 0.0
    @Published var tearDriftProgress: CGFloat = 0.0
    @Published var isTearingOff: Bool = false
    var isRenderingStaticPreview: Bool = false

    // Focus Lock Mode (single-task inverted black strip) & gentle overdue sway
    @Published var focusedItemID: UUID? {
        didSet {
            if oldValue != focusedItemID {
                onWindowLayoutChange?(true)
            }
        }
    }
    @Published var focusElapsedSeconds: Int = 0
    @Published var paperNudgeAngle: Double = 0.0

    @Published var activeReminderItemID: UUID? {
        didSet {
            if oldValue != activeReminderItemID {
                onWindowLayoutChange?(true)
            }
        }
    }
    @Published var currentMinutesOfDay: Int = TimeParser.currentMinutesOfDay()

    let speechService = SpeechService()

    var onWindowLayoutChange: ((Bool) -> Void)?
    var onAlwaysOnTopChange: ((Bool) -> Void)?
    var onGlobalHotkeyChange: ((Bool, GlobalHotkeyConfig) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onResetPosition: (() -> Void)?
    var onShowShareCard: ((DailyReceipt, Int, Bool) -> Void)?
    var onCloseShareCard: (() -> Void)?

    private let storage = StorageService.shared
    private let planner = LLMPlannerService.shared
    private let sound = ThermalSoundEngine.shared
    private var cancellables = Set<AnyCancellable>()
    private var clockTimer: Timer?
    private var focusTimer: Timer?
    private var lastNudgeDate: Date?
    private var toastTask: Task<Void, Never>?
    private var printTask: Task<Void, Never>?
    private var tearTask: Task<Void, Never>?
    private var nudgeTask: Task<Void, Never>?
    private var lastTearHapticStage: Int = 0
    private var lastTearSoundStep: Int = 0

    private let handledCarryOverKeyPrefix = "ReceiptTodo.HandledCarryOver."
    private let tornOffDateKey = "ReceiptTodo.TornOffDate"

    var todayDateString: String {
        DailyReceipt.dateKey(for: Date())
    }

    var tomorrowDate: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }

    var tomorrowDateString: String {
        DailyReceipt.dateKey(for: tomorrowDate)
    }

    /// After tearing off today, the active working sheet advances cleanly to Tomorrow; otherwise Today.
    var activeWorkingDate: Date {
        isTodayTornOff ? tomorrowDate : Date()
    }

    var activeWorkingDateString: String {
        isTodayTornOff ? tomorrowDateString : todayDateString
    }

    var isViewingToday: Bool {
        receipt.dateString == todayDateString
    }

    var isViewingTomorrow: Bool {
        isTodayTornOff && receipt.dateString == tomorrowDateString
    }

    var isViewingActiveDay: Bool {
        receipt.dateString == activeWorkingDateString
    }

    var isViewingTornOffTodayArchive: Bool {
        isTodayTornOff && receipt.dateString == todayDateString
    }

    /// True right after tearing off today: shows the serene compact NEXT ROLL stub until user clicks "写明天".
    var isShowingPostTearStub: Bool {
        isTodayTornOff && !isPlanningTomorrow && receipt.dateString == tomorrowDateString
    }

    var canTearOffCurrentReceipt: Bool {
        isViewingToday && !isTodayTornOff && !receipt.items.isEmpty && !isPrinting && !isTearingOff && !speechService.isRecording && !isParsingVoice
    }

    var canGoPreviousDate: Bool {
        guard let idx = availableDates.firstIndex(of: receipt.dateString) else { return false }
        return idx > 0
    }

    var canGoNextDate: Bool {
        guard let idx = availableDates.firstIndex(of: receipt.dateString) else { return false }
        return idx < availableDates.count - 1
    }

    var activeReminderItem: TodoItem? {
        guard isViewingToday, !isTodayTornOff, let id = activeReminderItemID else { return nil }
        return receipt.items.first { $0.id == id && !$0.isDone && !$0.reminderDismissed }
    }

    /// Timed tasks sorted chronologically (ascending by scheduledMinutes)
    var timedItems: [TodoItem] {
        receipt.items
            .filter { $0.scheduledMinutes != nil }
            .sorted { ($0.scheduledMinutes ?? 0) < ($1.scheduledMinutes ?? 0) }
    }

    /// Untimed tasks preserving natural order
    var untimedItems: [TodoItem] {
        receipt.items.filter { $0.scheduledMinutes == nil }
    }

    /// Next upcoming (or currently due) unchecked timed task for collapsed stub preview
    var nextUpcomingTimedItem: TodoItem? {
        guard isViewingToday && !isTodayTornOff else { return nil }
        return timedItems.first { !$0.isDone }
    }

    func isItemDue(_ item: TodoItem) -> Bool {
        guard isViewingToday, !isTodayTornOff, !item.isDone, let mins = item.scheduledMinutes else { return false }
        return mins <= currentMinutesOfDay
    }

    var remainingCount: Int {
        max(0, receipt.totalCount - receipt.doneCount)
    }

    var focusedItem: TodoItem? {
        guard let id = focusedItemID else { return nil }
        return receipt.items.first { $0.id == id && !$0.isDone }
    }

    var formattedFocusElapsed: String {
        let hrs = focusElapsedSeconds / 3600
        let mins = (focusElapsedSeconds % 3600) / 60
        let secs = focusElapsedSeconds % 60
        if hrs > 0 {
            return String(format: "%02d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    /// Minutes past scheduled time (returns >= 1 when genuinely overdue on active today).
    func overdueMinutes(for item: TodoItem) -> Int? {
        guard isViewingToday, !isTodayTornOff, !item.isDone, let mins = item.scheduledMinutes else { return nil }
        let delta = currentMinutesOfDay - mins
        return delta >= 1 ? delta : nil
    }

    func overdueCompactLabel(for item: TodoItem) -> String? {
        guard settings.pushUrgeEnabled, let mins = overdueMinutes(for: item) else { return nil }
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m == 0 ? "+\(h)h" : "+\(h)h\(m)m"
        }
        return "+\(mins)m"
    }

    var hasOverdueItem: Bool {
        guard isViewingToday, !isTodayTornOff else { return false }
        return timedItems.contains { overdueMinutes(for: $0) != nil }
    }

    var bezelLampStyle: BezelLampStyle {
        if isTodayTornOff || !isViewingToday {
            return .standbyDim
        }
        if receipt.items.isEmpty || receipt.isAllDone {
            return .calmGreen
        }
        if settings.pushUrgeEnabled && hasOverdueItem {
            return .urgentRedPulse
        }
        if settings.pushUrgeEnabled && remainingCount > 0 {
            return .openAmberPulse
        }
        return .calmGreen
    }

    // MARK: - Focus Lock Mode (Single-Task Black Strip)

    func startFocusing(on item: TodoItem) {
        guard !item.isDone else { return }
        if speechService.isRecording {
            speechService.cancelRecording()
        }
        focusTimer?.invalidate()
        focusedItemID = item.id
        focusElapsedSeconds = 0
        isExpanded = true
        paperReveal = 1.0
        onWindowLayoutChange?(true)
        sound.playShortLineFeed(enabled: settings.soundEnabled)

        focusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.focusedItemID != nil else { return }
                self.focusElapsedSeconds += 1
            }
        }
    }

    func exitFocusMode() {
        focusTimer?.invalidate()
        focusTimer = nil
        focusedItemID = nil
        focusElapsedSeconds = 0
        onWindowLayoutChange?(true)
    }

    func completeFocusedItem() {
        guard let id = focusedItemID else { return }
        focusTimer?.invalidate()
        focusTimer = nil
        focusedItemID = nil
        focusElapsedSeconds = 0
        toggleItem(id)
    }

    /// Subtle 0.48s pendulum paper sway when an overdue task remains unchecked (peripheral nudge, never intrusive).
    func triggerGentlePaperNudge() {
        guard isExpanded, !isTearingOff, focusedItemID == nil, !isShowingPostTearStub else { return }
        nudgeTask?.cancel()
        nudgeTask = Task { [weak self] in
            guard let self else { return }
            let frames: [(Double, Double)] = [
                (1.25, 0.11),
                (-0.95, 0.12),
                (0.55, 0.11),
                (-0.22, 0.09),
                (0.0, 0.10)
            ]
            for (angle, dur) in frames {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: dur)) {
                    self.paperNudgeAngle = angle
                }
                try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
            }
        }
    }

    init() {
        let today = Date()
        let todayKey = DailyReceipt.dateKey(for: today)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
        let tomorrowKey = DailyReceipt.dateKey(for: tomorrow)
        let loadedSettings = StorageService.shared.loadSettings()
        let todayReceipt = StorageService.shared.loadReceipt(dateString: todayKey)
        let tornOffDate = UserDefaults.standard.string(forKey: "ReceiptTodo.TornOffDate")
        let alreadyTornOffToday = (tornOffDate == todayKey)
        let tomorrowReceipt = alreadyTornOffToday ? StorageService.shared.loadReceipt(dateString: tomorrowKey) : nil

        self.settings = loadedSettings
        self.isTodayTornOff = alreadyTornOffToday
        self.isPlanningTomorrow = alreadyTornOffToday && !(tomorrowReceipt?.items.isEmpty ?? true)
        self.tornOffTodayDoneCount = todayReceipt.doneCount
        self.tornOffTodayTotalCount = todayReceipt.totalCount
        self.receipt = tomorrowReceipt ?? todayReceipt
        self.availableDates = StorageService.shared.listReceiptDates(
            includingToday: todayKey,
            extraDates: alreadyTornOffToday ? [tomorrowKey] : []
        )
        self.streakDays = StorageService.shared.calculateStreak(todayReceipt: todayReceipt, relativeTo: today)

        refreshCarryOverCandidates(for: alreadyTornOffToday ? tomorrow : today)

        speechService.$isRecording
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onWindowLayoutChange?(true)
            }
            .store(in: &cancellables)

        speechService.$permissionError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in
                self?.showToast(err, duration: 5.0)
            }
            .store(in: &cancellables)

        setupClockWatcher()
        evaluateReminders(allowAlert: false)
    }

    private func setupClockWatcher() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.checkDateRollover()
                self.currentMinutesOfDay = TimeParser.currentMinutesOfDay()
                self.evaluateReminders(allowAlert: true)
                self.evaluateOverdueNudge()
            }
        }
    }

    private func evaluateOverdueNudge() {
        guard settings.pushUrgeEnabled, isViewingToday, !isTodayTornOff, isExpanded, focusedItemID == nil else { return }
        let hasLongOverdue = timedItems.contains { (overdueMinutes(for: $0) ?? 0) >= 10 }
        guard hasLongOverdue else { return }
        let now = Date()
        if let last = lastNudgeDate, now.timeIntervalSince(last) < 600 {
            return
        }
        lastNudgeDate = now
        triggerGentlePaperNudge()
    }

    func checkDateRollover() {
        let currentKey = todayDateString
        // Once midnight passes past the torn-off day, Tomorrow seamlessly becomes real Today!
        if isTodayTornOff && UserDefaults.standard.string(forKey: tornOffDateKey) != currentKey {
            isTodayTornOff = false
            isPlanningTomorrow = false
            availableDates = storage.listReceiptDates(includingToday: currentKey)
            if receipt.dateString == currentKey {
                refreshCarryOverCandidates(for: Date())
                streakDays = storage.calculateStreak(todayReceipt: receipt, relativeTo: Date())
                evaluateReminders(allowAlert: false)
                onWindowLayoutChange?(true)
                return
            }
        }

        if !availableDates.contains(currentKey) {
            availableDates = storage.listReceiptDates(
                includingToday: currentKey,
                extraDates: isTodayTornOff ? [tomorrowDateString] : []
            )
        }

        // Only auto-advance if user was viewing yesterday (not intentionally browsing older archive)
        let yesterdayKey = Calendar.current.date(byAdding: .day, value: -1, to: Date()).map(DailyReceipt.dateKey)
        if receipt.dateString == yesterdayKey && receipt.dateString != currentKey {
            receipt = storage.loadReceipt(dateString: currentKey)
            isTodayTornOff = false
            isPlanningTomorrow = false
            refreshCarryOverCandidates(for: Date())
            streakDays = storage.calculateStreak(todayReceipt: receipt, relativeTo: Date())
            onWindowLayoutChange?(true)
        }
    }

    // MARK: - History Receipt Navigation

    func goToPreviousDate() {
        guard let idx = availableDates.firstIndex(of: receipt.dateString), idx > 0 else { return }
        switchViewingDate(to: availableDates[idx - 1])
    }

    func goToNextDate() {
        guard let idx = availableDates.firstIndex(of: receipt.dateString), idx < availableDates.count - 1 else { return }
        switchViewingDate(to: availableDates[idx + 1])
    }

    func goToActiveDay() {
        switchViewingDate(to: activeWorkingDateString)
    }

    func goToToday() {
        switchViewingDate(to: activeWorkingDateString)
    }

    private func switchViewingDate(to dateString: String) {
        if speechService.isRecording {
            speechService.cancelRecording()
        }
        aiErrorBanner = nil
        isCarryOverPickerOpen = false
        receipt = storage.loadReceipt(dateString: dateString)
        if dateString == activeWorkingDateString {
            refreshCarryOverCandidates(for: activeWorkingDate)
        }
        evaluateReminders(allowAlert: false)
        onWindowLayoutChange?(true)
    }

    /// Pulls a single unfinished item from a historical archive receipt into the active working receipt (Today or Tomorrow).
    func copyArchiveItemToToday(_ item: TodoItem) {
        let targetDateKey = activeWorkingDateString
        var targetReceipt = storage.loadReceipt(dateString: targetDateKey)
        let existing = Set(targetReceipt.items.map { $0.title.lowercased() })
        if existing.contains(item.title.lowercased()) {
            showToast(isTodayTornOff ? "明日小票中已有相同事项" : "今日小票中已有相同事项", duration: 2.0)
            return
        }
        let rolled = TodoItem(
            title: item.title,
            timeHint: nil,
            scheduledMinutes: nil,
            carryOverDays: item.carryOverDays + 1,
            source: .rollover
        )
        targetReceipt.items.append(rolled)
        storage.saveReceipt(targetReceipt)
        receipt = targetReceipt
        newlyAddedIDs.insert(rolled.id)
        availableDates = storage.listReceiptDates(
            includingToday: todayDateString,
            extraDates: isTodayTornOff ? [tomorrowDateString] : []
        )
        playThermalPrintFeed(steps: 3, startReveal: 0.78, fullAudio: false)
        let label = isTodayTornOff ? "明日小票" : "今日小票"
        showToast("已将「\(item.title)」顺延到\(label)", duration: 2.2)
        scheduleClearHighlight(ids: [rolled.id])
    }

    // MARK: - Cross-Weekend Selective Carry-Over

    private func refreshCarryOverCandidates(for today: Date) {
        let todayKey = DailyReceipt.dateKey(for: today)
        let handledKey = handledCarryOverKeyPrefix + todayKey
        if UserDefaults.standard.bool(forKey: handledKey) {
            carryOverSourceDate = nil
            carryOverCandidates = []
            selectedCarryOverIDs = []
            return
        }

        if let latest = storage.loadLatestUnfinishedBefore(today: today) {
            let todayTitles = Set(receipt.items.map { $0.title.lowercased() })
            let filtered = latest.items.filter { !todayTitles.contains($0.title.lowercased()) }
            if !filtered.isEmpty {
                carryOverSourceDate = latest.sourceDate
                carryOverCandidates = filtered
                selectedCarryOverIDs = Set(filtered.map(\.id))
                return
            }
        }
        carryOverSourceDate = nil
        carryOverCandidates = []
        selectedCarryOverIDs = []
    }

    func toggleCarryOverSelection(_ id: UUID) {
        if selectedCarryOverIDs.contains(id) {
            selectedCarryOverIDs.remove(id)
        } else {
            selectedCarryOverIDs.insert(id)
        }
    }

    func rolloverAllCarryOver() {
        selectedCarryOverIDs = Set(carryOverCandidates.map(\.id))
        confirmCarryOverSelected()
    }

    func confirmCarryOverSelected() {
        let chosen = carryOverCandidates.filter { selectedCarryOverIDs.contains($0.id) }
        markCarryOverHandledForActiveDay()
        guard !chosen.isEmpty else {
            onWindowLayoutChange?(true)
            return
        }

        if !isViewingActiveDay {
            receipt = storage.loadReceipt(dateString: activeWorkingDateString)
        }

        let existingTitles = Set(receipt.items.map { $0.title.lowercased() })
        var addedIDs: [UUID] = []

        for old in chosen {
            guard !existingTitles.contains(old.title.lowercased()) else { continue }
            // Carry over with incremented +1D badge, clearing expired alarm times from previous day!
            let rolled = TodoItem(
                title: old.title,
                timeHint: nil,
                scheduledMinutes: nil,
                carryOverDays: old.carryOverDays + 1,
                source: .rollover
            )
            receipt.items.append(rolled)
            newlyAddedIDs.insert(rolled.id)
            addedIDs.append(rolled.id)
        }

        if !addedIDs.isEmpty {
            persistReceipt()
            playThermalPrintFeed(steps: min(8, max(4, addedIDs.count + 3)), startReveal: 0.12)
            showToast("已顺延打印 \(addedIDs.count) 条上期未完成事项", duration: 2.5)
            scheduleClearHighlight(ids: addedIDs)
        }
    }

    func dismissCarryOver() {
        withAnimation(.easeOut(duration: 0.2)) {
            markCarryOverHandledForActiveDay()
        }
        onWindowLayoutChange?(true)
    }

    private func markCarryOverHandledForActiveDay() {
        UserDefaults.standard.set(true, forKey: handledCarryOverKeyPrefix + activeWorkingDateString)
        carryOverSourceDate = nil
        carryOverCandidates = []
        selectedCarryOverIDs = []
        isCarryOverPickerOpen = false
    }

    // MARK: - Reminders

    func evaluateReminders(allowAlert: Bool) {
        currentMinutesOfDay = TimeParser.currentMinutesOfDay()
        guard isViewingToday && !isTodayTornOff else {
            activeReminderItemID = nil
            return
        }
        let dueItem = timedItems.first { item in
            guard !item.isDone, !item.reminderDismissed, let mins = item.scheduledMinutes else { return false }
            return mins <= currentMinutesOfDay
        }

        let previousID = activeReminderItemID
        activeReminderItemID = dueItem?.id

        if allowAlert, let due = dueItem, due.id != previousID {
            if !isExpanded {
                expandFromSlot()
            }
            sound.playReminderChime(enabled: settings.soundEnabled)
        }
    }

    func completeActiveReminder() {
        guard let id = activeReminderItemID else { return }
        toggleItem(id)
        evaluateReminders(allowAlert: false)
    }

    func snoozeActiveReminder(minutes: Int = 10) {
        guard let id = activeReminderItemID,
              let idx = receipt.items.firstIndex(where: { $0.id == id }) else { return }
        let base = max(currentMinutesOfDay, receipt.items[idx].scheduledMinutes ?? currentMinutesOfDay)
        let newMins = min(1439, base + minutes)
        let formatted = TodoItem.formatMinutes(newMins)
        receipt.items[idx].scheduledMinutes = newMins
        receipt.items[idx].timeHint = formatted
        receipt.items[idx].reminderDismissed = false
        persistReceipt()
        evaluateReminders(allowAlert: false)
        showToast("已推迟至 \(formatted) 提醒", duration: 2.2)
    }

    func dismissActiveReminder() {
        guard let id = activeReminderItemID,
              let idx = receipt.items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            receipt.items[idx].reminderDismissed = true
        }
        persistReceipt()
        evaluateReminders(allowAlert: false)
    }

    // MARK: - Expand / Collapse with Physical Slot Feed & Retract

    func toggleExpanded() {
        if isExpanded {
            collapseToSlot()
        } else {
            expandFromSlot()
        }
    }

    func expandFromSlot() {
        guard !isExpanded else { return }
        resetTearPhysicsImmediate()
        printTask?.cancel()
        paperReveal = 0.0
        isExpanded = true
        onWindowLayoutChange?(false)

        printTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
            self.sound.playShortLineFeed(enabled: self.settings.soundEnabled)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                self.paperReveal = 1.0
            }
        }
    }

    // MARK: - End-of-Day Gentle Physical Pull-to-Tear Interaction (Option A)

    func resetTearPhysicsImmediate() {
        tearTask?.cancel()
        tearPullDistance = 0
        tearProgress = 0
        tearDriftProgress = 0
        isTearingOff = false
        lastTearHapticStage = 0
        lastTearSoundStep = 0
    }

    func updateManualTear(pullDistance: CGFloat) {
        guard canTearOffCurrentReceipt else { return }
        let clampedPull = max(0, min(140, pullDistance))
        tearPullDistance = clampedPull

        // Stage 1 (0..22pt): soft tension before perforation begins unzipping
        // Stage 2 (22..106pt): smooth progressive left-to-right unzip (0.0 -> 1.0)
        let rawProgress: CGFloat
        if clampedPull <= 22 {
            rawProgress = 0
        } else {
            rawProgress = min(1.0, (clampedPull - 22) / 84.0)
        }
        tearProgress = rawProgress

        // Real-time progressive paper-tearing sound synced to hand pull across 8 perforation teeth!
        let soundStep = rawProgress > 0.05 ? Int(floor(rawProgress * 8.0)) + 1 : 0
        if soundStep > lastTearSoundStep {
            sound.playTearStep(progress: rawProgress, enabled: settings.soundEnabled)
            lastTearSoundStep = soundStep
        } else if soundStep < lastTearSoundStep {
            lastTearSoundStep = soundStep
        }

        // Subtle Force Touch tactile ticks along the perforation teeth
        let stage: Int
        if rawProgress >= 0.92 { stage = 4 }
        else if rawProgress >= 0.68 { stage = 3 }
        else if rawProgress >= 0.40 { stage = 2 }
        else if rawProgress >= 0.14 { stage = 1 }
        else { stage = 0 }

        if stage > lastTearHapticStage {
            NSHapticFeedbackManager.defaultPerformer.perform(
                stage == 4 ? .levelChange : .alignment,
                performanceTime: .now
            )
            lastTearHapticStage = stage
        } else if stage < lastTearHapticStage {
            lastTearHapticStage = stage
        }

        // If user gently pulled all the way to full separation, detach smoothly!
        if rawProgress >= 0.995 && !isTearingOff {
            completeTearOffSequence(alreadyUnzipped: true)
        }
    }

    func finishManualTear(pullDistance: CGFloat) {
        guard !isTearingOff else { return }
        // Only tear off if user clearly passed the perforation threshold (>= 70%)
        if tearProgress >= 0.70 {
            completeTearOffSequence(alreadyUnzipped: false)
        } else {
            // Gently spring back up into the slot without tearing
            lastTearHapticStage = 0
            lastTearSoundStep = 0
            withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
                tearPullDistance = 0
                tearProgress = 0
            }
        }
    }

    /// Triggered from right-click / menu bar: plays the same gentle progressive left-to-right tear with real sound.
    func triggerAnimatedTearOff() {
        guard isViewingToday, !isTodayTornOff, !receipt.items.isEmpty, !isTearingOff else {
            if isTodayTornOff {
                showToast("今日小票已经撕下归档，可点击上方翻看历史或撤销", duration: 2.4)
            } else if receipt.items.isEmpty {
                showToast("今日还没有待办事项可撕下", duration: 2.0)
            }
            return
        }
        if !isExpanded {
            expandFromSlot()
        }
        if speechService.isRecording {
            speechService.cancelRecording()
        }

        tearTask?.cancel()
        isTearingOff = true
        tearDriftProgress = 0
        lastTearSoundStep = 0

        tearTask = Task { [weak self] in
            guard let self else { return }
            // Brief calm tension down-pull
            withAnimation(.easeOut(duration: 0.15)) {
                self.tearPullDistance = 24
                self.tearProgress = 0.04
            }
            try? await Task.sleep(nanoseconds: 155_000_000)
            guard !Task.isCancelled else { return }

            // Progressive left-to-right unzip across the cutter teeth with live paper-rip audio
            let steps = 16
            for i in 1...steps {
                guard !Task.isCancelled else { return }
                let frac = CGFloat(i) / CGFloat(steps)
                let eased = 1.0 - pow(1.0 - frac, 1.35)
                withAnimation(.linear(duration: 0.036)) {
                    self.tearProgress = eased
                    self.tearPullDistance = 24 + eased * 82
                }
                if i % 2 == 1 {
                    self.sound.playTearStep(progress: eased, enabled: self.settings.soundEnabled)
                }
                if i == 3 || i == 9 || i == 15 {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                try? await Task.sleep(nanoseconds: 36_000_000)
            }

            guard !Task.isCancelled else { return }
            await self.runPostUnzipFloatAway()
        }
    }

    private func completeTearOffSequence(alreadyUnzipped: Bool) {
        guard !isTearingOff else { return }
        tearTask?.cancel()
        isTearingOff = true

        tearTask = Task { [weak self] in
            guard let self else { return }
            if !alreadyUnzipped {
                self.sound.playTearStep(progress: 0.92, enabled: self.settings.soundEnabled)
                withAnimation(.easeOut(duration: 0.14)) {
                    self.tearProgress = 1.0
                    self.tearPullDistance = max(self.tearPullDistance, 108)
                }
                try? await Task.sleep(nanoseconds: 130_000_000)
                guard !Task.isCancelled else { return }
            }
            await self.runPostUnzipFloatAway()
        }
    }

    private func runPostUnzipFloatAway() async {
        // Snapshot & safely archive today's receipt
        persistReceipt()
        let tornSnapshot = receipt
        let snapshotStreak = streakDays

        // Crisp final thermal-paper detachment sound
        sound.playPaperTear(enabled: settings.soundEnabled)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        // Peaceful, feather-light downward drift & fade
        withAnimation(.easeOut(duration: 0.52)) {
            self.tearDriftProgress = 1.0
        }

        try? await Task.sleep(nanoseconds: 540_000_000)
        guard !Task.isCancelled else { return }

        // 1. Mark today torn off & transition slot cleanly to the serene short NEXT ROLL stub!
        let todayKey = todayDateString
        let nextDate = tomorrowDate
        let nextKey = DailyReceipt.dateKey(for: nextDate)
        UserDefaults.standard.set(todayKey, forKey: tornOffDateKey)

        tornOffTodayDoneCount = tornSnapshot.doneCount
        tornOffTodayTotalCount = tornSnapshot.totalCount
        isTodayTornOff = true
        isPlanningTomorrow = false
        tearPullDistance = 0
        tearProgress = 0
        tearDriftProgress = 0
        isTearingOff = false
        lastTearHapticStage = 0
        lastTearSoundStep = 0
        paperReveal = 0.0

        receipt = storage.loadReceipt(dateString: nextKey)
        availableDates = storage.listReceiptDates(includingToday: todayKey, extraDates: [nextKey])
        refreshCarryOverCandidates(for: nextDate)
        evaluateReminders(allowAlert: false)
        onWindowLayoutChange?(true)

        // 2. Display the torn-off shareable check-in poster DIRECTLY on screen!
        onShowShareCard?(tornSnapshot, snapshotStreak, true)

        // 3. After a calm brief empty-slot beat, gently peek out the short fresh NEXT ROLL stub!
        try? await Task.sleep(nanoseconds: 240_000_000)
        guard !Task.isCancelled else { return }
        playThermalPrintFeed(steps: 4, startReveal: 0.04, fullAudio: false)
    }

    /// Expands the serene NEXT ROLL stub into Tomorrow's full editable receipt on demand.
    func startPlanningTomorrow() {
        guard isTodayTornOff else { return }
        isPlanningTomorrow = true
        if receipt.dateString != tomorrowDateString {
            receipt = storage.loadReceipt(dateString: tomorrowDateString)
            refreshCarryOverCandidates(for: tomorrowDate)
        }
        if !isExpanded {
            isExpanded = true
        }
        onWindowLayoutChange?(true)
        playThermalPrintFeed(steps: 5, startReveal: 0.14, fullAudio: false)
    }

    /// Reverses today's tear-off: retracts Tomorrow's stub/sheet and cleanly restores Today's receipt back into the slot.
    func undoTearOffToday() {
        guard isTodayTornOff else { return }
        tearTask?.cancel()
        onCloseShareCard?()
        UserDefaults.standard.removeObject(forKey: tornOffDateKey)
        isTodayTornOff = false
        isPlanningTomorrow = false
        resetTearPhysicsImmediate()

        let todayKey = todayDateString
        receipt = storage.loadReceipt(dateString: todayKey)
        availableDates = storage.listReceiptDates(includingToday: todayKey)
        refreshCarryOverCandidates(for: Date())
        evaluateReminders(allowAlert: false)
        if !isExpanded {
            isExpanded = true
        }
        onWindowLayoutChange?(true)
        playThermalPrintFeed(steps: 5, startReveal: 0.06, fullAudio: false)
        showToast("已复原今日小票", duration: 2.2)
    }

    /// Opens the frameless shareable poster for today's torn-off receipt directly from the NEXT ROLL stub.
    func openShareCardForTornOffToday() {
        let todayReceipt = storage.loadReceipt(dateString: todayDateString)
        guard !todayReceipt.items.isEmpty else {
            showToast("今日没有待办记录可生成打卡图", duration: 2.0)
            return
        }
        onShowShareCard?(todayReceipt, streakDays, true)
    }

    /// Opens the shareable Check-In Poster for whichever receipt is currently displayed (or torn-off today if on stub).
    func openShareCardForCurrentReceipt() {
        if isShowingPostTearStub {
            openShareCardForTornOffToday()
            return
        }
        guard !receipt.items.isEmpty else {
            showToast("当前小票还没有待办内容可生成打卡图", duration: 2.2)
            return
        }
        onShowShareCard?(receipt, streakDays, isViewingTornOffTodayArchive)
    }

    func collapseToSlot() {
        guard isExpanded else { return }
        if speechService.isRecording {
            speechService.cancelRecording()
        }
        printTask?.cancel()
        sound.stopPrintSound()
        isPrinting = false

        printTask = Task { [weak self] in
            guard let self else { return }
            self.sound.playShortLineFeed(enabled: self.settings.soundEnabled)
            withAnimation(.easeIn(duration: 0.22)) {
                self.paperReveal = 0.0
            }
            try? await Task.sleep(nanoseconds: 230_000_000)
            guard !Task.isCancelled else { return }
            self.isExpanded = false
            self.onWindowLayoutChange?(true)
        }
    }

    func playThermalPrintFeed(steps: Int = 9, startReveal: CGFloat = 0.04, fullAudio: Bool = true) {
        printTask?.cancel()
        if !isExpanded {
            isExpanded = true
        }
        isPrinting = true
        paperReveal = startReveal
        onWindowLayoutChange?(false)

        printTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 25_000_000)

            if fullAudio {
                self.sound.playFullReceiptPrint(enabled: self.settings.soundEnabled)
            } else {
                self.sound.playShortLineFeed(enabled: self.settings.soundEnabled)
            }

            let totalSteps = max(2, steps)
            let totalFeedNs: UInt64 = fullAudio ? 1_080_000_000 : 260_000_000
            let stepIntervalNs = totalFeedNs / UInt64(totalSteps)

            for step in 1...totalSteps {
                guard !Task.isCancelled else { return }
                let fraction = CGFloat(step) / CGFloat(totalSteps)
                let targetReveal = startReveal + (1.0 - startReveal) * fraction
                withAnimation(.easeOut(duration: Double(stepIntervalNs) / 1_000_000_000.0 * 0.85)) {
                    self.paperReveal = min(1.0, targetReveal)
                }
                try? await Task.sleep(nanoseconds: stepIntervalNs)
            }

            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.06)) {
                self.paperReveal = 1.014
            }
            try? await Task.sleep(nanoseconds: 65_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) {
                self.paperReveal = 1.0
                self.isPrinting = false
            }
        }
    }

    func replayPrintAnimation() {
        playThermalPrintFeed(steps: 10, startReveal: 0.02, fullAudio: true)
    }

    // MARK: - Task Mutations

    func addManualItem(title: String, timeHint: String? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !isViewingActiveDay {
            goToActiveDay()
        }
        checkDateRollover()

        let parsed = TimeParser.parseManualOrFallback(trimmed)
        let finalTitle = parsed.cleanedTitle.isEmpty ? trimmed : parsed.cleanedTitle
        let finalHint = timeHint ?? parsed.timeHint
        let item = TodoItem(
            title: finalTitle,
            timeHint: finalHint,
            scheduledMinutes: parsed.scheduledMinutes,
            source: .manual
        )
        receipt.items.append(item)
        newlyAddedIDs.insert(item.id)
        persistReceipt()
        evaluateReminders(allowAlert: true)

        playThermalPrintFeed(steps: 2, startReveal: 0.88, fullAudio: false)
        scheduleClearHighlight(ids: [item.id])
    }

    func toggleItem(_ id: UUID) {
        guard let idx = receipt.items.firstIndex(where: { $0.id == id }) else { return }
        let wasAllDone = receipt.isAllDone
        withAnimation(.spring(response: 0.26, dampingFraction: 0.80)) {
            receipt.items[idx].isDone.toggle()
            receipt.items[idx].doneAt = receipt.items[idx].isDone ? Date() : nil
        }
        persistReceipt()
        onWindowLayoutChange?(true)

        if receipt.items[idx].isDone {
            if !wasAllDone && receipt.isAllDone {
                sound.playStampThump(enabled: settings.soundEnabled)
                showToast("今日待办已全部核销！", duration: 2.5)
            } else {
                sound.playPenStrike(enabled: settings.soundEnabled)
            }
        }
        evaluateReminders(allowAlert: false)
    }

    func updateItemTitle(_ id: UUID, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = receipt.items.firstIndex(where: { $0.id == id }) else { return }
        let parsed = TimeParser.parseManualOrFallback(trimmed)
        if let mins = parsed.scheduledMinutes {
            receipt.items[idx].title = parsed.cleanedTitle.isEmpty ? trimmed : parsed.cleanedTitle
            receipt.items[idx].scheduledMinutes = mins
            receipt.items[idx].timeHint = TodoItem.formatMinutes(mins)
            receipt.items[idx].reminderDismissed = false
        } else {
            receipt.items[idx].title = trimmed
            // If user deleted the pre-filled time prefix while editing, clear the schedule cleanly
            receipt.items[idx].scheduledMinutes = nil
            receipt.items[idx].timeHint = nil
            receipt.items[idx].reminderDismissed = false
        }
        persistReceipt()
        evaluateReminders(allowAlert: false)
    }

    func clearItemSchedule(_ id: UUID) {
        guard let idx = receipt.items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            receipt.items[idx].scheduledMinutes = nil
            receipt.items[idx].timeHint = nil
            receipt.items[idx].reminderDismissed = false
        }
        persistReceipt()
        evaluateReminders(allowAlert: false)
    }

    func deleteItem(_ id: UUID) {
        withAnimation(.easeOut(duration: 0.2)) {
            receipt.items.removeAll { $0.id == id }
        }
        persistReceipt()
        evaluateReminders(allowAlert: false)
        onWindowLayoutChange?(true)
    }

    func clearCompleted() {
        let count = receipt.doneCount
        guard count > 0 else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            receipt.items.removeAll { $0.isDone }
        }
        persistReceipt()
        evaluateReminders(allowAlert: false)
        onWindowLayoutChange?(true)
        showToast("已清理 \(count) 条已完成事项", duration: 2.0)
    }

    func clearAllItems() {
        let count = receipt.items.count
        guard count > 0 else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            receipt.items.removeAll()
            newlyAddedIDs.removeAll()
            activeReminderItemID = nil
        }
        persistReceipt()
        evaluateReminders(allowAlert: false)
        onWindowLayoutChange?(true)
        showToast("已清空全部 \(count) 条待办", duration: 2.2)
    }

    /// Copies completed items of the currently viewed receipt to clipboard for daily/weekly reports.
    func copyCompletedToClipboard() {
        let doneItems = receipt.items.filter(\.isDone)
        guard !doneItems.isEmpty else {
            showToast("当前小票还没有已完成的事项可复制", duration: 2.2)
            return
        }

        let header = "\(receipt.dateString) 已完成（\(doneItems.count)/\(receipt.totalCount)）："
        let lines = doneItems.map { item -> String in
            if let time = item.displayTimeLabel {
                return "- [x] \(item.title)（\(time)）"
            }
            return "- [x] \(item.title)"
        }
        let text = ([header] + lines).joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("已复制 \(doneItems.count) 条已完成事项（可直接粘贴进日报/周报）", duration: 2.6)
    }

    // MARK: - AI Reorganize Existing Receipt

    func reorganizePendingWithAI() async {
        let pending = receipt.items.filter { !$0.isDone }
        guard !pending.isEmpty else {
            showToast("当前没有需要整理的未完成待办", duration: 2.0)
            return
        }
        guard settings.hasAPIKey else {
            showToast("请先在设置中配置「2. AI 待办整理引擎」的大模型 API Key", duration: 3.5)
            openSettings()
            return
        }

        let completed = receipt.items.filter { $0.isDone }
        isParsingVoice = true
        do {
            let organized = try await planner.reorganizePendingItems(
                pendingItems: pending,
                completedTitles: completed.map(\.title),
                settings: settings
            )
            isParsingVoice = false
            guard !organized.isEmpty else {
                showToast("AI 未返回有效待办条目", duration: 2.5)
                return
            }

            let newPending = organized.map { dto -> TodoItem in
                let schedMins = TimeParser.parseHHMM(dto.scheduledTime) ?? TimeParser.parseHHMM(dto.timeHint)
                let hint = schedMins.map(TodoItem.formatMinutes) ?? dto.timeHint
                return TodoItem(title: dto.title, timeHint: hint, scheduledMinutes: schedMins, source: .voice)
            }
            receipt.items = completed + newPending
            newlyAddedIDs = Set(newPending.map(\.id))
            persistReceipt()
            evaluateReminders(allowAlert: true)

            let stepCount = min(11, max(7, receipt.items.count + 4))
            playThermalPrintFeed(steps: stepCount, startReveal: 0.03, fullAudio: true)
            showToast("AI 已重新整理为 \(newPending.count) 条干净待办", duration: 2.8)
            scheduleClearHighlight(ids: newPending.map(\.id))
        } catch {
            isParsingVoice = false
            showToast("AI 整理失败：\(error.localizedDescription)", duration: 4.0)
        }
    }

    // MARK: - Voice Recording & AI Planning (Supports Add + Complete + Update!)

    func toggleVoiceRecording() {
        if speechService.isRecording {
            Task { await finishVoiceAndOrganize() }
        } else {
            Task { await startVoiceRecording() }
        }
    }

    func startVoiceRecording() async {
        if isShowingPostTearStub {
            isPlanningTomorrow = true
        }
        if !isViewingActiveDay {
            goToActiveDay()
        }
        checkDateRollover()
        if !isExpanded {
            expandFromSlot()
        }
        let started = await speechService.startRecording(settings: settings)
        if started {
            onWindowLayoutChange?(true)
        }
    }

    func cancelVoiceRecording() {
        speechService.cancelRecording()
        onWindowLayoutChange?(true)
    }

    func finishVoiceAndOrganize() async {
        let transcript = await speechService.stopRecordingAndCollectTranscript()
        guard !transcript.isEmpty else {
            showToast("没有听到语音内容，请靠近麦克风重试", duration: 2.5)
            onWindowLayoutChange?(true)
            return
        }
        await runVoicePlanner(transcript: transcript)
    }

    func retryLastFailedTranscript() async {
        guard let transcript = lastFailedTranscript, !transcript.isEmpty else { return }
        await runVoicePlanner(transcript: transcript)
    }

    func dismissAIError() {
        withAnimation(.easeOut(duration: 0.2)) {
            aiErrorBanner = nil
            lastFailedTranscript = nil
        }
    }

    private func runVoicePlanner(transcript: String) async {
        aiErrorBanner = nil
        isParsingVoice = true
        let existingTitles = receipt.items.map(\.title)
        let result = await planner.organizeTodos(
            from: transcript,
            existingTitles: existingTitles,
            settings: settings
        )
        isParsingVoice = false

        if let err = result.errorMessage {
            lastFailedTranscript = transcript
            aiErrorBanner = err
            return
        }

        lastFailedTranscript = nil

        var completedCount = 0
        var updatedCount = 0
        var addedIDs: [UUID] = []

        // 1. Voice-command completions (e.g. "把踢足球划掉")
        for targetTitle in result.completeTitles {
            if let idx = findMatchingItemIndex(for: targetTitle, preferUnchecked: true) {
                if !receipt.items[idx].isDone {
                    receipt.items[idx].isDone = true
                    receipt.items[idx].doneAt = Date()
                    completedCount += 1
                }
            }
        }

        // 2. Voice-command updates/reschedules (e.g. "把封面反馈改到下午4点")
        for upd in result.updates {
            if let idx = findMatchingItemIndex(for: upd.matchTitle, preferUnchecked: true) {
                if let newTitle = upd.newTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !newTitle.isEmpty {
                    receipt.items[idx].title = newTitle
                }
                if let schedMins = TimeParser.parseHHMM(upd.scheduledTime) ?? TimeParser.parseHHMM(upd.timeHint) {
                    receipt.items[idx].scheduledMinutes = schedMins
                    receipt.items[idx].timeHint = TodoItem.formatMinutes(schedMins)
                    receipt.items[idx].reminderDismissed = false
                } else if let hint = upd.timeHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                    receipt.items[idx].timeHint = hint
                }
                newlyAddedIDs.insert(receipt.items[idx].id)
                addedIDs.append(receipt.items[idx].id)
                updatedCount += 1
            }
        }

        // 3. Newly added items
        var newItemCount = 0
        for dto in result.items {
            let schedMins = TimeParser.parseHHMM(dto.scheduledTime) ?? TimeParser.parseHHMM(dto.timeHint)
            let hint = schedMins.map(TodoItem.formatMinutes) ?? dto.timeHint
            let item = TodoItem(title: dto.title, timeHint: hint, scheduledMinutes: schedMins, source: .voice)
            receipt.items.append(item)
            newlyAddedIDs.insert(item.id)
            addedIDs.append(item.id)
            newItemCount += 1
        }

        guard newItemCount > 0 || completedCount > 0 || updatedCount > 0 else {
            showToast(result.note ?? "没有提取到新的待办或操作指令", duration: 3.0)
            return
        }

        persistReceipt()
        evaluateReminders(allowAlert: true)

        if newItemCount > 0 {
            let stepCount = min(11, max(7, receipt.items.count + 4))
            playThermalPrintFeed(steps: stepCount, startReveal: 0.03)
        } else if completedCount > 0 {
            if receipt.isAllDone {
                sound.playStampThump(enabled: settings.soundEnabled)
            } else {
                sound.playPenStrike(enabled: settings.soundEnabled)
            }
        } else {
            sound.playShortLineFeed(enabled: settings.soundEnabled)
        }

        var parts: [String] = []
        if newItemCount > 0 { parts.append("新增 \(newItemCount) 条") }
        if completedCount > 0 { parts.append("划掉 \(completedCount) 条") }
        if updatedCount > 0 { parts.append("修改 \(updatedCount) 条") }
        let summary = parts.joined(separator: " · ")

        if let note = result.note {
            showToast("\(summary) · \(note)", duration: 4.0)
        } else {
            showToast("已完成：\(summary)", duration: 2.8)
        }
        if !addedIDs.isEmpty {
            scheduleClearHighlight(ids: addedIDs)
        }
    }

    private func findMatchingItemIndex(for query: String, preferUnchecked: Bool) -> Int? {
        let normQuery = query.lowercased().replacingOccurrences(of: " ", with: "")
        guard !normQuery.isEmpty else { return nil }

        let candidates = receipt.items.enumerated().sorted { a, b in
            if preferUnchecked && a.element.isDone != b.element.isDone {
                return !a.element.isDone
            }
            return a.offset < b.offset
        }

        // 1. Exact or substring match
        for (idx, item) in candidates {
            let normTitle = item.title.lowercased().replacingOccurrences(of: " ", with: "")
            if normTitle == normQuery || normTitle.contains(normQuery) || normQuery.contains(normTitle) {
                return idx
            }
        }

        // 2. Character overlap match (>= 50%)
        let queryChars = Set(normQuery)
        var bestIdx: Int?
        var bestScore: Double = 0.45
        for (idx, item) in candidates {
            let titleChars = Set(item.title.lowercased().replacingOccurrences(of: " ", with: ""))
            let overlap = Double(queryChars.intersection(titleChars).count)
            let denom = Double(max(1, min(queryChars.count, titleChars.count)))
            let score = overlap / denom
            if score > bestScore {
                bestScore = score
                bestIdx = idx
            }
        }
        return bestIdx
    }

    // MARK: - Settings & Launch at Login

    func updateSettings(_ newSettings: AppSettings) {
        let topChanged = settings.alwaysOnTop != newSettings.alwaysOnTop
        let hotkeyChanged = settings.globalHotkeyEnabled != newSettings.globalHotkeyEnabled
            || settings.globalHotkey != newSettings.globalHotkey
        let layoutChanged = settings.pushUrgeEnabled != newSettings.pushUrgeEnabled
        settings = newSettings
        storage.saveSettings(newSettings)
        if topChanged {
            onAlwaysOnTopChange?(newSettings.alwaysOnTop)
        }
        if hotkeyChanged {
            onGlobalHotkeyChange?(newSettings.globalHotkeyEnabled, newSettings.globalHotkey)
        }
        if layoutChanged {
            onWindowLayoutChange?(true)
        }
    }

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "开机自启设置失败（建议先把 ReceiptTodo.app 拖到「应用程序」文件夹后重试）：\(error.localizedDescription)"
        }
    }

    func openSettings() {
        onOpenSettings?()
    }

    func resetWindowPosition() {
        onResetPosition?()
    }

    // MARK: - Helpers

    private func persistReceipt() {
        storage.saveReceipt(receipt)
        availableDates = storage.listReceiptDates(
            includingToday: todayDateString,
            extraDates: isTodayTornOff ? [tomorrowDateString] : []
        )
        let todayReceipt = isViewingToday ? receipt : storage.loadReceipt(dateString: todayDateString)
        streakDays = storage.calculateStreak(todayReceipt: todayReceipt, relativeTo: Date())
    }

    func showToast(_ message: String, duration: Double = 2.5) {
        toastTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }
        onWindowLayoutChange?(true)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    self?.toastMessage = nil
                }
                self?.onWindowLayoutChange?(true)
            }
        }
    }

    private func scheduleClearHighlight(ids: [UUID]) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.45)) {
                    for id in ids {
                        self?.newlyAddedIDs.remove(id)
                    }
                }
            }
        }
    }
}
