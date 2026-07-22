import Foundation
import Observation
import ReticulumSwift
import SwiftUI

// MARK: - Log entry

struct RNSLogEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let level: Reticulum.LogLevel
    let message: String

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(level: Reticulum.LogLevel, message: String) {
        self.id        = UUID()
        self.timestamp = Date()
        self.level     = level
        self.message   = message
    }

    var timestampString: String { Self.formatter.string(from: timestamp) }
    var formatted: String { "[\(level.abbreviation)] \(timestampString) \(message)" }
}

// MARK: - Log store

/// Thread-safe hand-off between the RNS log handler (called from arbitrary
/// transport threads) and the main-actor store. Keeps the hot path to a lock +
/// array append so logging never blocks the caller.
private final class RNSLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [RNSLogEntry] = []
    private var flushScheduled = false

    /// Buffers an entry. Returns `true` when the caller should schedule a flush.
    func append(_ entry: RNSLogEntry, cap: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending.append(entry)
        // Bound the buffer itself, so a burst between flushes can't grow without limit.
        if pending.count > cap {
            pending.removeFirst(pending.count - cap)
        }
        let needSchedule = !flushScheduled
        flushScheduled = true
        return needSchedule
    }

    func drain() -> [RNSLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let out = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        return out
    }
}

/// Captures RNS log output and exposes it to SwiftUI.
///
/// Installs itself as `Reticulum.logHandler` on init. Note the handler is only
/// invoked for messages that already passed `Reticulum.log`'s level filter
/// (`guard level <= globalLogLevel`) — it does NOT see everything.
/// Persists the chosen log level to UserDefaults so the setting survives relaunches.
///
/// Log lines are coalesced rather than published one-by-one: `Reticulum.log` is
/// called from transport threads and, at the `.debug`/`.extreme` levels this app
/// exposes in Settings, fires **per packet**. Publishing each line individually
/// meant one main-actor `Task` hop plus one `objectWillChange` (and so a re-render
/// of every observing view) per log line, which made raising the log level enough
/// to saturate the main actor. Now a burst collapses into one batched append.
/// `@Observable` (not `ObservableObject`) is load-bearing here, not stylistic.
/// `ObservableObject` invalidates EVERY view holding the object on ANY
/// `@Published` change — so appending a log line re-rendered `SettingsView`,
/// which observes this store purely to read `logLevel` for one Picker. Settings
/// (and every submenu and text field under it) therefore re-rendered on every
/// RNS log line. `@Observable` tracks per-property, established by what each
/// `body` actually reads: `LogsView` reads `entries` and still updates, while
/// `SettingsView` reads only `logLevel` and no longer re-renders on log traffic.
@MainActor
@Observable
final class RNSLogStore {
    static let maxEntries = 500
    private static let logLevelKey = "rnsLogLevel"
    /// Coalescing window — short enough to feel live in the Logs screen.
    private static let flushInterval: TimeInterval = 0.25

    private(set) var entries: [RNSLogEntry] = []
    private(set) var logLevel: Reticulum.LogLevel

    private let buffer = RNSLogBuffer()

    init() {
        // Restore persisted level, defaulting to .notice if never saved.
        let savedRaw = UserDefaults.standard.object(forKey: Self.logLevelKey) as? Int
        let level = savedRaw.flatMap { Reticulum.LogLevel(rawValue: $0) } ?? .notice
        logLevel = level
        Reticulum.globalLogLevel = level

        // Route RNS log output through this store. Called on transport threads:
        // buffer cheaply here, publish in batches on the main actor.
        let buffer = self.buffer
        let cap = Self.maxEntries
        Reticulum.logHandler = { [weak self] message, lvl in
            let entry = RNSLogEntry(level: lvl, message: message)
            guard buffer.append(entry, cap: cap) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    func setLogLevel(_ level: Reticulum.LogLevel) {
        logLevel = level
        Reticulum.globalLogLevel = level
        UserDefaults.standard.set(level.rawValue, forKey: Self.logLevelKey)
    }

    func clear() {
        _ = buffer.drain()
        entries.removeAll()
    }

    /// Appends a whole batch in one mutation — a single `objectWillChange`
    /// regardless of how many lines arrived in the window.
    private func flush() {
        let batch = buffer.drain()
        guard !batch.isEmpty else { return }
        entries.append(contentsOf: batch)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}

// MARK: - LogLevel display helpers

extension Reticulum.LogLevel {
    var displayName: String {
        switch self {
        case .none:     return "None"
        case .critical: return "Critical"
        case .error:    return "Error"
        case .warning:  return "Warning"
        case .notice:   return "Notice"
        case .info:     return "Info"
        case .verbose:  return "Verbose"
        case .debug:    return "Debug"
        case .pathing:  return "Pathing"
        case .extreme:  return "Extreme"
        }
    }

    var abbreviation: String {
        switch self {
        case .none:     return "NON"
        case .critical: return "CRT"
        case .error:    return "ERR"
        case .warning:  return "WRN"
        case .notice:   return "NTC"
        case .info:     return "INF"
        case .verbose:  return "VRB"
        case .debug:    return "DBG"
        case .pathing:  return "PTH"
        case .extreme:  return "XTR"
        }
    }

    var levelColor: Color {
        switch self {
        case .none, .critical, .error: return .rnsError
        case .warning:                 return .rnsWarning
        case .notice:                  return .rnsTextPrimary
        case .info:                    return .rnsInfo
        case .verbose:                 return .rnsTextSecondary
        case .debug, .pathing, .extreme: return .rnsTextMuted
        }
    }
}
