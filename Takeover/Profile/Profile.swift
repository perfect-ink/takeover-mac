import Foundation

/// The synced snapshot of a Mac's Takeover setup. Wire-compatible with
/// takeover-api's profile schema (see its README), plus `app_installers` so
/// a profile carries everything in the settings folder. Self-contained: a
/// restoring Mac needs nothing from its local catalog.
///
/// This is the one format every Mac pushes and pulls (Takeover Cloud sync,
/// Restore, first-launch setup). Decoding is lenient so profiles written by
/// older builds, which used a slightly different shape, still load.
struct Profile: Codable, Equatable {
    var version = 1
    var macDefaults: [MacDefaultEntry] = []
    var links: [LinkEntry] = []
    var apps: [AppEntry] = []
    /// Nil in profiles pushed by builds that didn't sync installers; applying
    /// such a profile keeps this Mac's installers as they are.
    var appInstallers: [AppInstallerEntry]?

    enum CodingKeys: String, CodingKey {
        case version
        case macDefaults = "mac_defaults"
        case links
        case apps
        case appInstallers = "app_installers"
    }

    init(version: Int = 1, macDefaults: [MacDefaultEntry] = [], links: [LinkEntry] = [],
         apps: [AppEntry] = [], appInstallers: [AppInstallerEntry]? = nil) {
        self.version = version
        self.macDefaults = macDefaults
        self.links = links
        self.apps = apps
        self.appInstallers = appInstallers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        macDefaults = (try? c.decodeIfPresent([MacDefaultEntry].self, forKey: .macDefaults)) ?? []
        links = (try? c.decodeIfPresent([LinkEntry].self, forKey: .links)) ?? []
        apps = (try? c.decodeIfPresent([AppEntry].self, forKey: .apps)) ?? []
        appInstallers = try? c.decodeIfPresent([AppInstallerEntry].self, forKey: .appInstallers)
    }

    struct MacDefaultEntry: Codable, Equatable, Identifiable, Hashable {
        var name: String
        var domain: String
        var key: String
        var type: String
        var value: String
        var hostFlag: String = ""
        var postCommand: String = ""

        var id: String { "\(domain)|\(key)|\(name)" }

        enum CodingKeys: String, CodingKey {
            case name, domain, key, type, value
            case hostFlag = "host_flag"
            case postCommand = "post_command"
        }

        init(name: String, domain: String, key: String, type: String, value: String,
             hostFlag: String = "", postCommand: String = "") {
            self.name = name
            self.domain = domain
            self.key = key
            self.type = type
            self.value = value
            self.hostFlag = hostFlag
            self.postCommand = postCommand
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "string"
            value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
            hostFlag = try c.decodeIfPresent(String.self, forKey: .hostFlag) ?? ""
            postCommand = try c.decodeIfPresent(String.self, forKey: .postCommand) ?? ""
        }
    }

    struct LinkEntry: Codable, Equatable, Identifiable, Hashable {
        var name: String
        var from: String
        var to: String
        var defaults: String = ""

        var id: String { "\(name)|\(from)" }

        enum CodingKeys: String, CodingKey {
            case name, from, to, defaults
        }

        init(name: String, from: String, to: String, defaults: String = "") {
            self.name = name
            self.from = from
            self.to = to
            self.defaults = defaults
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
            to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
            defaults = try c.decodeIfPresent(String.self, forKey: .defaults) ?? ""
        }
    }

    enum AppSource: String, Codable, CaseIterable {
        case brew, local, mas
    }

    struct AppEntry: Codable, Equatable, Identifiable, Hashable {
        var name: String
        var source: AppSource = .brew
        var cask: String?
        var masID: String?
        /// Installed automatically by Restore > Apply All.
        var alwaysInstall: Bool = false

        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, source, cask
            case masID = "mas_id"
            case alwaysInstall = "always_install"
        }

        init(name: String, source: AppSource = .brew, cask: String? = nil, masID: String? = nil,
             alwaysInstall: Bool = false) {
            self.name = name
            self.source = source
            self.cask = cask
            self.masID = masID
            self.alwaysInstall = alwaysInstall
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            let raw = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            source = AppSource(rawValue: raw) ?? .brew
            cask = try c.decodeIfPresent(String.self, forKey: .cask)
            masID = try c.decodeIfPresent(String.self, forKey: .masID)
            alwaysInstall = try c.decodeIfPresent(Bool.self, forKey: .alwaysInstall) ?? false
        }
    }

    struct AppInstallerEntry: Codable, Equatable, Hashable, Identifiable {
        var name: String
        var path: String

        var id: String { "installer|\(name)" }
    }
}

// MARK: - Build from the local model

extension Profile {
    /// `defaults` should already be filtered to rows with a non-empty value.
    static func snapshot(defaults: [MacDefault], links: [LinkItem], apps: [AppEntryModel]) -> Profile {
        Profile(
            version: 1,
            macDefaults: defaults.map {
                MacDefaultEntry(name: $0.name, domain: $0.domain, key: $0.key, type: $0.type,
                                value: $0.value, hostFlag: $0.hostFlag, postCommand: $0.postCommand)
            },
            links: links.map {
                LinkEntry(name: $0.name, from: $0.from, to: $0.to, defaults: $0.defaults)
            },
            apps: apps.map {
                AppEntry(name: $0.name,
                         source: AppSource(rawValue: $0.source) ?? .brew,
                         cask: $0.cask.isEmpty ? nil : $0.cask,
                         masID: $0.masID.isEmpty ? nil : $0.masID,
                         alwaysInstall: $0.alwaysInstall)
            }
        )
    }
}

// MARK: - Settings folder <-> profile

extension Profile {
    /// The profile for a settings file. Mac-default rows are filled in with
    /// domain/key/type from the catalog when the file doesn't carry them, so
    /// the profile stands on its own on another Mac.
    init(settings: SettingsYaml, catalog: [MacDefaultCatalogEntry]) {
        let byName = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        let defaults: [MacDefaultEntry] = (settings.macDefaults ?? []).compactMap { cfg in
            guard let value = cfg.value, !value.isEmpty else { return nil }
            let entry = byName[cfg.name]
            guard let domain = cfg.domain ?? entry?.domain,
                  let key = cfg.key ?? entry?.key else { return nil }
            return MacDefaultEntry(
                name: cfg.name, domain: domain, key: key,
                type: cfg.type ?? entry?.type ?? "string",
                value: value,
                hostFlag: cfg.hostFlag ?? entry?.hostFlag ?? "",
                postCommand: cfg.postCommand ?? entry?.postCommand ?? "")
        }

        self.init(
            version: 1,
            macDefaults: defaults,
            links: settings.links.map {
                LinkEntry(name: $0.name, from: $0.from, to: $0.to, defaults: $0.defaults ?? "")
            },
            apps: (settings.apps ?? []).map {
                AppEntry(name: $0.name,
                         source: AppSource(rawValue: $0.source) ?? .brew,
                         cask: $0.cask, masID: $0.masID,
                         alwaysInstall: $0.alwaysInstall ?? false)
            },
            appInstallers: (settings.appInstallers ?? []).map {
                AppInstallerEntry(name: $0.name, path: $0.path)
            }
        )
    }

    /// The settings file this profile describes. `keepingInstallersFrom`
    /// supplies installers when the profile predates syncing them.
    func settings(keepingInstallersFrom local: SettingsYaml?) -> SettingsYaml {
        SettingsYaml(
            links: links.map {
                LinkConfig(name: $0.name, from: $0.from, to: $0.to,
                           defaults: $0.defaults.isEmpty ? nil : $0.defaults)
            },
            macDefaults: macDefaults.map {
                MacDefaultConfig(
                    name: $0.name,
                    domain: $0.domain.isEmpty ? nil : $0.domain,
                    key: $0.key.isEmpty ? nil : $0.key,
                    type: $0.type,
                    value: $0.value,
                    hostFlag: $0.hostFlag.isEmpty ? nil : $0.hostFlag,
                    postCommand: $0.postCommand.isEmpty ? nil : $0.postCommand,
                    capturedOSMajorVersion: nil)
            },
            appInstallers: appInstallers.map { $0.map { AppInstallerConfig(name: $0.name, path: $0.path) } }
                ?? local?.appInstallers,
            apps: apps.map {
                AppEntryConfig(name: $0.name, source: $0.source.rawValue, cask: $0.cask, masID: $0.masID,
                               alwaysInstall: $0.alwaysInstall)
            }
        )
    }

    var isEmpty: Bool {
        macDefaults.isEmpty && links.isEmpty && apps.isEmpty && (appInstallers ?? []).isEmpty
    }
}
