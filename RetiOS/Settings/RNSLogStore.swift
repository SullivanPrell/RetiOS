import Foundation
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

/// Captures all RNS log output and exposes it to SwiftUI.
///
/// Installs itself as `Reticulum.logHandler` on init so it receives every
/// `Reticulum.log()` call regardless of the global log level filter.
/// Persists the chosen log level to UserDefaults so the setting survives relaunches.
@MainActor
final class RNSLogStore: ObservableObject {
    static let maxEntries = 500
    private static let logLevelKey = "rnsLogLevel"

    @Published private(set) var entries: [RNSLogEntry] = []
    @Published private(set) var logLevel: Reticulum.LogLevel

    init() {
        // Restore persisted level, defaulting to .notice if never saved.
        let savedRaw = UserDefaults.standard.object(forKey: Self.logLevelKey) as? Int
        let level = savedRaw.flatMap { Reticulum.LogLevel(rawValue: $0) } ?? .notice
        logLevel = level
        Reticulum.globalLogLevel = level

        // Route all RNS log output through this store.
        Reticulum.logHandler = { [weak self] message, lvl in
            Task { @MainActor [weak self] in
                self?.append(message: message, level: lvl)
            }
        }
    }

    func setLogLevel(_ level: Reticulum.LogLevel) {
        logLevel = level
        Reticulum.globalLogLevel = level
        UserDefaults.standard.set(level.rawValue, forKey: Self.logLevelKey)
    }

    func clear() {
        entries.removeAll()
    }

    private func append(message: String, level: Reticulum.LogLevel) {
        entries.append(RNSLogEntry(level: level, message: message))
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
        case .debug, .extreme:         return .rnsTextMuted
        }
    }
}
