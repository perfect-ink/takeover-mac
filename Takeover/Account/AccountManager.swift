import Foundation
import Combine

@MainActor
final class AccountManager: ObservableObject {
    static let shared = AccountManager()

    @Published private(set) var currentUser: APIUser?
    @Published var authError: String?
    @Published var isLoadingAuth = false

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

    func register(email: String, password: String) async {
        await run { try await APIClient.register(email: email, password: password) }
    }

    func login(email: String, password: String) async {
        await run { try await APIClient.login(login: email, password: password) }
    }

    func loginWithApple(idToken: String, email: String?) async {
        await run { try await APIClient.signInWithApple(idToken: idToken, email: email) }
    }

    func signOut() {
        APIClient.clearToken()
        currentUser = nil
        ProfileSyncManager.shared.reset()
        TakeoverCloud.shared.clear()
    }

    /// Records a successful sign-in (from here or from Takeover Cloud's
    /// sign-in in Storage settings) and syncs this Mac with the account.
    func adopt(_ user: APIUser) async {
        currentUser = user
        await ProfileSyncManager.shared.registerThisMac()
        await ProfileSyncManager.shared.syncNow()
    }

    private func run(_ call: () async throws -> AuthResponse) async {
        isLoadingAuth = true
        authError = nil
        defer { isLoadingAuth = false }
        do {
            let response = try await call()
            await adopt(response.user)
        } catch {
            authError = error.localizedDescription
        }
    }
}
