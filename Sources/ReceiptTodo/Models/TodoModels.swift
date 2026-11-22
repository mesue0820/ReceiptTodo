import Foundation

enum TodoSource: String, Codable {
    case voice
    case manual
    case rollover
}

struct TodoItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var timeHint: String?
    /// Minutes since midnight (0...1439) for exact timed tasks, e.g. 12:00 -> 720.
    var scheduledMinutes: Int?
    var reminderDismissed: Bool = false
    /// How many days this item has been carried over from previous receipts (0 = created today, 1 = +1D, etc.)
    var carryOverDays: Int = 0
    var isDone: Bool = false
    var createdAt: Date = Date()
    var doneAt: Date?
    var source: TodoSource = .manual

    var displayTimeLabel: String? {
        if let mins = scheduledMinutes {
            return Self.formatMinutes(mins)
        }
        if let hint = timeHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            return hint
        }
        return nil
    }

    static func formatMinutes(_ minutes: Int) -> String {
        let clamped = max(0, min(1439, minutes))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    init(
        id: UUID = UUID(),
        title: String,
        timeHint: String? = nil,
        scheduledMinutes: Int? = nil,
        reminderDismissed: Bool = false,
        carryOverDays: Int = 0,
        isDone: Bool = false,
        createdAt: Date = Date(),
        doneAt: Date? = nil,
        source: TodoSource = .manual
    ) {
        self.id = id
        self.title = title
        self.timeHint = timeHint
        self.scheduledMinutes = scheduledMinutes
        self.reminderDismissed = reminderDismissed
        self.carryOverDays = carryOverDays
        self.isDone = isDone
        self.createdAt = createdAt
        self.doneAt = doneAt
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        timeHint = try c.decodeIfPresent(String.self, forKey: .timeHint)
        scheduledMinutes = try c.decodeIfPresent(Int.self, forKey: .scheduledMinutes)
        reminderDismissed = try c.decodeIfPresent(Bool.self, forKey: .reminderDismissed) ?? false
        carryOverDays = try c.decodeIfPresent(Int.self, forKey: .carryOverDays) ?? 0
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        source = try c.decodeIfPresent(TodoSource.self, forKey: .source) ?? .manual
    }
}

struct DailyReceipt: Codable, Equatable {
    var dateString: String
    var receiptNo: String
    var items: [TodoItem]

    var totalCount: Int { items.count }
    var doneCount: Int { items.filter(\.isDone).count }
    var isAllDone: Bool { !items.isEmpty && doneCount == totalCount }

    static func empty(for date: Date = Date()) -> DailyReceipt {
        let dateStr = Self.dateKey(for: date)
        let compact = dateStr.replacingOccurrences(of: "-", with: "")
        return DailyReceipt(
            dateString: dateStr,
            receiptNo: "NO.\(compact)",
            items: []
        )
    }

    static func dateKey(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func displayDate(for dateString: String) -> String {
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let date = inFmt.date(from: dateString) else { return dateString }

        let outFmt = DateFormatter()
        outFmt.locale = Locale(identifier: "zh_CN")
        outFmt.dateFormat = "yyyy.MM.dd EEE"
        return outFmt.string(from: date)
    }
}

enum SpeechEngineType: String, Codable, CaseIterable, Identifiable {
    case macOS
    case doubao

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOS: return "macOS 系统语音"
        case .doubao: return "豆包语音"
        }
    }
}

enum LLMProviderPreset: String, Codable, CaseIterable, Identifiable {
    case deepseek
    case volcengine
    case qwen
    case gemini
    case openai
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .volcengine: return "火山方舟"
        case .qwen: return "通义千问"
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .custom: return "自定义"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek:
            return "https://api.deepseek.com/v1/chat/completions"
        case .volcengine:
            return "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        case .qwen:
            return "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .openai:
            return "https://api.openai.com/v1/chat/completions"
        case .custom:
            return "https://api.openai.com/v1/chat/completions"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .volcengine: return "doubao-seed-2-1-lite-260915"
        case .qwen: return "qwen-plus"
        case .gemini: return "gemini-2.5-flash"
        case .openai: return "gpt-4o-mini"
        case .custom: return "gpt-4o-mini"
        }
    }
}

struct AppSettings: Codable, Equatable {
    static let defaultDoubaoWSURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    static let defaultDoubaoResourceID = "volc.seedasr.sauc.duration"

    // Speech recognition (ASR)
    var speechEngine: SpeechEngineType = .macOS
    var doubaoAPIKey: String = ""
    var doubaoWebSocketURL: String = AppSettings.defaultDoubaoWSURL
    var doubaoResourceID: String = AppSettings.defaultDoubaoResourceID
    var customHotwords: String = ""

    // LLM todo structuring
    var provider: LLMProviderPreset = .deepseek
    var apiKey: String = ""
    var baseURL: String = LLMProviderPreset.deepseek.defaultBaseURL
    var modelName: String = LLMProviderPreset.deepseek.defaultModel

    // Widget preferences
    var alwaysOnTop: Bool = true
    var soundEnabled: Bool = true
    var globalHotkeyEnabled: Bool = true
    var preferOnDeviceSpeech: Bool = false

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasDoubaoAPIKey: Bool {
        !doubaoAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Splits user's custom proper nouns / hotwords (comma, Chinese comma, dunhao, whitespace, newline).
    var parsedHotwords: [String] {
        let seps = CharacterSet(charactersIn: ",，、;；\n\t ")
        var seen = Set<String>()
        var result: [String] = []
        for raw in customHotwords.components(separatedBy: seps) {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !seen.contains(word) else { continue }
            seen.insert(word)
            result.append(word)
        }
        return Array(result.prefix(100))
    }

    init(
        speechEngine: SpeechEngineType = .macOS,
        doubaoAPIKey: String = "",
        doubaoWebSocketURL: String = AppSettings.defaultDoubaoWSURL,
        doubaoResourceID: String = AppSettings.defaultDoubaoResourceID,
        customHotwords: String = "",
        provider: LLMProviderPreset = .deepseek,
        apiKey: String = "",
        baseURL: String = LLMProviderPreset.deepseek.defaultBaseURL,
        modelName: String = LLMProviderPreset.deepseek.defaultModel,
        alwaysOnTop: Bool = true,
        soundEnabled: Bool = true,
        globalHotkeyEnabled: Bool = true,
        preferOnDeviceSpeech: Bool = false
    ) {
        self.speechEngine = speechEngine
        self.doubaoAPIKey = doubaoAPIKey
        self.doubaoWebSocketURL = doubaoWebSocketURL
        self.doubaoResourceID = doubaoResourceID
        self.customHotwords = customHotwords
        self.provider = provider
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelName = modelName
        self.alwaysOnTop = alwaysOnTop
        self.soundEnabled = soundEnabled
        self.globalHotkeyEnabled = globalHotkeyEnabled
        self.preferOnDeviceSpeech = preferOnDeviceSpeech
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speechEngine = try c.decodeIfPresent(SpeechEngineType.self, forKey: .speechEngine) ?? .macOS
        doubaoAPIKey = try c.decodeIfPresent(String.self, forKey: .doubaoAPIKey) ?? ""
        doubaoWebSocketURL = try c.decodeIfPresent(String.self, forKey: .doubaoWebSocketURL) ?? Self.defaultDoubaoWSURL
        doubaoResourceID = try c.decodeIfPresent(String.self, forKey: .doubaoResourceID) ?? Self.defaultDoubaoResourceID
        customHotwords = try c.decodeIfPresent(String.self, forKey: .customHotwords) ?? ""
        provider = try c.decodeIfPresent(LLMProviderPreset.self, forKey: .provider) ?? .deepseek
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? provider.defaultBaseURL
        modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? provider.defaultModel
        alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? true
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        globalHotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalHotkeyEnabled) ?? true
        preferOnDeviceSpeech = try c.decodeIfPresent(Bool.self, forKey: .preferOnDeviceSpeech) ?? false
    }
}
