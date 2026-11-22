import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: TodoStore
    let onClose: () -> Void

    @State private var draft: AppSettings
    @State private var showDoubaoKey: Bool = false
    @State private var showAPIKey: Bool = false

    @State private var isTestingASR: Bool = false
    @State private var asrTestResult: String?
    @State private var asrTestSucceeded: Bool = false

    @State private var isTestingLLM: Bool = false
    @State private var llmTestResult: String?
    @State private var llmTestSucceeded: Bool = false
    @State private var showClearAllConfirm: Bool = false
    @State private var launchAtLogin: Bool
    @State private var loginStatusNote: String?

    init(store: TodoStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        self._draft = State(initialValue: store.settings)
        self._launchAtLogin = State(initialValue: store.isLaunchAtLoginEnabled)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Section 1: Speech Recognition (ASR)
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. 语音识别引擎（听写麦克风 → 文字）")
                        .font(.headline)

                    HStack(spacing: 8) {
                        ForEach(SpeechEngineType.allCases) { engine in
                            Button {
                                draft.speechEngine = engine
                                asrTestResult = nil
                            } label: {
                                Text(engine.displayName)
                                    .font(.system(size: 12, weight: draft.speechEngine == engine ? .semibold : .regular))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5.5)
                                    .background(draft.speechEngine == engine ? Color.accentColor : Color.secondary.opacity(0.14))
                                    .foregroundColor(draft.speechEngine == engine ? .white : .primary)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }

                    if draft.speechEngine == .doubao {
                        Text("把你在火山引擎「豆包语音」创建的 API Key 填到下面，WebSocket 地址与资源 ID 已自动预填。")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                            GridRow {
                                Text("豆包 Key")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 78, alignment: .trailing)

                                HStack(spacing: 6) {
                                    Group {
                                        if showDoubaoKey {
                                            TextField("填入豆包语音 API Key", text: $draft.doubaoAPIKey)
                                        } else {
                                            SecureField("填入豆包语音 API Key", text: $draft.doubaoAPIKey)
                                        }
                                    }
                                    .textFieldStyle(.roundedBorder)

                                    Button {
                                        showDoubaoKey.toggle()
                                    } label: {
                                        Image(systemName: showDoubaoKey ? "eye.slash" : "eye")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            GridRow {
                                Text("WS 地址")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 78, alignment: .trailing)
                                TextField(AppSettings.defaultDoubaoWSURL, text: $draft.doubaoWebSocketURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }

                            GridRow {
                                Text("资源 ID")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 78, alignment: .trailing)
                                TextField(AppSettings.defaultDoubaoResourceID, text: $draft.doubaoResourceID)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                runASRConnectionTest()
                            } label: {
                                HStack(spacing: 5) {
                                    if isTestingASR {
                                        ProgressView().controlSize(.small).scaleEffect(0.75)
                                    }
                                    Text(isTestingASR ? "测试中..." : "测试语音连接")
                                }
                            }
                            .disabled(isTestingASR || !draft.hasDoubaoAPIKey)

                            if let asrTestResult {
                                Text(asrTestResult)
                                    .font(.caption)
                                    .foregroundColor(asrTestSucceeded ? .green : .red)
                                    .lineLimit(2)
                            }
                        }
                    } else {
                        Toggle("优先使用 macOS 本地离线语音识别（如设备支持）", isOn: $draft.preferOnDeviceSpeech)
                            .font(.system(size: 12.5))
                    }

                    // Dual-layer custom hotwords / proper nouns (fed to BOTH Doubao ASR + AI LLM!)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("常用专有名词 / 热词（防同音词误识别）")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("同时生效于豆包听写 + AI 纠错")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        TextField("例如：智谱, GLM, 鸿蒙, 小红书, Monster（逗号或空格分隔）", text: $draft.customHotwords)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    .padding(.top, 4)
                }

                Divider()

                // Section 2: LLM Todo Structuring Engine
                VStack(alignment: .leading, spacing: 10) {
                    Text("2. AI 待办整理引擎（关键：去水话、纠错、拆任务、去重）")
                        .font(.headline)

                    Text("语音识别只负责把声音原样转成文字；必须在这里填入一个文本大模型 API Key（如火山方舟、DeepSeek、通义千问等），才能把一大段口语水话整理成干净的 To-Do List。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 5) {
                        ForEach(LLMProviderPreset.allCases) { preset in
                            Button {
                                draft.provider = preset
                                if preset != .custom {
                                    draft.baseURL = preset.defaultBaseURL
                                    draft.modelName = preset.defaultModel
                                }
                                llmTestResult = nil
                            } label: {
                                Text(preset.displayName)
                                    .font(.system(size: 11.5, weight: draft.provider == preset ? .semibold : .regular))
                                    .padding(.horizontal, 8.5)
                                    .padding(.vertical, 5)
                                    .background(draft.provider == preset ? Color.accentColor : Color.secondary.opacity(0.14))
                                    .foregroundColor(draft.provider == preset ? .white : .primary)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                        GridRow {
                            Text("API Key")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 78, alignment: .trailing)

                            HStack(spacing: 6) {
                                Group {
                                    if showAPIKey {
                                        TextField("选填：大模型 API Key", text: $draft.apiKey)
                                    } else {
                                        SecureField("选填：大模型 API Key", text: $draft.apiKey)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)

                                Button {
                                    showAPIKey.toggle()
                                } label: {
                                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        GridRow {
                            Text("接口地址")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 78, alignment: .trailing)
                            TextField("https://.../chat/completions", text: $draft.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                        }

                        GridRow {
                            Text("模型名称")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 78, alignment: .trailing)
                            TextField("例如 doubao-1-5-pro-32k / deepseek-chat", text: $draft.modelName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            runLLMConnectionTest()
                        } label: {
                            HStack(spacing: 5) {
                                if isTestingLLM {
                                    ProgressView().controlSize(.small).scaleEffect(0.75)
                                }
                                Text(isTestingLLM ? "测试中..." : "测试整理接口")
                            }
                        }
                        .disabled(isTestingLLM || !draft.hasAPIKey)

                        if let llmTestResult {
                            Text(llmTestResult)
                                .font(.caption)
                                .foregroundColor(llmTestSucceeded ? .green : .red)
                                .lineLimit(2)
                        }
                    }
                }

                Divider()

                // Section 3: Widget Behavior
                VStack(alignment: .leading, spacing: 8) {
                    Text("3. 小票浮窗偏好")
                        .font(.headline)

                    Toggle("始终置顶悬浮在其他窗口上方", isOn: $draft.alwaysOnTop)
                    Toggle("开启打印机出纸与划掉音效", isOn: $draft.soundEnabled)
                    Toggle("开启未完成催促感（进度条 / 呼吸灯 / 逾期计时与轻抖）", isOn: $draft.pushUrgeEnabled)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Toggle("全局快捷键唤醒语音记录", isOn: $draft.globalHotkeyEnabled)
                            Spacer()
                            if draft.globalHotkeyEnabled {
                                ShortcutRecorderControl(hotkey: $draft.globalHotkey)
                            }
                        }

                        if draft.globalHotkeyEnabled {
                            Text("点击右侧框后直接按下任意单键（如 F5、右 ⌥、Fn）或组合键（按 Esc 取消），也可点下拉选预设。")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if draft.globalHotkey.isPlainTypingSingleKey {
                                Text("⚠️ 单按常用字母/空格可能影响其他软件打字，更推荐 F5、单按右 ⌥ / Fn 或组合键。")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            } else if draft.globalHotkey.isSingleModifier && !AXIsProcessTrusted() {
                                HStack(spacing: 6) {
                                    Text("提示：单修饰键（如右 ⌥ / Fn）在其他软件中全局响应需开启「辅助功能」权限。")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                    Button("去开启") {
                                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    .font(.caption)
                                    .buttonStyle(.link)
                                }
                            }
                        }
                    }

                    Toggle("登录 Mac 时自动启动", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            let err = store.setLaunchAtLogin(newValue)
                            if let err {
                                loginStatusNote = err
                                launchAtLogin = store.isLaunchAtLoginEnabled
                            } else {
                                launchAtLogin = newValue
                                loginStatusNote = newValue ? "已开启开机自启" : "已关闭开机自启"
                            }
                        }
                    ))

                    if let loginStatusNote {
                        Text(loginStatusNote)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button("重置小票到屏幕右上角") {
                            store.resetWindowPosition()
                        }

                        Button("清空今日全部待办") {
                            showClearAllConfirm = true
                        }
                        .foregroundColor(.red)
                        .disabled(store.receipt.items.isEmpty)

                        Spacer()
                    }
                    .padding(.top, 2)
                }

                Divider()

                // Footer buttons
                HStack {
                    Button("退出小票待办") {
                        NSApp.terminate(nil)
                    }
                    .foregroundColor(.red)

                    Spacer()
                    Button("取消") {
                        onClose()
                    }
                    Button("保存") {
                        store.updateSettings(draft)
                        store.showToast("设置已保存", duration: 1.8)
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
        }
        .frame(width: 500, height: 645)
        .alert("确认清空今日全部待办？", isPresented: $showClearAllConfirm) {
            Button("取消", role: .cancel) {}
            Button("全部清除", role: .destructive) {
                store.clearAllItems()
            }
        } message: {
            Text("将清除今天小票上的全部 \(store.receipt.totalCount) 条待办（包含未完成与已完成项），清除后无法撤销。")
        }
    }

    private func runASRConnectionTest() {
        isTestingASR = true
        asrTestResult = nil
        Task {
            do {
                let msg = try await DoubaoASRClient.testConnection(settings: draft)
                await MainActor.run {
                    isTestingASR = false
                    asrTestSucceeded = true
                    asrTestResult = msg
                }
            } catch {
                await MainActor.run {
                    isTestingASR = false
                    asrTestSucceeded = false
                    asrTestResult = error.localizedDescription
                }
            }
        }
    }

    private func runLLMConnectionTest() {
        isTestingLLM = true
        llmTestResult = nil
        Task {
            do {
                let msg = try await LLMPlannerService.shared.testConnection(settings: draft)
                await MainActor.run {
                    isTestingLLM = false
                    llmTestSucceeded = true
                    llmTestResult = msg
                }
            } catch {
                await MainActor.run {
                    isTestingLLM = false
                    llmTestSucceeded = false
                    llmTestResult = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Interactive Global Shortcut Recorder (Click to Record Any Key Combo + Presets)

private struct ShortcutRecorderControl: View {
    @Binding var hotkey: GlobalHotkeyConfig

    @State private var isRecording = false
    @State private var keyDownMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var pendingModifierKeyCode: UInt32?
    @State private var pendingModifierInvalidated = false

    var body: some View {
        HStack(spacing: 5) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(isRecording ? "按下单键或组合键..." : hotkey.displaySymbols)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(isRecording ? .accentColor : .primary)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 108)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isRecording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                isRecording ? Color.accentColor : Color.primary.opacity(0.18),
                                lineWidth: isRecording ? 1.5 : 0.8
                            )
                    )
            }
            .buttonStyle(.plain)
            .help(isRecording ? "按下单键（如 F5、右 ⌥、Fn）或组合键，按 Esc 取消" : "点击后按下自定义单键或组合键")

            // Quick presets menu for effortless 1-click conflict avoidance
            Menu {
                ForEach(GlobalHotkeyConfig.presets, id: \.label) { preset in
                    Button {
                        stopRecording()
                        hotkey = preset.config
                    } label: {
                        HStack {
                            Text(preset.label)
                            if hotkey == preset.config {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("选择常用快捷键预设")

            if hotkey != .defaultOptionSpace && !isRecording {
                Button {
                    hotkey = .defaultOptionSpace
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.plain)
                .help("恢复默认 ⌥ Space")
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        pendingModifierKeyCode = nil
        pendingModifierInvalidated = false
        GlobalHotkeyManager.shared.pauseTemporarily()

        let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

        // 1. Capture any key combination OR single regular key (e.g. F5, `, etc.)
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            pendingModifierInvalidated = true
            if event.keyCode == UInt16(kVK_Escape) {
                Task { @MainActor in
                    stopRecording()
                }
                return nil
            }
            if let captured = GlobalHotkeyConfig.from(keyDownEvent: event) {
                Task { @MainActor in
                    hotkey = captured
                    stopRecording()
                }
            }
            return nil
        }

        // 2. Capture single modifier key tap-and-release (e.g. tapping 右 ⌥ or Fn 🌐 alone!)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let code = UInt32(event.keyCode)
            guard let flag = GlobalHotkeyConfig.modifierFlag(for: code) else { return event }
            let active = event.modifierFlags.intersection(relevantMask)

            if active.contains(flag) {
                if active == flag {
                    pendingModifierKeyCode = code
                    pendingModifierInvalidated = false
                } else {
                    pendingModifierInvalidated = true
                }
            } else {
                if pendingModifierKeyCode == code && !pendingModifierInvalidated {
                    let captured = GlobalHotkeyConfig(kind: .singleModifier, keyCode: code, modifiers: 0)
                    Task { @MainActor in
                        hotkey = captured
                        stopRecording()
                    }
                }
                pendingModifierKeyCode = nil
                pendingModifierInvalidated = false
            }
            return event
        }
    }

    private func stopRecording() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        pendingModifierKeyCode = nil
        pendingModifierInvalidated = false
        if isRecording {
            isRecording = false
            GlobalHotkeyManager.shared.resumeIfNeeded()
        }
    }
}
