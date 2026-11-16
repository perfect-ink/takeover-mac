import CryptoKit
import Foundation
import os

/// One chosen Mac default, resolved to the exact `defaults` call that sets it
/// on this Mac. Only entries with a value are ever resolved, so defaults the
/// user didn't pick are never touched.
struct MacDefaultTarget: Equatable {
    let name: String
    let domain: String
    let key: String
    let type: String
    let value: String
    let hostFlag: String
    let postCommand: String

    var readArguments: [String] {
        (hostFlag.isEmpty ? [] : [hostFlag]) + ["read", domain, key]
    }

    var writeArguments: [String] {
        (hostFlag.isEmpty ? [] : [hostFlag]) + ["write", domain, key, "-\(type)", value]
    }

    /// The catalog describes catalog defaults (same as the Mac Defaults tab);
    /// custom ones carry their own domain and key. Entries without a value,
    /// ones the catalog hides on this macOS, and ones with no domain/key are
    /// skipped. A name listed twice uses its last entry.
    static func resolve(
        _ configs: [MacDefaultConfig],
        catalog: [MacDefaultCatalogEntry],
        unsupported: Set<String> = []
    ) -> [MacDefaultTarget] {
        let catalogByName = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        var order: [String] = []
        var byName: [String: MacDefaultTarget] = [:]
        for config in configs {
            guard let value = config.value, !value.isEmpty, !unsupported.contains(config.name) else { continue }
            let target: MacDefaultTarget
            if let entry = catalogByName[config.name] {
                target = MacDefaultTarget(
                    name: config.name, domain: entry.domain, key: entry.key, type: entry.type, value: value,
                    hostFlag: entry.hostFlag ?? "", postCommand: entry.postCommand ?? "")
            } else if let domain = config.domain, !domain.isEmpty, let key = config.key, !key.isEmpty {
                target = MacDefaultTarget(
                    name: config.name, domain: domain, key: key, type: config.type ?? "string", value: value,
                    hostFlag: config.hostFlag ?? "", postCommand: config.postCommand ?? "")
            } else {
                continue
            }
            if byName[config.name] == nil { order.append(config.name) }
            byName[config.name] = target
        }
        return order.compactMap { byName[$0] }
    }

    /// Each distinct follow-up command once, in first-seen order, so ten
    /// Finder settings restart Finder once.
    static func postCommands(for targets: [MacDefaultTarget]) -> [String] {
        var seen = Set<String>()
        return targets.map(\.postCommand).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum MacDefaultValue {
    /// Whether `current` (as `defaults read` prints it, "" when unset)
    /// already equals `desired` for this type: `defaults read` prints a bool
    /// as 1/0 and a float without trailing zeros, so compare by meaning.
    static func matches(type: String, desired: String, current: String) -> Bool {
        let want = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let have = current.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type.lowercased() {
        case "bool", "boolean":
            if let a = bool(want), let b = bool(have) { return a == b }
        case "int", "integer":
            if let a = Int(want), let b = Int(have) { return a == b }
        case "float":
            if let a = Double(want), let b = Double(have) { return abs(a - b) < 0.000_001 }
        default:
            break
        }
        return want == have
    }

    static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }
}

/// Makes this Mac match the defaults chosen in `mac-defaults.yaml`: reads
/// each one, writes only those that differ, then runs each needed follow-up
/// (`killall Dock`, `killall Finder`…) once. Used at login and on file
/// changes by the background agent (DefaultsAgent), by the app while the
/// agent isn't running, and reusable by anything that applies a profile.
@MainActor
enum MacDefaultsEnforcer {
    enum Trigger: String {
        /// Login, agent start or app launch: check everything.
        case startup
        /// mac-defaults.yaml changed: apply it unless this Mac wrote it.
        case fileChanged
    }

    struct Outcome {
        var checked = 0
        var applied: [String] = []
        var failed: [String] = []
    }

    static let log = Logger(subsystem: "alexvaos.Takeover", category: "mac-defaults")

    // Shared with the other process (app or agent) through the app's defaults.
    nonisolated static let localWriteKey = "takeover.macDefaultsLocalWrite"
    nonisolated static let lastAppliedKey = "takeover.macDefaultsLastApplied"
    nonisolated static let lastAppliedAtKey = "takeover.macDefaultsLastAppliedAt"

    /// Hash of the file contents this process last checked.
    private static var lastCheckedHash: String?

    /// Applies every chosen default that differs from the system.
    @discardableResult
    static func enforce(_ configs: [MacDefaultConfig]) -> Outcome {
        let catalog = MacDefaultCatalog.shared
        let targets = MacDefaultTarget.resolve(configs, catalog: catalog.entries, unsupported: catalog.unsupportedNames)
        var outcome = Outcome(checked: targets.count)
        var changed: [MacDefaultTarget] = []

        for target in targets {
            let current = MacDefaultInstaller.readValue(arguments: target.readArguments)
            if MacDefaultValue.matches(type: target.type, desired: target.value, current: current) { continue }
            let write = Proc.run("/usr/bin/defaults", target.writeArguments)
            if write.ok {
                changed.append(target)
                outcome.applied.append(target.name)
                log.info("Applied \(target.name, privacy: .public): \(target.domain, privacy: .public) \(target.key, privacy: .public) = \(target.value, privacy: .public)")
            } else {
                outcome.failed.append(target.name)
                log.error("Couldn't apply \(target.name, privacy: .public): \(write.combined, privacy: .public)")
            }
        }

        for command in MacDefaultTarget.postCommands(for: changed) {
            let result = Shell.runTrusted(command)
            if !result.ok { log.error("'\(command, privacy: .public)' failed: \(result.text, privacy: .public)") }
        }

        if !outcome.applied.isEmpty {
            UserDefaults.standard.set(outcome.applied, forKey: lastAppliedKey)
            UserDefaults.standard.set(Date(), forKey: lastAppliedAtKey)
        }
        return outcome
    }

    /// Reads `mac-defaults.yaml` from the chosen settings folder and applies
    /// it. On `.fileChanged`, contents already checked here, or written by
    /// this Mac's own app (an edit in the Mac Defaults tab, which has its own
    /// Apply buttons), are left alone so a half-typed value or an unrelated
    /// save never touches the system. Does nothing before a storage choice.
    @discardableResult
    static func enforceFile(trigger: Trigger) -> Outcome? {
        guard StorageLocation.load() != nil else { return nil }
        let url = SettingsManager.shared.macDefaultsFileURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = fingerprint(data)
        if trigger == .fileChanged {
            if hash == lastCheckedHash { return nil }
            if hash == UserDefaults.standard.string(forKey: localWriteKey) {
                lastCheckedHash = hash
                return nil
            }
        }
        lastCheckedHash = hash

        let configs: [MacDefaultConfig]
        do {
            configs = try SettingsManager.decodeMacDefaults(data) ?? []
        } catch {
            log.error("Couldn't read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let outcome = enforce(configs)
        log.info("\(trigger.rawValue, privacy: .public): checked \(outcome.checked), applied \(outcome.applied.count), failed \(outcome.failed.count)")
        return outcome
    }

    /// Stable across processes (unlike `hashValue`).
    nonisolated static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// "Dark Mode, Dock Autohide" and when, for the Mac Defaults tab.
    static var lastApplied: (names: [String], at: Date)? {
        guard let names = UserDefaults.standard.stringArray(forKey: lastAppliedKey), !names.isEmpty,
              let at = UserDefaults.standard.object(forKey: lastAppliedAtKey) as? Date else { return nil }
        return (names, at)
    }
}
