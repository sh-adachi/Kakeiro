import AuthenticationServices
import CryptoKit
import Security
import UIKit

/// Public-client Authorization Code + PKCE, using Moneytree's documented endpoints.
/// A registered client ID and redirect URI are required; no client secret enters iOS.
@MainActor
final class MoneytreeAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?

    func authorize(_ configuration: MoneytreeConfiguration) async throws -> MoneytreeTokens {
        let authHost = configuration.environment == "production" ? "myaccount.getmoneytree.com" : "myaccount-staging.getmoneytree.com"
        guard ["production", "staging"].contains(configuration.environment),
              configuration.authorizationURL == "https://\(authHost)/oauth/authorize",
              configuration.tokenURL == "https://\(authHost)/oauth/token",
              configuration.redirectURI == "kakeiro://moneytree/callback",
              !configuration.clientID.isEmpty, !configuration.scopes.isEmpty,
              Set(configuration.scopes).isSubset(of: ["guest_read", "accounts_read", "transactions_read", "request_refresh", "investment_accounts_read", "investment_transactions_read"]) else {
            throw SyncClientError.message("Moneytreeの認証設定が対応形式ではありません。登録済みの公開クライアント設定を確認してください。")
        }
        let verifier = try randomURLSafeString()
        let state = try randomURLSafeString()
        let challenge = urlSafe(Data(SHA256.hash(data: Data(verifier.utf8))))
        var authorize = URLComponents(string: configuration.authorizationURL)!
        authorize.queryItems = [
            .init(name: "client_id", value: configuration.clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: configuration.redirectURI), .init(name: "scope", value: configuration.scopes.joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "locale", value: "ja")
        ]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let web = ASWebAuthenticationSession(url: authorize.url!, callbackURLScheme: "kakeiro") { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? SyncClientError.message("認証を完了できませんでした。")) }
            }
            web.presentationContextProvider = self
            web.prefersEphemeralWebBrowserSession = false
            webSession = web
            if !web.start() { webSession = nil; continuation.resume(throwing: SyncClientError.message("認証画面を開けませんでした。")) }
        }
        webSession = nil
        guard let response = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              response.scheme == "kakeiro", response.host == "moneytree", response.path == "/callback", response.fragment == nil,
              response.queryItems?.filter({ $0.name == "state" }).count == 1,
              response.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw SyncClientError.message("認証結果を確認できませんでした。もう一度連携してください。")
        }
        guard response.queryItems?.contains(where: { $0.name == "error" }) != true,
              response.queryItems?.filter({ $0.name == "code" }).count == 1,
              let code = response.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw SyncClientError.message("連携が許可されませんでした。")
        }
        let fields = ["grant_type": "authorization_code", "client_id": configuration.clientID,
                      "redirect_uri": configuration.redirectURI, "code": code, "code_verifier": verifier]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: configuration.tokenURL)!)
        request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let settings = URLSessionConfiguration.ephemeral; settings.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: settings, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, http) = try await session.data(for: request)
        guard (http as? HTTPURLResponse)?.statusCode == 200, data.count < 64 * 1024 else {
            throw SyncClientError.message("Moneytreeから認証情報を取得できませんでした。登録設定と利用権限を確認してください。")
        }
        struct TokenResponse: Decodable {
            let access_token: String; let refresh_token: String; let token_type: String
            let created_at: Double; let expires_in: Double; let resource_server: String; let scope: String
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard token.token_type.lowercased() == "bearer", token.expires_in > 0, token.expires_in < 31_536_000,
              token.created_at.isFinite, !token.access_token.isEmpty, !token.refresh_token.isEmpty,
              Set(configuration.scopes).isSubset(of: Set(token.scope.split(separator: " ").map(String.init))) else {
            throw SyncClientError.message("自動更新に必要な権限または認証情報を取得できませんでした。")
        }
        return MoneytreeTokens(accessToken: token.access_token, refreshToken: token.refresh_token,
                               expiresAt: Date(timeIntervalSince1970: token.created_at + token.expires_in), resourceServer: token.resource_server)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func randomURLSafeString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SyncClientError.message("認証に必要な乱数を生成できませんでした。") }
        return urlSafe(Data(bytes))
    }
    private func urlSafe(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
