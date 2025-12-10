import Foundation

/// Represents an OAuth 2.0 access token
public struct OAuthToken: Codable, Sendable {
    /// The access token string
    public let accessToken: String

    /// The token type (usually "Bearer")
    public let tokenType: String

    /// Token expiration time in seconds
    public let expiresIn: Int?

    /// Refresh token for obtaining new access tokens
    public let refreshToken: String?

    /// The scope of the access token
    public let scope: String?

    /// When this token was issued
    public let issuedAt: Date

    /// The client ID associated with this token
    public let clientId: String?

    /// The authorization endpoint URL associated with this token
    public let authorizationEndpoint: URL?

    /// The token endpoint URL associated with this token
    public let tokenEndpoint: URL?

    /// Checks if the token is expired (with 60 second buffer)
    public var isExpired: Bool {
        guard let expiresIn = expiresIn else { return false }
        return Date().timeIntervalSince(issuedAt) > TimeInterval(expiresIn - 60)
    }

    public init(
        accessToken: String,
        tokenType: String = "Bearer",
        expiresIn: Int? = nil,
        refreshToken: String? = nil,
        scope: String? = nil,
        issuedAt: Date = Date(),
        clientId: String? = nil,
        authorizationEndpoint: URL? = nil,
        tokenEndpoint: URL? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
        self.issuedAt = issuedAt
        self.clientId = clientId
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }
}
