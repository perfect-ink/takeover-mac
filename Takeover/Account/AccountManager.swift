import Foundation
import Combine

/// The signed-in Takeover account, if any. Signing in only happens in
/// Settings > Storage when Takeover Cloud is chosen (CloudAccountView via
/// TakeoverCloud); the rest of the app has no sign-in button.
@MainActor
final class AccountManager: ObservableObject {
    static let shared = AccountManager()

    @Published private(set) var currentUser: APIUser?

    var isSignedIn: Bool { currentUser != nil && APIClient.isSignedIn }

    private init() {}

    /// Called on launch: if a token is stored, confirm it still works.
    func refresh() async {
        guard APIClient.isSignedIn else { return }
        do {
            currentUser = try await APIClient.me()
        } catch {
            // Token rejected / server down — treat as signed out but keep quiet.
            currentUser = nil
        }
    }

    func signOut() {
        APIClient.clearToken()
        currentUser = nil
        ProfileSyncManager.shared.reset()
        TakeoverCloud.shared.clear()
    }

    /// Records a successful Takeover Cloud sign-in and syncs this Mac with
    /// the account.
    func adopt(_ user: APIUser) async {
        currentUser = user
        await ProfileSyncManager.shared.registerThisMac()
        await ProfileSyncManager.shared.syncNow()
    }
}
