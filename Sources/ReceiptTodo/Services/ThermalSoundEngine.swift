import AppKit
import AVFoundation
import Foundation

/// Plays real recorded receipt-printer audio bundled in Resources/ (CC0 public domain recording),
/// paired with macOS built-in real recorded ink-pen stroke & payment chime sounds,
/// plus live drag-synced granular thermal-paper tearing audio.
@MainActor
final class ThermalSoundEngine {
    static let shared = ThermalSoundEngine()

    private let fullPrintURL: URL?
    private let shortFeedURL: URL?
    private let paperTearURL: URL?
    private let paperTearGrainURL: URL?
    private let inkStrokeURL: URL?
    private let allDoneURL: URL?

    private var activePrintSound: NSSound?
    private var tearGrainPlayers: [AVAudioPlayer] = []
    private var nextTearGrainIndex: Int = 0
    private var lastTearGrainTime: TimeInterval = 0

    private init() {
        self.fullPrintURL = Self.locateBundledAudio(named: "printer_print", ext: "m4a")
        self.shortFeedURL = Self.locateBundledAudio(named: "printer_short", ext: "m4a")
        self.paperTearURL = Self.locateBundledAudio(named: "paper_tear", ext: "m4a")
        self.paperTearGrainURL = Self.locateBundledAudio(named: "paper_tear_grain", ext: "m4a")

        let inkPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/ink/InkSoundStroke1.aif"
        self.inkStrokeURL = FileManager.default.fileExists(atPath: inkPath) ? URL(fileURLWithPath: inkPath) : nil

        let payPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/payment_success.aif"
        self.allDoneURL = FileManager.default.fileExists(atPath: payPath) ? URL(fileURLWithPath: payPath) : nil

        if let grainURL = paperTearGrainURL {
            for _ in 0..<4 {
                if let player = try? AVAudioPlayer(contentsOf: grainURL) {
                    player.enableRate = true
                    player.prepareToPlay()
                    tearGrainPlayers.append(player)
                }
            }
        }
    }

    private static func locateBundledAudio(named name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        // Fallback when running directly from .build/release during development
        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(name).\(ext)")
        if FileManager.default.fileExists(atPath: cwdURL.path) {
            return cwdURL
        }
        return nil
    }

    /// Real recorded receipt printer printing + paper tear (~1.30s)
    func playFullReceiptPrint(enabled: Bool) {
        guard enabled, let url = fullPrintURL else { return }
        activePrintSound?.stop()
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = 0.72
        activePrintSound = sound
        sound.play()
    }

    /// Real recorded short single-line printer feed (~0.34s)
    func playShortLineFeed(enabled: Bool) {
        guard enabled, let url = shortFeedURL else { return }
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = 0.58
        sound.play()
    }

    /// Real-time progressive paper-tearing micro-grain synced to live hand pull across cutter teeth.
    /// Throttled smoothly so pulling faster yields a continuous crisp rip and pausing stops audio instantly.
    func playTearStep(progress: CGFloat, enabled: Bool) {
        guard enabled, !tearGrainPlayers.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTearGrainTime >= 0.052 else { return }
        lastTearGrainTime = now

        let clamped = max(0.0, min(1.0, progress))
        let player = tearGrainPlayers[nextTearGrainIndex]
        nextTearGrainIndex = (nextTearGrainIndex + 1) % tearGrainPlayers.count

        player.stop()
        player.currentTime = 0
        player.rate = Float(0.90 + clamped * 0.28)
        player.volume = Float(0.38 + clamped * 0.24)
        player.play()
    }

    /// Real recorded crisp thermal-paper final detachment tear (~0.23s, calm volume)
    func playPaperTear(enabled: Bool) {
        guard enabled else { return }
        if let url = paperTearURL, let sound = NSSound(contentsOf: url, byReference: true) {
            sound.volume = 0.68
            sound.play()
            return
        }
        if let url = shortFeedURL, let sound = NSSound(contentsOf: url, byReference: true) {
            sound.volume = 0.48
            sound.play()
        }
    }

    /// Real recorded pen-on-paper ink stroke when crossing off a task
    func playPenStrike(enabled: Bool) {
        guard enabled else { return }
        if let url = inkStrokeURL, let sound = NSSound(contentsOf: url, byReference: true) {
            sound.volume = 0.55
            sound.play()
            return
        }
        if let orig = NSSound(named: NSSound.Name("Tink")), let copy = orig.copy() as? NSSound {
            copy.volume = 0.25
            copy.play()
        }
    }

    /// Crisp payment/register confirmation chime when all today's items are done
    func playStampThump(enabled: Bool) {
        guard enabled else { return }
        if let url = allDoneURL, let sound = NSSound(contentsOf: url, byReference: true) {
            sound.volume = 0.45
            sound.play()
            return
        }
        if let orig = NSSound(named: NSSound.Name("Glass")), let copy = orig.copy() as? NSSound {
            copy.volume = 0.28
            copy.play()
        }
    }

    /// Subtle, crisp reminder chime when a scheduled todo hits its time
    func playReminderChime(enabled: Bool) {
        guard enabled else { return }
        if let orig = NSSound(named: NSSound.Name("Ping")), let copy = orig.copy() as? NSSound {
            copy.volume = 0.32
            copy.play()
        }
    }

    func stopPrintSound() {
        activePrintSound?.stop()
        activePrintSound = nil
    }
}
