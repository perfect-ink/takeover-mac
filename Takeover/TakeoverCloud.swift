import Foundation

/// Takeover Cloud: settings stored in the user's Takeover account
/// (takeoverapp.site). Settings still live in a local folder
/// (`StorageLocation.cloudCachePath`); `ProfileSyncManager` pushes each save
/// and pulls newer changes from the user's other Macs.
///
/// Uses the app's one sign-in (`APIClient` / `AccountManager`), so signing in
/// here or in the Account sheet is the same thing. This type adds the
/// trial/subscription state shown in Storage settings.
@MainActor
final class TakeoverCloud: ObservableObject {
    static let shared = TakeoverCloud()

    @Published private(set) var account: CloudAccount?

    var isSignedIn: Bool { APIClient.isSignedIn }

    private init() {}

    // MARK: - Account

    func signIn(login: String, password: String) async throws {
        let response = try await APIClient.login(login: login, password: password)
        await didSignIn(response.user)
    }

    func register(email: String, password: String) async throws {
        let response = try await APIClient.register(email: email, password: password)
        await didSignIn(response.user)
    }

    func signOut() {
        AccountManager.shared.signOut()
    }

    /// Called by AccountManager on sign-out.
    func clear() {
        account = nil
    }

    private func didSignIn(_ user: APIUser) async {
        await AccountManager.shared.adopt(user)
        try? await refreshAccount()
    }

    /// Reloads the account, including its trial/subscription state.
    func refreshAccount() async throws {
        account = try await request("GET", "auth/me")
    }

    // MARK: - HTTP

    private func request<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        guard let token = APIClient.token, let url = URL(string: "\(APIClient.baseURL)/\(path)") else {
            throw CloudError.signedOut
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return try JSONDecoder().decode(Response.self, from: data)
        case 401:
            signOut()
            throw CloudError.server(Self.message(in: data) ?? "Please sign in again.")
        case 402:
            throw CloudError.subscriptionRequired
        default:
            throw CloudError.server(Self.message(in: data) ?? "Takeover Cloud returned \(status).")
        }
    }

    private static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? String { return error }
        if let errors = object["errors"] as? [String] { return errors.joined(separator: "\n") }
        return nil
    }
}

// MARK: - Wire types

struct CloudAccount: Decodable {
    let id: Int
    let email: String
    let username: String?
    let subscription: CloudSubscription?
}

/// Trial/subscription state as reported by takeover-api. Admin accounts are
/// free; everyone else gets a 30-day trial, then $3/month.
struct CloudSubscription: Decodable {
    let status: String
    let trialEndsAt: String?
    let price: String?
    let checkoutURL: String?

    enum CodingKeys: String, CodingKey {
        case status, price
        case trialEndsAt = "trial_ends_at"
        case checkoutURL = "checkout_url"
    }

    var trialEndDate: Date? {
        trialEndsAt.flatMap { ISO8601DateFormatter.withFractionalSeconds.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
    }

    var summary: String {
        switch status {
        case "admin":
            return "Admin account, no subscription needed."
        case "trialing":
            if let end = trialEndDate {
                let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: end).day ?? 0)
                return "Free trial, \(days) day\(days == 1 ? "" : "s") left. Then \(price ?? "$3/month")."
            }
            return "Free trial. Then \(price ?? "$3/month")."
        case "active":
            return "Subscribed, \(price ?? "$3/month")."
        default:
            return "Trial ended. Subscribe for \(price ?? "$3/month") to keep syncing."
        }
    }

    var needsPayment: Bool { status != "admin" && status != "trialing" && status != "active" }
}

enum CloudError: LocalizedError {
    case signedOut
    case subscriptionRequired
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to Takeover Cloud."
        case .subscriptionRequired: return "Your Takeover Cloud trial has ended. Subscribe for $3/month to keep syncing."
        case .server(let message): return message
        }
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
