import Foundation

struct PlannedTodoDTO: Codable {
    let title: String
    let timeHint: String?
    let scheduledTime: String? // Optional exact 24h "HH:mm", e.g. "12:00", "15:30"

    init(title: String, timeHint: String?, scheduledTime: String? = nil) {
        self.title = title
        self.timeHint = timeHint
        self.scheduledTime = scheduledTime
    }
}

struct PlannedTodoUpdateDTO: Codable {
    let matchTitle: String
    let newTitle: String?
    let timeHint: String?
    let scheduledTime: String?
}

struct PlannerResult {
    let items: [PlannedTodoDTO]
    let completeTitles: [String]
    let updates: [PlannedTodoUpdateDTO]
    let usedFallback: Bool
    let errorMessage: String?
    let note: String?

    init(
        items: [PlannedTodoDTO],
        completeTitles: [String] = [],
        updates: [PlannedTodoUpdateDTO] = [],
        usedFallback: Bool,
        errorMessage: String? = nil,
        note: String? = nil
    ) {
        self.items = items
        self.completeTitles = completeTitles
        self.updates = updates
        self.usedFallback = usedFallback
        self.errorMessage = errorMessage
        self.note = note
    }
}

enum LLMPlannerError: LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case emptyResponse
    case parseFailed(raw: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "接口地址 (Base URL) 格式不正确，请在设置中检查。"
        case .httpError(let code, let message):
            if code == 401 || code == 403 {
                return "鉴权失败 (HTTP \(code))：API Key 无效或无权限（注意：第 2 栏需填「火山方舟」的 Key，不能填「豆包语音」的 Key）。原始返回：\(message)"
            }
            if code == 404 || message.contains("InvalidEndpointOrModel") || message.contains("NotFound") {
                return "模型不存在或未开通 (HTTP \(code))：请去火山方舟控制台复制你已开通的 Model ID 或 ep- 接入点填到「模型名称」。原始返回：\(message)"
            }
            return "接口请求失败 (HTTP \(code))：\(message)"
        case .emptyResponse:
            return "大模型返回了空内容。"
        case .parseFailed(let raw):
            return "大模型返回格式非标准 JSON（片段：\(raw.prefix(80))）"
        }
    }
}

final class LLMPlannerService {
    static let shared = LLMPlannerService()

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct ThinkingConfig: Encodable {
            let type: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let thinking: ThinkingConfig?
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct PlannerJSONPayload: Decodable {
        let items: [PlannedTodoDTO]?
        let completeTitles: [String]?
        let updates: [PlannedTodoUpdateDTO]?
    }

    private struct ParsedVoiceActions {
        let items: [PlannedTodoDTO]
        let completeTitles: [String]
        let updates: [PlannedTodoUpdateDTO]
    }

    private let organizerSystemPrompt = """
    你是一个极其专业、严谨的「中文口语 → 每日极简待办整理专家」。
    用户会通过语音口述今天的工作安排，语音转写文本往往包含：
    - 大量口语水话、寒暄、思考停顿（如“你好”“我现在想要”“那个”“就是”“呃”“其实”“然后吧”）
    - 语音识别同音错别字或漏字（如把“稿子/稿件”识别成“搞得”，中英文混杂断句错误）
    - 多件事黏在同一句话里（如“A的反馈B的封面”、“离职交接和GLM视频跟进”）
    - 同一件事反复换说法重复提到
    - 状态抱怨式表达（如“今天鸿蒙的视频反馈还没有给到”）

    请你严格按以下 7 条规则整理出干净、可直接执行的 To-Do List：
    1. 【彻底去水话】删掉一切寒暄（你好等）、过渡词（我现在想要、今天要把、就是、然后）、情绪废话和无行动意义的闲聊。
    2. 【专有名词与同音纠错】优先对照「用户常用专有名词词典」修正同音/近音识别错误（例如“质朴”→“智谱”，“搞得”→“稿件”）；即使词典未列，也要结合工作语境把明显同音错别字修正，保留英文项目名（如 GLM、Monster、小红书、鸿蒙）。
    3. 【原子化拆分】如果一句话里包含多个独立任务（无论用“和/以及/还有”连接还是连读粘在一起），必须拆分成多条独立的待办，每条只做一件事。
    4. 【合并去重】用户反复提到的同一件任务（或与「今日已有待办」明显重复的任务），合并为最清晰的一条，不要重复输出。
    5. 【统一动宾短语】把口语或状态陈述改写为简洁、清晰的动宾短语（4~16个字为佳），例如：“今天鸿蒙的视频反馈还没有给到” → “跟进鸿蒙视频反馈”；时间词绝对不要留在 title 里。
    6. 【时间就近精准绑定，严禁串行合并或传染】
       - 先按独立事件断句，再逐条判断「哪一条本身带了时间」；
       - 某一个时间点（如“12点”“下午3点半”）只绑定到它直接修饰的那**唯一一条**任务，绝不能把时间前后的两件事合并成一条，也绝不能把上一条的时间顺延传染给下一条没提时间的任务！
    7. 【时间字段格式】
       - 提到具体时间点或相对时间（如“今天12点去踢足球”“下午3点半开会”“半小时后拿快递”），结合「当前时间」换算为 24 小时制 "HH:mm" 填入 scheduledTime 与 timeHint（如 "12:00"、"15:30"）；
       - 仅模糊时段（如“上午”“下午”“下班前”），scheduledTime 填 null，timeHint 填该词；
       - 没提到时间，两者均为 null。
    8. 【支持直接语音操作已有待办（划掉 / 改时间）】
       - 如果用户说某件「今日已有待办」已经做完了/帮我划掉（如“踢足球已经完了帮我划掉”），请把对应已有待办的标题放入 completeTitles 数组，不要在 items 里重复新增；
       - 如果用户说修改某件已有待办的时间或内容（如“把封面反馈改到下午四点”），请放入 updates 数组：{"matchTitle":"已有标题关键词","newTitle":null,"timeHint":"16:00","scheduledTime":"16:00"}；
       - 一句话里可以同时包含新增、划掉和修改。

    示例（注意时间严禁传染给相邻条目）：
    当前时间：10:30
    用户常用专有名词：智谱, GLM, 鸿蒙, 小红书
    输入语音：「踢足球已经结束了帮我划掉，把封面反馈改到下午四点，然后先把质朴的GLM视频跟进一下，12点半去吃饭」
    输出 JSON：
    {"items":[{"title":"跟进智谱 GLM 视频进度","timeHint":null,"scheduledTime":null},{"title":"去吃饭","timeHint":"12:30","scheduledTime":"12:30"}],"completeTitles":["去踢足球"],"updates":[{"matchTitle":"封面反馈","newTitle":null,"timeHint":"16:00","scheduledTime":"16:00"}]}

    严格要求：只输出合法 JSON 对象，不要包含 Markdown 代码块（不要 ```json），不要输出任何解释或多余文字。
    """

    func organizeTodos(
        from transcript: String,
        existingTitles: [String],
        settings: AppSettings
    ) async -> PlannerResult {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return PlannerResult(items: [], usedFallback: true, errorMessage: nil, note: "没有识别到语音内容")
        }

        // Only use local rule splitter when user has NOT configured any AI API Key
        guard settings.hasAPIKey else {
            let localItems = parseLocally(transcript: cleaned, existingTitles: existingTitles)
            return PlannerResult(
                items: localItems,
                usedFallback: true,
                errorMessage: nil,
                note: "未配置 AI 整理 Key，当前仅本地切句（去设置填入大模型 Key 可智能去水话与纠错）"
            )
        }

        let nowLabel = TodoItem.formatMinutes(TimeParser.currentMinutesOfDay())
        let hotwordsList = settings.parsedHotwords
        let hotwordsSection = hotwordsList.isEmpty
            ? ""
            : "\n【用户常用专有名词词典（遇到同音/近音错别字请优先纠正为以下写法）】\n\(hotwordsList.joined(separator: "、"))\n"

        let existingContext = existingTitles.isEmpty
            ? "（今日暂无已有待办）"
            : existingTitles.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let userPrompt = """
        【当前时间】\(nowLabel)
        \(hotwordsSection)
        【今日已有待办（避免重复生成）】
        \(existingContext)

        【用户刚才口述的语音转写原文】
        \(cleaned)
        """

        do {
            let actions = try await callLLM(
                systemPrompt: organizerSystemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
            if actions.items.isEmpty && actions.completeTitles.isEmpty && actions.updates.isEmpty {
                return PlannerResult(
                    items: [],
                    usedFallback: false,
                    errorMessage: "AI 没有从这段话中提取出待办或操作指令（原文：\(cleaned.prefix(60))）",
                    note: nil
                )
            }
            return PlannerResult(
                items: actions.items,
                completeTitles: actions.completeTitles,
                updates: actions.updates,
                usedFallback: false,
                errorMessage: nil,
                note: nil
            )
        } catch {
            return PlannerResult(
                items: [],
                usedFallback: false,
                errorMessage: error.localizedDescription,
                note: nil
            )
        }
    }

    /// Uses the configured LLM to clean up, split, deduplicate, and polish all current pending items on today's receipt.
    func reorganizePendingItems(
        pendingItems: [TodoItem],
        completedTitles: [String],
        settings: AppSettings
    ) async throws -> [PlannedTodoDTO] {
        guard settings.hasAPIKey else {
            throw LLMPlannerError.httpError(statusCode: 0, message: "请先在「设置 → 2. AI 待办整理引擎」填入大模型 API Key")
        }

        let pendingText = pendingItems.enumerated().map { idx, item in
            let hint = item.timeHint.map { "（\($0)）" } ?? ""
            return "\(idx + 1). \(item.title)\(hint)"
        }.joined(separator: "\n")

        let doneContext = completedTitles.isEmpty
            ? "（无）"
            : completedTitles.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let hotwordsList = settings.parsedHotwords
        let hotwordsSection = hotwordsList.isEmpty
            ? ""
            : "\n【用户常用专有名词词典（遇到同音/近音错别字请优先纠正为以下写法）】\n\(hotwordsList.joined(separator: "、"))\n"

        let userPrompt = """
        【当前时间】\(TodoItem.formatMinutes(TimeParser.currentMinutesOfDay()))
        \(hotwordsSection)
        请帮我把下面这批凌乱的「今日未完成待办」重新彻底整理：
        - 去掉所有水话、口语寒暄，按词典和语境修正语音错别字；
        - 把粘在一条里的多个任务拆分独立，确保每个时间点只绑定对应的单条任务、不串行；
        - 合并重复的事项（也不要和「已完成待办」重复）；
        - 输出干净、简洁、动宾结构的最终待办清单 JSON。

        【今日已完成待办（无需再生成）】
        \(doneContext)

        【需要重新整理的待办】
        \(pendingText)
        """

        let actions = try await callLLM(
            systemPrompt: organizerSystemPrompt,
            userPrompt: userPrompt,
            settings: settings
        )
        return actions.items
    }

    func testConnection(settings: AppSettings) async throws -> String {
        guard settings.hasAPIKey else {
            throw LLMPlannerError.httpError(statusCode: 0, message: "请先填写 API Key")
        }
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LLMPlannerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

        let model = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldDisableThinking = settings.baseURL.lowercased().contains("volces.com")
            && (model.lowercased().contains("seed") || model.lowercased().contains("thinking"))

        let payload = ChatRequest(
            model: model,
            messages: [
                .init(role: "user", content: "请只回复 OK")
            ],
            temperature: 0.1,
            thinking: shouldDisableThinking ? .init(type: "disabled") : nil
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMPlannerError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(220) ?? ""
            throw LLMPlannerError.httpError(statusCode: http.statusCode, message: String(body))
        }
        return "连接成功（\(settings.modelName)）"
    }

    private func callLLM(
        systemPrompt: String,
        userPrompt: String,
        settings: AppSettings
    ) async throws -> ParsedVoiceActions {
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LLMPlannerError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

        let model = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldDisableThinking = settings.baseURL.lowercased().contains("volces.com")
            && (model.lowercased().contains("seed") || model.lowercased().contains("thinking"))

        let body = ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.15,
            thinking: shouldDisableThinking ? .init(type: "disabled") : nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMPlannerError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let errText = String(data: data, encoding: .utf8)?.prefix(200) ?? "未知错误"
            throw LLMPlannerError.httpError(statusCode: http.statusCode, message: String(errText))
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let rawContent = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawContent.isEmpty else {
            throw LLMPlannerError.emptyResponse
        }

        return try parseJSONActions(from: rawContent)
    }

    private func parseJSONActions(from raw: String) throws -> ParsedVoiceActions {
        var cleaned = raw
        if let thinkRegex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: .caseInsensitive) {
            cleaned = thinkRegex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if cleaned.contains("```") {
            let lines = cleaned.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let candidateJSON: String
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") {
            candidateJSON = String(cleaned[start...end])
        } else if let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]") {
            candidateJSON = String(cleaned[start...end])
        } else {
            throw LLMPlannerError.parseFailed(raw: raw)
        }

        guard let data = candidateJSON.data(using: .utf8) else {
            throw LLMPlannerError.parseFailed(raw: raw)
        }

        if let payload = try? JSONDecoder().decode(PlannerJSONPayload.self, from: data),
           (payload.items != nil || payload.completeTitles != nil || payload.updates != nil) {
            return ParsedVoiceActions(
                items: sanitize(payload.items ?? []),
                completeTitles: (payload.completeTitles ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                updates: payload.updates ?? []
            )
        }
        if let directArray = try? JSONDecoder().decode([PlannedTodoDTO].self, from: data) {
            return ParsedVoiceActions(items: sanitize(directArray), completeTitles: [], updates: [])
        }

        if let anyObj = try? JSONSerialization.jsonObject(with: data) {
            if let arr = anyObj as? [Any] {
                let parsed = extractFlexibleItems(from: arr)
                if !parsed.isEmpty {
                    return ParsedVoiceActions(items: sanitize(parsed), completeTitles: [], updates: [])
                }
            } else if let dict = anyObj as? [String: Any] {
                let candidateKeys = ["items", "tasks", "todos", "todo_list", "todoList", "list", "data", "result"]
                for key in candidateKeys {
                    if let arr = dict[key] as? [Any] {
                        let parsed = extractFlexibleItems(from: arr)
                        if !parsed.isEmpty {
                            return ParsedVoiceActions(items: sanitize(parsed), completeTitles: [], updates: [])
                        }
                    }
                }
                for (_, val) in dict {
                    if let arr = val as? [Any] {
                        let parsed = extractFlexibleItems(from: arr)
                        if !parsed.isEmpty {
                            return ParsedVoiceActions(items: sanitize(parsed), completeTitles: [], updates: [])
                        }
                    }
                }
            }
        }

        throw LLMPlannerError.parseFailed(raw: raw)
    }

    private func extractFlexibleItems(from array: [Any]) -> [PlannedTodoDTO] {
        var out: [PlannedTodoDTO] = []
        for elem in array {
            if let str = elem as? String {
                let parsed = TimeParser.parseManualOrFallback(str)
                out.append(PlannedTodoDTO(title: parsed.cleanedTitle, timeHint: parsed.timeHint, scheduledTime: parsed.scheduledMinutes.map(TodoItem.formatMinutes)))
            } else if let obj = elem as? [String: Any] {
                let title = (obj["title"] as? String)
                    ?? (obj["task"] as? String)
                    ?? (obj["content"] as? String)
                    ?? (obj["text"] as? String)
                    ?? (obj["name"] as? String)
                    ?? ""
                let hint = (obj["timeHint"] as? String)
                    ?? (obj["time_hint"] as? String)
                    ?? (obj["time"] as? String)
                let sched = (obj["scheduledTime"] as? String)
                    ?? (obj["scheduled_time"] as? String)
                    ?? (obj["time"] as? String)
                if !title.isEmpty {
                    out.append(PlannedTodoDTO(title: title, timeHint: hint, scheduledTime: sched))
                }
            }
        }
        return out
    }

    private func sanitize(_ items: [PlannedTodoDTO]) -> [PlannedTodoDTO] {
        items.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let hint = item.timeHint?.trimmingCharacters(in: .whitespacesAndNewlines)
            let sched = item.scheduledTime?.trimmingCharacters(in: .whitespacesAndNewlines)
            return PlannedTodoDTO(
                title: title,
                timeHint: (hint?.isEmpty == false) ? hint : nil,
                scheduledTime: (sched?.isEmpty == false) ? sched : nil
            )
        }
    }

    // Improved local rule-based fallback when no LLM API Key is configured
    func parseLocally(transcript: String, existingTitles: [String]) -> [PlannedTodoDTO] {
        let normalized = transcript
            .replacingOccurrences(of: "然后呢", with: "，")
            .replacingOccurrences(of: "然后", with: "，")
            .replacingOccurrences(of: "还有就是", with: "，")
            .replacingOccurrences(of: "还有", with: "，")
            .replacingOccurrences(of: "另外", with: "，")
            .replacingOccurrences(of: "顺便", with: "，")
            .replacingOccurrences(of: "以及", with: "，")
            .replacingOccurrences(of: "接着", with: "，")
            .replacingOccurrences(of: "最后", with: "，")
            .replacingOccurrences(of: "第一", with: "，")
            .replacingOccurrences(of: "第二", with: "，")
            .replacingOccurrences(of: "第三", with: "，")
            .replacingOccurrences(of: "第四", with: "，")

        let separators = CharacterSet(charactersIn: "，,。.;；！!？?\n、")
        var rawSegments = normalized.components(separatedBy: separators)

        // Also split compound "A和B" when both halves look like independent tasks (>= 4 chars each)
        var expandedSegments: [String] = []
        for seg in rawSegments {
            let trimmed = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = trimmed.range(of: "和") {
                let left = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if left.count >= 4 && right.count >= 4 {
                    expandedSegments.append(left)
                    expandedSegments.append(right)
                    continue
                }
            }
            expandedSegments.append(trimmed)
        }
        rawSegments = expandedSegments

        let leadingPrefixes = [
            "你好", "哈喽", "嗨", "喂",
            "我现在想要把", "我现在想要", "我现在想把", "我现在想", "我想把", "我想要把", "我想要",
            "今天我要把", "我今天要把", "今天我要", "我今天要", "今天需要把", "今天需要", "今天想", "今天打算", "今天要把", "今天要", "今天得",
            "首先", "先", "再去", "还要把", "还要", "还得", "需要", "记得", "别忘了", "对了", "那个", "就是", "其实", "呃", "嗯", "啊", "哦"
        ]
        let timeKeywords = ["早上", "上午", "中午", "下午", "傍晚", "晚上", "睡前", "下班前"]

        let existingSet = Set(existingTitles.map { $0.lowercased() })
        var results: [PlannedTodoDTO] = []

        for seg in rawSegments {
            var text = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { continue }

            var changed = true
            while changed {
                changed = false
                for prefix in leadingPrefixes {
                    if text.hasPrefix(prefix) && text.count > prefix.count + 1 {
                        text.removeFirst(prefix.count)
                        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        changed = true
                    }
                }
            }

            text = text.replacingOccurrences(of: "的就是", with: "的")

            // First try extracting exact clock time (e.g. "今天12点去踢足球" -> "去踢足球", "12:00")
            let parsedTime = TimeParser.parseManualOrFallback(text)
            if let mins = parsedTime.scheduledMinutes {
                let cleanTitle = parsedTime.cleanedTitle
                guard cleanTitle.count >= 2, !existingSet.contains(cleanTitle.lowercased()) else { continue }
                let formatted = TodoItem.formatMinutes(mins)
                results.append(PlannedTodoDTO(title: cleanTitle, timeHint: formatted, scheduledTime: formatted))
                continue
            }

            var timeHint: String? = nil
            for kw in timeKeywords {
                if text.hasPrefix(kw) && text.count > kw.count + 1 {
                    timeHint = kw
                    text.removeFirst(kw.count)
                    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            guard text.count >= 2 else { continue }
            guard !existingSet.contains(text.lowercased()) else { continue }
            results.append(PlannedTodoDTO(title: text, timeHint: timeHint, scheduledTime: nil))
        }

        if results.isEmpty {
            let fallback = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                return [PlannedTodoDTO(title: fallback, timeHint: nil)]
            }
        }
        return results
    }
}
