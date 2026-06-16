import AppKit
import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An HTTP transport that automatically handles OAuth authentication
///
/// This transport extends the functionality of HTTPClientTransport by automatically
/// injecting OAuth tokens into ALL requests (including SSE) and handling token refresh when needed.
public actor OAuthHTTPClientTransport: Transport {
    /// The endpoint URL for the MCP server
    let endpoint: URL

    /// OAuth authenticator for managing tokens
    private var authenticator: OAuthAuthenticator

    /// Identifier for token storage (allows multiple token sets)
    private let tokenIdentifier: String

    /// Logger instance for transport-related events
    public nonisolated let logger: Logger

    /// The underlying HTTP transport - recreated when token changes
    private var baseTransport: any Transport

    /// URLSession configuration template
    private let sessionConfiguration: URLSessionConfiguration

    /// Whether streaming is enabled
    public var streaming: Bool

    /// Whether streamable HTTP is enabled
    private let streamableHTTP: Bool

    /// Whether the transport has been explicitly connected
    private var isConnected = false

    /// Whether the transport has been explicitly disconnected
    private var isDisconnected = false

    /// Incremented whenever the wrapped base transport is replaced.
    private var baseTransportGeneration = 0

    /// Client name for dynamic registration
    private let clientName: String?

    /// Creates an OAuth-enabled transport for dynamic discovery
    ///
    /// Use this when connecting to an MCP server that requires OAuth but you don't have
    /// configuration yet. The transport will automatically discover OAuth requirements
    /// from the server's 401 response and guide you through dynamic registration.
    ///
    /// - Parameters:
    ///   - endpoint: The MCP server URL to connect to
    ///   - tokenStorage: Optional token storage (defaults to platform-appropriate storage)
    ///   - tokenIdentifier: Identifier for token storage (default: "default")
    ///   - configuration: URLSession configuration
    ///   - streaming: Whether to enable SSE streaming
    ///   - logger: Optional logger instance
    public static func withDynamicDiscovery(
        endpoint: URL,
        tokenStorage: TokenStorage? = nil,
        tokenIdentifier: String = "default",
        redirectURIResolver: @escaping OAuthConfiguration.RedirectURIResolver,
        clientName: String,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = true,
        logger: Logger? = nil
    ) -> OAuthHTTPClientTransport {
        // Create a minimal configuration for discovery
        // This will be replaced after dynamic registration
        let discoveryConfig = try! OAuthConfiguration(
            authorizationEndpoint: URL(string: "https://discovery.pending")!,
            tokenEndpoint: URL(string: "https://discovery.pending")!,
            clientId: UUID().uuidString, // Temporary ID for discovery
            redirectURIResolver: redirectURIResolver
        )

        return OAuthHTTPClientTransport(
            endpoint: endpoint,
            oauthConfig: discoveryConfig,
            tokenStorage: tokenStorage,
            tokenIdentifier: tokenIdentifier,
            configuration: configuration,
            streamableHTTP: false,
            streaming: streaming,
            clientName: clientName,
            logger: logger
        )
    }

    public static func withDynamicDiscoveryAndHTTPStreaming(
        endpoint: URL,
        tokenStorage: TokenStorage? = nil,
        tokenIdentifier: String = "default",
        redirectURIResolver: @escaping OAuthConfiguration.RedirectURIResolver,
        clientName: String,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = true,
        logger: Logger? = nil
    ) -> OAuthHTTPClientTransport {
        // Create a minimal configuration for discovery
        // This will be replaced after dynamic registration
        let discoveryConfig = try! OAuthConfiguration(
            authorizationEndpoint: URL(string: "https://discovery.pending")!,
            tokenEndpoint: URL(string: "https://discovery.pending")!,
            clientId: UUID().uuidString, // Temporary ID for discovery
            redirectURIResolver: redirectURIResolver
        )

        return OAuthHTTPClientTransport(
            endpoint: endpoint,
            oauthConfig: discoveryConfig,
            tokenStorage: tokenStorage,
            tokenIdentifier: tokenIdentifier,
            configuration: configuration,
            streamableHTTP: true,
            streaming: streaming,
            clientName: clientName,
            logger: logger
        )
    }

    /// Creates a new OAuth-enabled HTTP transport for MCP servers
    ///
    /// - Parameters:
    ///   - endpoint: The MCP server URL to connect to
    ///   - oauthConfig: OAuth configuration
    ///   - tokenStorage: Optional token storage (defaults to platform-appropriate storage)
    ///   - tokenIdentifier: Identifier for token storage (default: "default")
    ///   - configuration: URLSession configuration
    ///   - streaming: Whether to enable SSE streaming
    ///   - logger: Optional logger instance
    public init(
        endpoint: URL,
        oauthConfig: OAuthConfiguration,
        tokenStorage: TokenStorage? = nil,
        tokenIdentifier: String = "default",
        configuration: URLSessionConfiguration = .default,
        streamableHTTP: Bool = true,
        streaming: Bool = true,
        clientName: String? = nil,
        logger: Logger? = nil
    ) {
        self.endpoint = endpoint
        sessionConfiguration = configuration
        self.streaming = streaming
        self.streamableHTTP = streamableHTTP
        self.clientName = clientName

        let effectiveLogger = logger ?? Logger(label: "mcp.client.oauth.http.transport")
        self.logger = effectiveLogger
        self.tokenIdentifier = tokenIdentifier

        // Set up token storage
        let storage: TokenStorage
        #if canImport(Security)
            storage = tokenStorage ?? KeychainTokenStorage()
        #elseif os(Linux)
            storage = tokenStorage ?? (try? FileTokenStorage()) ?? InMemoryTokenStorage()
        #else
            storage = tokenStorage ?? InMemoryTokenStorage()
        #endif

        // Create separate URLSession instances for authenticator and transport
        // to avoid session invalidation race conditions
        let authenticatorSession = URLSession(configuration: configuration)
        let transportSession = URLSession(configuration: configuration)

        authenticator = OAuthAuthenticator(
            configuration: oauthConfig,
            tokenStorage: storage,
            urlSession: authenticatorSession,
            logger: effectiveLogger
        )

        if streamableHTTP {
            baseTransport = StreamableHTTPTransport(
                endpoint: endpoint,
                session: transportSession,
                requestModifier: { [authenticator, tokenIdentifier] req async -> URLRequest in
                    var request = req
                    // Use getValidToken to ensure we always have a fresh token (refreshing if needed)
                    if let token = try? await authenticator.getValidToken(for: tokenIdentifier) {
                        request.setValue(
                            "\(token.tokenType.capitalized) \(token.accessToken)",
                            forHTTPHeaderField: "Authorization"
                        )
                    }
                    return request
                },
                logger: self.logger
            )
        } else {
            baseTransport = HTTPClientTransport(
                endpoint: endpoint,
                session: transportSession,
                streaming: true,
                requestModifier: { [authenticator, tokenIdentifier] req async -> URLRequest in
                    var request = req
                    // Use getValidToken to ensure we always have a fresh token (refreshing if needed)
                    if let token = try? await authenticator.getValidToken(for: tokenIdentifier) {
                        request.setValue(
                            "\(token.tokenType.capitalized) \(token.accessToken)",
                            forHTTPHeaderField: "Authorization"
                        )
                    }
                    return request
                },
                logger: logger
            )
        }
    }

    /// Creates or updates the base transport with current OAuth token
    public func updateBaseTransport(with token: OAuthToken) {
        // Create a new configuration with OAuth headers
        guard let config = sessionConfiguration.copy() as? URLSessionConfiguration else {
            logger.error("Failed to copy URLSession configuration")
            return
        }
        var headers = config.httpAdditionalHeaders as? [String: String] ?? [:]
        headers["Authorization"] = "\(token.tokenType) \(token.accessToken)"
        config.httpAdditionalHeaders = headers

        // Create a new authenticated session
        let authenticatedSession = URLSession(configuration: config)

        // Re-create the request modifiers to use the authenticator for token refreshment
        // We capture the authenticator and identifier to allow dynamic token retrieval
        let authenticator = self.authenticator
        let tokenIdentifier = self.tokenIdentifier

        if streamableHTTP {
            baseTransportGeneration += 1
            baseTransport = StreamableHTTPTransport(
                endpoint: endpoint,
                session: authenticatedSession,
                requestModifier: { [authenticator, tokenIdentifier] req async -> URLRequest in
                    var request = req
                    // Use getValidToken to ensure we always have a fresh token (refreshing if needed)
                    if let token = try? await authenticator.getValidToken(for: tokenIdentifier) {
                        request.setValue(
                            "\(token.tokenType.capitalized) \(token.accessToken)",
                            forHTTPHeaderField: "Authorization"
                        )
                    }
                    return request
                },
                logger: logger
            )
        } else {
            // Create new transport with authenticated session
            baseTransportGeneration += 1
            baseTransport = HTTPClientTransport(
                endpoint: endpoint,
                session: authenticatedSession,
                streaming: streaming,
                requestModifier: { [authenticator, tokenIdentifier] req async -> URLRequest in
                    var request = req
                    // Use getValidToken to ensure we always have a fresh token (refreshing if needed)
                    if let token = try? await authenticator.getValidToken(for: tokenIdentifier) {
                        request.setValue(
                            "\(token.tokenType.capitalized) \(token.accessToken)",
                            forHTTPHeaderField: "Authorization"
                        )
                    }
                    return request
                },
                logger: logger
            )
        }

        logger.debug("Updated base transport with new OAuth token")
    }

    /// Establishes connection with OAuth authentication for MCP
    public func connect() async throws {
        logger.info("Connecting OAuth HTTP transport to MCP server")
        isDisconnected = false

        // Try to get existing valid token first
        do {
            // Connect the base transport
            try await baseTransport.connect()
            isConnected = true

            logger.info("OAuth HTTP transport connected with existing token")
            return
        } catch OAuthAuthenticator.OAuthError.authenticationRequired {
            logger.info("No valid token found, will attempt MCP OAuth discovery on first request")

            // For MCP, we'll discover OAuth requirements when we get a 401 response
            // Create an unauthenticated transport for the initial discovery request
            // Do NOT connect yet - wait for explicit connect() call
            let oldTransport = baseTransport
            baseTransportGeneration += 1
            baseTransport = HTTPClientTransport(
                endpoint: endpoint,
                session: URLSession(configuration: sessionConfiguration),
                streaming: streaming,
                logger: logger
            )

            // Disconnect the old transport after replacement so active OAuth receive streams
            // observe the new base transport instead of a terminal EOF.
            await oldTransport.disconnect()

            logger.info("OAuth HTTP transport ready, awaiting OAuth discovery")
        } catch {
            logger.error("Connection error: \(error)")
        }
    }

    /// Disconnects from the transport
    public func disconnect() async {
        logger.info("Disconnecting OAuth HTTP transport")

        isConnected = false
        isDisconnected = true
        baseTransportGeneration += 1
        currentStream = nil

        // Disconnect the base transport
        await baseTransport.disconnect()
    }

    /// Sends data with automatic OAuth token injection, refresh, and MCP discovery
    public func send(_ data: Data) async throws {
        guard !isDisconnected else {
            throw MCPError.internalError("Transport disconnected")
        }

        // Try to send with current token (or no token for initial discovery)
        do {
            try await baseTransport.send(data)
        } catch let MCPError.unauthorized(wwwAuthenticateHeader) {
            logger.info("Received 401 response, attempting MCP OAuth discovery")

            do {
                try await performMCPOAuthDiscovery(wwwAuthenticateHeader: wwwAuthenticateHeader)

                // Retry the request with the new token
                try await baseTransport.send(data)
            } catch {
                logger.error("Auto-Authentication failed: \(error)")
                throw error
            }

        } catch {
            logger.error("Sending failed: \(error)")
            throw error
        }
    }

    private var currentStream: AsyncThrowingStream<Data, Swift.Error>?

    /// Receives data from the transport
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        if let currentStream {
            return currentStream
        }

        currentStream = AsyncThrowingStream { continuation in
            Task {
                await self.forwardBaseTransportMessages(to: continuation)
            }
        }

        return currentStream!
    }

    private func forwardBaseTransportMessages(
        to continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    ) async {
        while !Task.isCancelled {
            if isDisconnected {
                currentStream = nil
                continuation.finish()
                return
            }

            let generation = baseTransportGeneration
            let stream = await baseTransport.receive()

            do {
                for try await data in stream {
                    if Task.isCancelled || isDisconnected {
                        currentStream = nil
                        continuation.finish()
                        return
                    }

                    continuation.yield(data)
                }

                if isDisconnected {
                    currentStream = nil
                    continuation.finish()
                    return
                }

                if generation != baseTransportGeneration {
                    continue
                }

                currentStream = nil
                continuation.finish()
                return
            } catch {
                if isDisconnected {
                    currentStream = nil
                    continuation.finish()
                    return
                }

                if generation != baseTransportGeneration {
                    continue
                }

                currentStream = nil
                continuation.finish(throwing: error)
                return
            }
        }

        currentStream = nil
        continuation.finish()
    }

    // MARK: - Private Methods

    /// Extract base domain URL from an endpoint URL
    /// For example: https://example.com/mcp -> https://example.com
    private func getBaseDomainURL(from url: URL) -> URL? {
        guard let scheme = url.scheme,
              let host = url.host
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port

        return components.url
    }

    private func isAuthenticationError(_ error: Swift.Error) -> Bool {
        // Check if this is an MCP authentication error
        if let mcpError = error as? MCPError,
           case let .internalError(message) = mcpError
        {
            return (message?.contains("Authentication required") ?? false)
                || (message?.contains("Access forbidden") ?? false)
                || (message?.contains("401") ?? false) || (message?.contains("403") ?? false)
        }

        return false
    }

    /// Perform MCP OAuth discovery and authentication flow
    private func performMCPOAuthDiscovery(wwwAuthenticateHeader: String? = nil) async throws {
        logger.info("Starting MCP OAuth discovery process")
        logger.info("Step 1/4: Discovering OAuth server metadata...")

        let (_, discoveryDocument) = try await discoverOAuthServerMetadata(
            wwwAuthenticateHeader: wwwAuthenticateHeader
        )

        logger.info("Step 1/4: OAuth server metadata discovered successfully")

        // Proceed with public client flow (PKCE authentication)
        try await handlePublicClientFlow(discoveryDocument: discoveryDocument)
    }

    private let metadataPaths = [
        ".well-known/oauth-protected-resource",
        ".well-known/oauth-protected-resource/sse",
        "mcp/.well-known/oauth-protected-resource",
        "mcp/.well-known/oauth-protected-resource/sse",
    ]

    private func discoverOAuthServerMetadata(wwwAuthenticateHeader: String? = nil) async throws -> (
        URL, OAuthAuthenticator.OAuthDiscoveryDocument
    ) {
        // Step 1: Try to get metadata URL from WWW-Authenticate header if available
        var metadataURL: URL?

        let endpointURL =
            if endpoint.lastPathComponent == "mcp" || endpoint.lastPathComponent == "sse" {
                endpoint.deletingLastPathComponent()
            } else {
                endpoint
            }

        // 1. Try to get metadata URL from WWW-Authenticate header if available
        if let wwwAuthHeader = wwwAuthenticateHeader {
            // Parse the WWW-Authenticate header for resource_metadata URL
            if let parsedURL = try await authenticator.parseWWWAuthenticateHeader(wwwAuthHeader) {
                logger.info(
                    "Found resource metadata URL in WWW-Authenticate header: \(parsedURL.absoluteString)"
                )
                metadataURL = parsedURL
            }
        }

        // 2. Create a list of URLs to attempt
        var urlsToAttempt: [URL] = []
        if let metadataURL {
            urlsToAttempt.insert(metadataURL, at: 0)
        }
        for metadataPath in metadataPaths {
            let url = endpointURL.appending(path: metadataPath)
            let baseDomainURL = getBaseDomainURL(from: endpoint)?.appending(path: metadataPath)

            urlsToAttempt.append(url)
            if let baseDomainURL {
                urlsToAttempt.append(baseDomainURL)
            }
        }

        // 3. Fetch protected resource metadata from MCP server
        var metadata: OAuthAuthenticator.ProtectedResourceMetadata? = nil

        // Looping through the list of URLs to attempt
        while !urlsToAttempt.isEmpty, metadata == nil {
            let metadataURL = urlsToAttempt.removeFirst()

            do {
                metadata = try await authenticator.fetchProtectedResourceMetadata(from: metadataURL)
            } catch {
                logger.info(
                    "Failed to fetch protected resource metadata from \(metadataURL.absoluteString)"
                )
                if urlsToAttempt.isEmpty {
                    break
                } else {
                    continue
                }
            }
        }

        // Step 3: Select the first authorization server from the metadata
        let authServerURL =
            if let firstAuthServerString = metadata?.authorizationServers?.first,
            let url = URL(string: firstAuthServerString) {
                url
            } else {
                // If no metadata URLs were found, try to use the endpoint URL
                endpoint
            }

        logger.info(
            "Found authorization server", metadata: ["server": "\(authServerURL.absoluteString)"]
        )

        // Step 4: Discover authorization server metadata using MCP priority order
        let discoveryDocument = try await authenticator.discoverAuthorizationServerMetadata(
            from: authServerURL
        )

        // Step 5: Validate PKCE support (required by MCP)
        try await authenticator.validatePKCESupport(in: discoveryDocument)

        return (authServerURL, discoveryDocument)
    }

    private func handlePublicClientFlow(
        discoveryDocument: OAuthAuthenticator.OAuthDiscoveryDocument
    ) async throws {
        let currentConfig = await authenticator.configuration

        if currentConfig.clientType == .confidential {
            logger.info("Step 2/4: Confidential client detected - client credentials flow")

            let mcpConfig = try createMCPConfiguration(
                from: discoveryDocument,
                basedOn: currentConfig,
                usePKCE: currentConfig.usePKCE
            )

            authenticator = try await createAuthenticator(with: mcpConfig)

            let token = try await authenticator.authenticateClientCredentials(identifier: tokenIdentifier)
            try await updateTransportWithToken(token)
            logger.info("OAuth HTTP transport connected with new token")
            return
        }

        logger.info("Step 2/4: Resolving redirect URI for interactive authentication...")
        let redirectURI = try await resolveRedirectURI(for: currentConfig)
        logger.info("Step 2/4: Redirect URI resolved")

        logger.info("Step 3/4: Public client detected - authorization code flow with PKCE required")

        var mcpConfig = try createMCPConfiguration(
            from: discoveryDocument,
            basedOn: currentConfig,
            usePKCE: true
        )

        if let registrationEndpoint = discoveryDocument.registrationEndpoint,
           let clientName
        {
            logger.info("Step 3/4: Registration endpoint found, performing automatic client registration...")

            let registration = try await authenticator.registerClient(
                registrationEndpoint: registrationEndpoint,
                clientName: clientName,
                redirectURIs: [redirectURI],
                scopes: discoveryDocument.scopesSupported ?? []
            )

            logger.info(
                "Step 3/4: Client registered successfully", metadata: ["clientId": "\(registration.clientId)"]
            )

            mcpConfig = try OAuthConfiguration(
                authorizationEndpoint: discoveryDocument.authorizationEndpoint,
                tokenEndpoint: discoveryDocument.tokenEndpoint,
                revocationEndpoint: discoveryDocument.revocationEndpoint,
                clientId: registration.clientId,
                clientSecret: registration.clientSecret,
                scopes: discoveryDocument.scopesSupported ?? [],
                redirectURIResolver: currentConfig.redirectURIResolver,
                usePKCE: true,
                resourceIndicator: endpoint.absoluteString
            )
        }

        // Update authenticator with new configuration
        authenticator = try await createAuthenticator(with: mcpConfig)

        // Trigger interactive authentication
        logger.info("Step 4/4: Starting interactive authentication (opening browser)...")
        let token = try await authenticator.authenticate(
            identifier: tokenIdentifier,
            redirectURIOverride: redirectURI
        )
        logger.info("Step 4/4: Interactive authentication completed successfully")

        // Update transport and reconnect
        try await updateTransportWithToken(token)
        logger.info("OAuth HTTP transport connected with new token")
    }

    private func createMCPConfiguration(
        from discoveryDocument: OAuthAuthenticator.OAuthDiscoveryDocument,
        basedOn originalConfig: OAuthConfiguration,
        usePKCE: Bool
    ) throws -> OAuthConfiguration {
        try OAuthConfiguration(
            authorizationEndpoint: discoveryDocument.authorizationEndpoint,
            tokenEndpoint: discoveryDocument.tokenEndpoint,
            revocationEndpoint: discoveryDocument.revocationEndpoint,
            clientId: originalConfig.clientId,
            clientSecret: originalConfig.clientSecret,
            clientType: originalConfig.clientType,
            scopes: discoveryDocument.scopesSupported ?? [],
            redirectURIResolver: originalConfig.redirectURIResolver,
            usePKCE: usePKCE,
            resourceIndicator: endpoint.absoluteString // MCP server as resource
        )
    }

    /// Performs dynamic client registration and updates the transport configuration
    ///
    /// Call this after receiving a 401 response to register your client and get OAuth credentials.
    ///
    /// - Parameters:
    ///   - clientName: Human-readable name for your application
    ///   - redirectURIs: Redirect URIs for OAuth callbacks
    ///   - scopes: OAuth scopes to request
    ///   - softwareId: Optional software identifier
    ///   - softwareVersion: Optional software version
    /// - Returns: The registered OAuth configuration
    public func performDynamicRegistration(
        clientName: String,
        redirectURIs: [URL],
        scopes: [String] = [],
        softwareId _: String? = nil,
        softwareVersion _: String? = nil
    ) async throws -> OAuthConfiguration {
        logger.info("Starting dynamic client registration")

        // The discovery should have already happened via performMCPOAuthDiscovery
        // Now we need to register the client

        // Get the current discovery document (should be cached from discovery)
        // For now, we'll need to re-discover - in a production implementation,
        // we'd cache the discovery document
        let (_, discoveryDocument) = try await discoverOAuthServerMetadata()

        // Check if registration endpoint exists
        guard let registrationEndpoint = discoveryDocument.registrationEndpoint else {
            throw OAuthAuthenticator.OAuthError.registrationEndpointNotFound
        }

        // Register the client
        let registration = try await authenticator.registerClient(
            registrationEndpoint: registrationEndpoint,
            clientName: clientName,
            redirectURIs: redirectURIs,
            scopes: scopes
        )

        // Create new configuration with registered client details
        let newConfig = try OAuthConfiguration(
            authorizationEndpoint: discoveryDocument.authorizationEndpoint,
            tokenEndpoint: discoveryDocument.tokenEndpoint,
            revocationEndpoint: discoveryDocument.revocationEndpoint,
            clientId: registration.clientId,
            clientSecret: registration.clientSecret, // Will be nil for public clients
            scopes: scopes,
            redirectURIResolver: redirectURIs.first.map { redirectURI in
                { @Sendable in redirectURI }
            },
            resourceIndicator: endpoint.absoluteString
        )

        // Update the authenticator with the new configuration
        authenticator = OAuthAuthenticator(
            configuration: newConfig,
            tokenStorage: authenticator.tokenStorage,
            urlSession: authenticator.urlSession,
            logger: authenticator.logger
        )

        logger.info(
            "Dynamic registration complete", metadata: ["clientId": "\(registration.clientId)"]
        )
        return newConfig
    }

    private func createAuthenticator(with configuration: OAuthConfiguration) async throws
        -> OAuthAuthenticator
    {
        OAuthAuthenticator(
            configuration: configuration,
            tokenStorage: authenticator.tokenStorage,
            urlSession: authenticator.urlSession,
            logger: authenticator.logger
        )
    }

    private func resolveRedirectURI(for configuration: OAuthConfiguration) async throws -> URL {
        do {
            guard let redirectURI = try await configuration.resolveRedirectURI() else {
                throw OAuthAuthenticator.OAuthError.redirectURIRequired
            }

            return redirectURI
        } catch let error as OAuthAuthenticator.OAuthError {
            throw error
        } catch {
            throw OAuthAuthenticator.OAuthError.redirectURIResolutionFailed("\(error)")
        }
    }

    private func updateTransportWithToken(_ token: OAuthToken) async throws {
        let oldTransport = baseTransport

        // Update transport with new token
        updateBaseTransport(with: token)

        // Disconnect the old transport after replacement so active OAuth receive streams
        // move to the new base transport instead of finishing the public OAuth stream.
        await oldTransport.disconnect()

        // Only reconnect if we're in connected state
        if isConnected {
            try await baseTransport.connect()
        }
    }
}

// MARK: - Convenience Initializers

public extension OAuthHTTPClientTransport {
    /// Creates an OAuth transport with client credentials flow
    static func clientCredentials(
        endpoint: URL,
        tokenEndpoint: URL,
        clientId: String,
        clientSecret: String,
        scopes: [String] = [],
        tokenStorage: TokenStorage? = nil,
        logger: Logger? = nil
    ) throws -> OAuthHTTPClientTransport {
        let config = try OAuthConfiguration(
            authorizationEndpoint: tokenEndpoint, // Not used for client credentials
            tokenEndpoint: tokenEndpoint,
            clientId: clientId,
            clientSecret: clientSecret,
            scopes: scopes,
            redirectURIResolver: nil
        )

        return OAuthHTTPClientTransport(
            endpoint: endpoint,
            oauthConfig: config,
            tokenStorage: tokenStorage,
            logger: logger
        )
    }
}
