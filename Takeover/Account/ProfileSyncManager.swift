import Foundation
import Combine
import AppKit

extension Notification.Name {
    /// Posted after a newer profile from the account was written to the
    /// settings folder. `object` is the new `SettingsYaml`; the app replaces
    /// its local lists with it.
    static let settingsPulledFromAccount = Notification.Name("settingsPulledFromAccount")
}

/// Keeps this Mac and the Takeover account (takeoverapp.site) in step.
///
/// Push: every settings save uploads this Mac's profile (debounced) while
/// signed in, whatever the storage choice, so the account always has it for
/// Restore.
///
/// Pull: when settings are stored in Takeover Cloud, the newest profile any
/// other Mac pushed is applied here if it's newer than what this Mac last
/// pushed or pulled. Checked on launch, sign-in, app activation and every
/// few minutes. Conflicts resolve last-writer-wins by server time; an edit
/// made here while offline is pushed before anything is pulled, so it wins.
/// Applying a pulled profile never pushes it back, so Macs don't ping-pong.
@MainActor
final class ProfileSyncManager: ObservableObject {
    static let shared = ProfileSyncManager()

    @Published private(set) var thisComputerID: Int?
    @Published private(set) var isPushing = false
    @Published private(set) var isPulling = false
    @Published var lastPushError: String?
    @Published private(set) var lastPushedAt: Date?
    @Published private(set) var lastPulledAt: Date?

    // Restore side
    @Published private(set) var computers: [APIComputer] = []
    @Published var isLoadingComputers = false
    @Published var computersError: String?
    @Published private(set) var profilesByComputer: [Int: Profile] = [:]

    private var pushTask: Task<Void, Never>?
    private var pendingProfile: Profile?
    private var autoSyncTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    static let pullInterval: UInt64 = 3 * 60 * 1_000_000_000 // 3 minutes

    private init() {}

    // MARK: - Persistent sync state

    private static let syncedThroughKey = "takeover.profileSyncedThrough"
    private static let unpushedKey = "takeover.profileHasUnpushedChanges"

    /// Server time of the newest profile this Mac has pushed or applied.
    private var syncedThrough: Date? {
        get { UserDefaults.standard.object(forKey: Self.syncedThroughKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.syncedThroughKey) }
    }

    /// A local edit that hasn't reached the server yet (offline, error).
    private var hasUnpushedChanges: Bool {
        get { UserDefaults.standard.bool(forKey: Self.unpushedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.unpushedKey) }
    }

    /// The last time this Mac synced with the account, either way.
    var lastSyncedAt: Date? {
        [lastPushedAt, lastPulledAt].compactMap { $0 }.max()
    }

    private var isSignedIn: Bool { AccountManager.shared.isSignedIn }

    /// Pulling only makes sense when the account is where settings live;
    /// iCloud/Dropbox/folder users already sync through their files.
    private var pullsFromAccount: Bool {
        StorageLocation.load()?.provider == .takeoverCloud
    }

    func reset() {
        thisComputerID = nil
        computers = []
        profilesByComputer = [:]
        lastPushedAt = nil
        lastPulledAt = nil
        lastPushError = nil
        pushTask?.cancel()
        pendingProfile = nil
        syncedThrough = nil
        hasUnpushedChanges = false
    }

    /// Ensure this Mac has a row on the account. Safe to call repeatedly.
    @discardableResult
    func registerThisMac() async -> Int? {
        guard isSignedIn else { return nil }
        if let thisComputerID { return thisComputerID }
        do {
            let computer = try await APIClient.registerComputer(
                clientUUID: ComputerIdentity.id, name: ComputerIdentity.name)
            thisComputerID = computer.id
            return computer.id
        } catch {
            lastPushError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Push

    /// Debounced upload of the current profile. No-op when signed out.
    func schedulePush(_ profile: Profile) {
        guard isSignedIn else { return }
        hasUnpushedChanges = true
        pendingProfile = profile
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.push(profile)
        }
    }

    func push(_ profile: Profile) async {
        guard isSignedIn else { return }
        isPushing = true
        lastPushError = nil
        defer { isPushing = false }
        do {
            guard let id = await registerThisMac() else { return }
            let serverTime = try await APIClient.putProfile(computerID: id, profile: profile)
            if pendingProfile == profile { pendingProfile = nil }
            hasUnpushedChanges = pendingProfile != nil
            syncedThrough = serverTime ?? Date()
            lastPushedAt = Date()
        } catch {
            hasUnpushedChanges = true
            lastPushError = error.localizedDescription
        }
    }

    /// Pushes the settings folder's current contents right away.
    func pushCurrentSettings() async {
        guard let settings = SettingsManager.shared.settings else { return }
        pushTask?.cancel()
        await push(Profile(settings: settings, catalog: MacDefaultCatalog.shared.entries))
    }

    // MARK: - Pull

    /// Starts the launch/activation/interval checks. Safe to call repeatedly.
    func startAutoSync() {
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in await ProfileSyncManager.shared.syncNow() }
            }
        }
        guard autoSyncTask == nil else { return }
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(nanoseconds: Self.pullInterval)
            }
        }
    }

    /// Pushes anything unsent, then pulls a newer profile from another Mac.
    func syncNow() async {
        // The launch-time account check can fail offline; retry it here.
        if APIClient.isSignedIn && !isSignedIn { await AccountManager.shared.refresh() }
        guard isSignedIn, pullsFromAccount, !isPulling, !isPushing, pendingProfile == nil else { return }
        guard SettingsManager.shared.settings != nil else { return } // settings not loaded yet

        if hasUnpushedChanges || (syncedThrough == nil && !localIsEmpty) {
            // Local edits not on the server yet, or this Mac has never synced
            // but already has settings: this Mac's copy goes up first and
            // becomes the newest. Other Macs' profiles stay on the account
            // (Restore tab) either way.
            await pushCurrentSettings()
            return
        }
        await pullIfNewer()
    }

    /// Applies the newest profile another Mac pushed, if it's newer than this
    /// Mac's last push/pull. Returns whether anything was applied.
    @discardableResult
    func pullIfNewer() async -> Bool {
        guard isSignedIn else { return false }
        isPulling = true
        defer { isPulling = false }
        do {
            let thisID = await registerThisMac()
            let all = try await APIClient.listComputers()
            computers = all.sorted { $0.name < $1.name }
            guard let newest = all
                .filter({ $0.id != thisID && $0.profileUpdatedAt != nil })
                .max(by: { $0.profileUpdatedAt! < $1.profileUpdatedAt! }),
                  let updatedAt = newest.profileUpdatedAt else { return false }
            if let syncedThrough, updatedAt <= syncedThrough { return false }

            let envelope = try await APIClient.fetchProfile(computerID: newest.id)
            profilesByComputer[newest.id] = envelope.profile
            // Don't overwrite an edit made while the request was in flight.
            guard pendingProfile == nil, !hasUnpushedChanges else { return false }

            let settings = envelope.profile.settings(keepingInstallersFrom: SettingsManager.shared.settings)
            try await SettingsManager.shared.applyFromAccount(settings)
            syncedThrough = envelope.profileUpdatedAt ?? updatedAt
            lastPulledAt = Date()
            NotificationCenter.default.post(name: .settingsPulledFromAccount, object: settings)
            return true
        } catch {
            lastPushError = error.localizedDescription
            return false
        }
    }

    private var localIsEmpty: Bool {
        guard let s = SettingsManager.shared.settings else { return true }
        return s.links.isEmpty && (s.macDefaults ?? []).isEmpty
            && (s.appInstallers ?? []).isEmpty && (s.apps ?? []).isEmpty
    }

    // MARK: - Restore side

    func loadComputers() async {
        guard isSignedIn else { return }
        isLoadingComputers = true
        computersError = nil
        defer { isLoadingComputers = false }
        do {
            computers = try await APIClient.listComputers()
        } catch {
            computersError = error.localizedDescription
        }
    }

    func profile(for computerID: Int, force: Bool = false) async -> Profile? {
        if !force, let cached = profilesByComputer[computerID] { return cached }
        do {
            let env = try await APIClient.fetchProfile(computerID: computerID)
            profilesByComputer[computerID] = env.profile
            return env.profile
        } catch {
            computersError = error.localizedDescription
            return nil
        }
    }

    func isThisMac(_ computer: APIComputer) -> Bool {
        computer.name == ComputerIdentity.name || computer.id == thisComputerID
    }
}
