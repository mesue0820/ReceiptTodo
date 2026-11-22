import Foundation

struct ParsedTaskTime {
    let cleanedTitle: String
    let scheduledMinutes: Int?
    let timeHint: String?
}

/// Parses exact times (e.g. "12:00", "今天12点去踢足球", "下午3点半开会", "半小时后拿快递")
/// from both manual input and AI structured output.
enum TimeParser {
    static func currentMinutesOfDay(for date: Date = Date()) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// Parses strict "HH:mm" (24h) string returned by LLM.
    static func parseHHMM(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.replacingOccurrences(of: "：", with: ":").split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else {
            return nil
        }
        return h * 60 + m
    }

    /// Extracts an optional exact time from natural Chinese/numeric input and cleans the task title.
    static func parseManualOrFallback(_ rawInput: String, now: Date = Date()) -> ParsedTaskTime {
        let original = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            return ParsedTaskTime(cleanedTitle: "", scheduledMinutes: nil, timeHint: nil)
        }

        // 1. Relative times: "半小时后", "X分钟后", "X小时后"
        if let rel = matchRelativeTime(in: original, now: now) {
            return rel
        }

        // 2. Explicit HH:mm (with optional period prefix like 下午 3:30)
        if let hm = matchColonTime(in: original) {
            return hm
        }

        // 3. Spoken Chinese clock time: "(今天/中午/下午/晚上)? (数字/中文数字)点(半/一刻/XX分)?"
        if let cn = matchChineseClockTime(in: original) {
            return cn
        }

        return ParsedTaskTime(cleanedTitle: original, scheduledMinutes: nil, timeHint: nil)
    }

    // MARK: - Pattern Matchers

    private static func matchRelativeTime(in text: String, now: Date) -> ParsedTaskTime? {
        let nowMins = currentMinutesOfDay(for: now)

        if let range = text.range(of: "半小时后|半个小时后", options: .regularExpression) {
            let target = min(1439, nowMins + 30)
            let cleaned = cleanRemainder(text, removing: range)
            return ParsedTaskTime(
                cleanedTitle: cleaned.isEmpty ? text : cleaned,
                scheduledMinutes: target,
                timeHint: TodoItem.formatMinutes(target)
            )
        }

        if let regex = try? NSRegularExpression(pattern: "([0-9]{1,2}|[一二两三四五六七八九十]{1,2})\\s*(?:个)?(分钟|小时)后"),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let fullRange = Range(match.range, in: text),
           let numRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text),
           let value = parseSmallChineseOrArabicInt(String(text[numRange])) {
            let delta = (text[unitRange] == "小时") ? value * 60 : value
            let target = min(1439, nowMins + delta)
            let cleaned = cleanRemainder(text, removing: fullRange)
            return ParsedTaskTime(
                cleanedTitle: cleaned.isEmpty ? text : cleaned,
                scheduledMinutes: target,
                timeHint: TodoItem.formatMinutes(target)
            )
        }

        return nil
    }

    private static func matchColonTime(in text: String) -> ParsedTaskTime? {
        let pattern = "(?:今天)?\\s*(早上|上午|中午|下午|傍晚|晚上|今晚)?\\s*([0-2]?[0-9])[:：]([0-5][0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let fullRange = Range(match.range, in: text),
              let hourRange = Range(match.range(at: 2), in: text),
              let minRange = Range(match.range(at: 3), in: text),
              var hour = Int(text[hourRange]),
              let minute = Int(text[minRange]),
              hour <= 23 else {
            return nil
        }

        if let periodRange = Range(match.range(at: 1), in: text) {
            hour = adjustHour(hour, period: String(text[periodRange]))
        }
        let total = hour * 60 + minute
        let cleaned = cleanRemainder(text, removing: fullRange)
        return ParsedTaskTime(
            cleanedTitle: cleaned.isEmpty ? text : cleaned,
            scheduledMinutes: total,
            timeHint: TodoItem.formatMinutes(total)
        )
    }

    private static func matchChineseClockTime(in text: String) -> ParsedTaskTime? {
        let pattern = "(?:今天)?\\s*(早上|上午|中午|下午|傍晚|晚上|今晚)?\\s*([0-2]?[0-9]|[一二两三四五六七八九十]{1,3})\\s*点\\s*(半|一刻|三刻|([0-5]?[0-9]|[一二三四五六七八九十]{1,3})\\s*分?)?"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let fullRange = Range(match.range, in: text),
              let hourRange = Range(match.range(at: 2), in: text),
              var hour = parseSmallChineseOrArabicInt(String(text[hourRange])),
              (0...23).contains(hour) else {
            return nil
        }

        var minute = 0
        if let subRange = Range(match.range(at: 3), in: text) {
            let sub = String(text[subRange])
            if sub == "半" {
                minute = 30
            } else if sub == "一刻" {
                minute = 15
            } else if sub == "三刻" {
                minute = 45
            } else if let minNumRange = Range(match.range(at: 4), in: text),
                      let parsedMin = parseSmallChineseOrArabicInt(String(text[minNumRange])),
                      (0...59).contains(parsedMin) {
                minute = parsedMin
            }
        }

        if let periodRange = Range(match.range(at: 1), in: text) {
            hour = adjustHour(hour, period: String(text[periodRange]))
        }

        let total = hour * 60 + minute
        let cleaned = cleanRemainder(text, removing: fullRange)
        return ParsedTaskTime(
            cleanedTitle: cleaned.isEmpty ? text : cleaned,
            scheduledMinutes: total,
            timeHint: TodoItem.formatMinutes(total)
        )
    }

    private static func adjustHour(_ hour: Int, period: String) -> Int {
        switch period {
        case "下午", "傍晚", "晚上", "今晚":
            if hour >= 1 && hour <= 11 { return hour + 12 }
            return hour
        case "中午":
            if hour >= 1 && hour <= 4 { return hour + 12 }
            return hour
        default:
            return hour
        }
    }

    private static func cleanRemainder(_ text: String, removing range: Range<String.Index>) -> String {
        var result = text
        result.removeSubrange(range)
        result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。:：-")))
        let prefixes = ["要去", "要", "得", "需要", "记得", "打算", "准备", "左右", "之前", "前"]
        var changed = true
        while changed {
            changed = false
            for p in prefixes {
                if result.hasPrefix(p) && result.count > p.count + 1 {
                    result.removeFirst(p.count)
                    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        return result
    }

    private static func parseSmallChineseOrArabicInt(_ s: String) -> Int? {
        if let v = Int(s) { return v }
        let map: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        if s == "十" { return 10 }
        let chars = Array(s)
        if chars.count == 1, let v = map[chars[0]] { return v }
        if chars.count == 2 {
            if chars[0] == "十", let ones = map[chars[1]] { return 10 + ones }
            if chars[1] == "十", let tens = map[chars[0]] { return tens * 10 }
        }
        if chars.count == 3, chars[1] == "十", let tens = map[chars[0]], let ones = map[chars[2]] {
            return tens * 10 + ones
        }
        return nil
    }
}
