@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)

    // MARK: - Test trait

    /// A test trait that automatically manages the mock URL protocol handler for HTTP client transport tests.
    struct OAuthHTTPClientTransportTestSetupTrait: TestTrait, TestScoping {
        func provideScope(
            for test: Test, testCase: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            // Clear handler before test
            await OAuthMockURLProtocol.requestHandlerStorage.clearHandler()

            // Execute the test
            try await function()

            // Clear handler after test
            await OAuthMockURLProtocol.requestHandlerStorage.clearHandler()
        }
    }

    extension Trait where Self == OAuthHTTPClientTransportTestSetupTrait {
        static var oauthHttpClientTransportSetup: Self { Self() }
    }

    // MARK: - Mock Handler Registry Actor

    actor OAuthRequestHandlerStorage {
        private var requestHandler:
            (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

        func setHandler(
            _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
        ) async {
            requestHandler = handler
        }

        func clearHandler() async {
            requestHandler = nil
        }

        func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            guard let handler = requestHandler else {
                throw OAuthMockURLProtocolError.noRequestHandler
            }
            return try await handler(request)
        }
    }

    // MARK: - Helper Methods

    extension URLRequest {
        fileprivate func readBody() -> Data? {
            if let httpBodyData = self.httpBody {
                return httpBodyData
            }

            guard let bodyStream = self.httpBodyStream else { return nil }
            bodyStream.open()
            defer { bodyStream.close() }

            let bufferSize: Int = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            var data = Data()
            while bodyStream.hasBytesAvailable {
                let bytesRead = bodyStream.read(buffer, maxLength: bufferSize)
                data.append(buffer, count: bytesRead)
            }
            return data
        }
    }

    // MARK: - Mock URL Protocol

    final class OAuthMockURLProtocol: URLProtocol, @unchecked Sendable {
        static let requestHandlerStorage = OAuthRequestHandlerStorage()

        static func setHandler(
            _ handler: @Sendable @escaping (URLRequest) async throws -> (HTTPURLResponse, Data)
        ) async {
            await requestHandlerStorage.setHandler { request in
                try await handler(request)
            }
        }

        func executeHandler(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            return try await Self.requestHandlerStorage.executeHandler(for: request)
        }

        override class func canInit(with request: URLRequest) -> Bool {
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }

        override func startLoading() {
            Task {
                do {
                    let (response, data) = try await self.executeHandler(for: request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }

        override func stopLoading() {}
    }

    enum OAuthMockURLProtocolError: Swift.Error {
        case noRequestHandler
        case invalidURL
        case sseConnectionAttempted
    }

    // MARK: -

    @Suite("OAuth HTTP Client Transport Tests", .serialized)
    struct OAuthHTTPClientTransportTests {
        let testEndpoint = URL(string: "http://localhost:8080/mcp")!
        let tokenEndpoint = URL(string: "http://localhost:8080/token")!

        @Test("Initialize Before Connect Flow", .oauthHttpClientTransportSetup)
        func testInitializeBeforeConnect() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OAuthMockURLProtocol.self]

            // 1. Setup OAuth Transport
            // We use a dummy config initially
            let oauthConfig = try OAuthConfiguration(
                authorizationEndpoint: tokenEndpoint,
                tokenEndpoint: tokenEndpoint,
                clientId: "test-client",
                clientSecret: "test-secret"
            )

            let transport = OAuthHTTPClientTransport(
                endpoint: testEndpoint,
                oauthConfig: oauthConfig,
                configuration: configuration,
                streaming: true, // Enable streaming to test that it DOESN'T connect prematurely
                logger: nil
            )

            // 2. Prepare Initialize Request Data
            let initializeRequest = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(using: .utf8)!
            
            // 3. Setup Mock Handler for 401 Unauthorized (Triggering Discovery/Auth)
            await OAuthMockURLProtocol.setHandler { request in
                // Expect POST to endpoint
                if request.url == testEndpoint && request.httpMethod == "POST" {
                     let response = HTTPURLResponse(
                        url: testEndpoint,
                        statusCode: 401,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "WWW-Authenticate": "Bearer realm=\"test\", resource_metadata=\"http://localhost:8080/.well-known/oauth-protected-resource\""
                        ]
                    )!
                    return (response, Data())
                }
                
                // Expect Metadata Fetch
                if request.url?.absoluteString == "http://localhost:8080/.well-known/oauth-protected-resource" {
                     let metadata = """
                    {
                        "authorization_servers": ["http://localhost:8080"],
                        "resource": "http://localhost:8080/mcp"
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                    return (response, metadata)
                }
                
                // Expect Auth Server Metadata Discovery
                if request.url?.absoluteString == "http://localhost:8080/.well-known/oauth-authorization-server" {
                    let metadata = """
                    {
                        "issuer": "http://localhost:8080",
                        "authorization_endpoint": "http://localhost:8080/authorize",
                        "token_endpoint": "http://localhost:8080/token",
                        "response_types_supported": ["code"],
                        "code_challenge_methods_supported": ["S256"]
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                    return (response, metadata)
                }
                
                // Expect Token Request (Client Credentials flow for this test simplicity, or we mock the flow used)
                // The current implementation tries Client Credentials if Confidential client.
                if request.url == tokenEndpoint {
                     let tokenResponse = """
                    {
                        "access_token": "new-access-token",
                        "token_type": "Bearer",
                        "expires_in": 3600
                    }
                    """.data(using: .utf8)!
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                    return (response, tokenResponse)
                }
                
                // Expect Retry of Initialize Request with Token
                if request.url == testEndpoint && request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access-token" {
                     let responseData = #"{"jsonrpc":"2.0","result":{},"id":1}"#.data(using: .utf8)!
                     let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
                    return (response, responseData)
                }
                
                // FAIL if we see an SSE connection attempt (GET with text/event-stream)
                if request.value(forHTTPHeaderField: "Accept") == "text/event-stream" {
                    throw OAuthMockURLProtocolError.sseConnectionAttempted
                }

                throw OAuthMockURLProtocolError.invalidURL
            }

            // 4. Send Initialize Request (Should trigger auth flow but NOT SSE connect)
            // Note: We do NOT call transport.connect() yet.
            try await transport.send(initializeRequest)
            
            // 5. Now Call Connect (Should trigger SSE)
            await OAuthMockURLProtocol.setHandler { request in
                 if request.value(forHTTPHeaderField: "Accept") == "text/event-stream" {
                    // Success!
                    let response = HTTPURLResponse(
                        url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"])!
                    return (response, Data())
                }
                throw OAuthMockURLProtocolError.invalidURL
            }
            
            try await transport.connect()
        }
    }

#endif
