// AuthService.swift
// WhiteBoARd - Spatial AR Notetaking
//
// Our own email/password auth against the SpatialBoard backend (/login, /signup).
// The returned JWT is sent on every sync so the backend keys this device's notes
// to the signed-in account — the same account the web app logs in as. No third
// party, no extra Swift packages.

import Foundation

@MainActor
@Observable
final class AuthService {
    static let shared = AuthService()
    private init() {
        self.email = UserDefaults.standard.string(forKey: Self.emailKey)
        self.token = UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    private static let emailKey = "com.whiteboard.authEmail"
    private static let tokenKey = "com.whiteboard.authToken"

    private(set) var email: String?
    private var token: String?
    private var loginURL: URL?
    private var signupURL: URL?

    var isSignedIn: Bool { token != nil && email != nil }

    /// Derive /login and /signup from the configured sync URL (…/sync).
    func configure(syncURL: String) {
        let base = syncURL.replacingOccurrences(of: "/sync", with: "")
        loginURL = URL(string: base + "/login")
        signupURL = URL(string: base + "/signup")
    }

    /// Returns an error message, or nil on success.
    func login(email: String, password: String) async -> String? { await authenticate(loginURL, email, password) }
    func signUp(email: String, password: String) async -> String? { await authenticate(signupURL, email, password) }

    private func authenticate(_ url: URL?, _ email: String, _ password: String) async -> String? {
        guard let url else { return "Not configured" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200, let r = try? JSONDecoder().decode(AuthResponse.self, from: data) {
                self.email = r.email
                self.token = r.token
                UserDefaults.standard.set(r.email, forKey: Self.emailKey)
                UserDefaults.standard.set(r.token, forKey: Self.tokenKey)
                return nil
            }
            let err = (try? JSONDecoder().decode(AuthError.self, from: data))?.error
            return err ?? "Failed (\(code))"
        } catch {
            return error.localizedDescription
        }
    }

    func signOut() {
        email = nil
        token = nil
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
    }

    /// The bearer token SyncService attaches to each sync.
    func currentToken() -> String? { token }
}

private struct AuthResponse: Decodable {
    let token: String
    let email: String
}
private struct AuthError: Decodable {
    let error: String
}
