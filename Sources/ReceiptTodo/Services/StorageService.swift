import Foundation

final class StorageService {
    static let shared = StorageService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    let rootDirectory: URL
    let receiptsDirectory: URL
    let configURL: URL

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.rootDirectory = appSupport.appendingPathComponent("ReceiptTodo", isDirectory: true)
        self.receiptsDirectory = rootDirectory.appendingPathComponent("receipts", isDirectory: true)
        self.configURL = rootDirectory.appendingPathComponent("config.json")

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        ensureDirectories()
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: receiptsDirectory, withIntermediateDirectories: true)
    }

    func receiptURL(for dateString: String) -> URL {
        receiptsDirectory.appendingPathComponent("\(dateString).json")
    }

    func loadReceipt(for date: Date = Date()) -> DailyReceipt {
        loadReceipt(dateString: DailyReceipt.dateKey(for: date))
    }

    func loadReceipt(dateString: String) -> DailyReceipt {
        let url = receiptURL(for: dateString)
        guard let data = try? Data(contentsOf: url),
              let receipt = try? decoder.decode(DailyReceipt.self, from: data) else {
            let compact = dateString.replacingOccurrences(of: "-", with: "")
            return DailyReceipt(dateString: dateString, receiptNo: "NO.\(compact)", items: [])
        }
        return receipt
    }

    func listReceiptDates(includingToday todayKey: String, extraDates: [String] = []) -> [String] {
        ensureDirectories()
        let urls = (try? fileManager.contentsOfDirectory(at: receiptsDirectory, includingPropertiesForKeys: nil)) ?? []
        var dates = Set<String>()
        dates.insert(todayKey)
        for extra in extraDates where extra.count == 10 {
            dates.insert(extra)
        }
        for url in urls where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            if stem.count == 10 { // YYYY-MM-DD
                dates.insert(stem)
            }
        }
        return dates.sorted()
    }

    func saveReceipt(_ receipt: DailyReceipt) {
        ensureDirectories()
        let url = receiptURL(for: receipt.dateString)
        guard let data = try? encoder.encode(receipt) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Scans up to the past 14 days (supporting weekends/vacations!) to find the most recent past receipt
    /// that still has unfinished items.
    func loadLatestUnfinishedBefore(today: Date = Date()) -> (sourceDate: String, items: [TodoItem])? {
        let calendar = Calendar.current
        for offset in 1...14 {
            guard let pastDate = calendar.date(byAdding: .day, value: -offset, to: today) else { break }
            let key = DailyReceipt.dateKey(for: pastDate)
            let url = receiptURL(for: key)
            guard let data = try? Data(contentsOf: url),
                  let receipt = try? decoder.decode(DailyReceipt.self, from: data) else {
                continue
            }
            let unfinished = receipt.items.filter { !$0.isDone }
            if !unfinished.isEmpty {
                return (sourceDate: key, items: unfinished)
            }
            // If the most recent saved receipt had all items finished, don't reach further back
            if !receipt.items.isEmpty {
                return nil
            }
        }
        return nil
    }

    func calculateStreak(todayReceipt: DailyReceipt, relativeTo today: Date = Date()) -> Int {
        var streak = 0
        let calendar = Calendar.current

        // Count today if user has at least 1 completed item today
        if todayReceipt.doneCount > 0 {
            streak += 1
        }

        // Walk backwards from yesterday
        for offset in 1...365 {
            guard let pastDate = calendar.date(byAdding: .day, value: -offset, to: today) else { break }
            let key = DailyReceipt.dateKey(for: pastDate)
            let url = receiptURL(for: key)
            guard let data = try? Data(contentsOf: url),
                  let receipt = try? decoder.decode(DailyReceipt.self, from: data),
                  receipt.doneCount > 0 else {
                break
            }
            streak += 1
        }
        return streak
    }

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: configURL),
              let settings = try? decoder.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func saveSettings(_ settings: AppSettings) {
        ensureDirectories()
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: configURL, options: .atomic)
        // Restrict permissions to owner read/write since config stores API key
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}
