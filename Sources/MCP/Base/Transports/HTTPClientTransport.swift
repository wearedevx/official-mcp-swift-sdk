import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public actor HTTPClientTransport: Actor, Transport {
    public var endpoint: URL
    public var endpointPostURL: URL?
    private let session: URLSession
    public private(set) var sessionID: String?
    private let streaming: Bool
    private var streamingTask: Task<Void, Never>?
    private var lastEventID: String?
    public nonisolated let logger: Logger
    public var endpointCommunication: URL?
    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    private var eventListeningError: Error?

    private let requestModifier: (@Sendable (URLRequest) async -> URLRequest)?

    public init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        streaming: Bool = false,
        requestModifier: (@Sendable (URLRequest) async -> URLRequest)? = nil,
        logger: Logger? = nil,
        endpointCommunication: URL? = nil
    ) {
        self.init(
            endpoint: endpoint,
            session: URLSession(configuration: configuration),
            streaming: streaming,
            requestModifier: requestModifier,
            logger: logger,
            endpointCommunication: endpointCommunication
        )
    }

    init(
        endpoint: URL,
        session: URLSession,
        streaming: Bool = false,
        requestModifier: (@Sendable (URLRequest) async -> URLRequest)? = nil,
        logger: Logger? = nil,
        endpointCommunication: URL? = nil
    ) {
        self.endpoint = endpoint
        self.session = session
        self.streaming = streaming
        self.requestModifier = requestModifier
        eventListeningError = nil

        // Create message stream
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        messageStream = AsyncThrowingStream { continuation = $0 }
        messageContinuation = continuation

        self.logger =
            logger
                ?? Logger(
                    label: "mcp.transport.http.client",
                    factory: { _ in SwiftLogNoOpLogHandler() }
                )
        self.endpointCommunication = endpointCommunication
    }

    /// Establishes connection with the transport
    public func connect() async throws {
        eventListeningError = nil

        guard !isConnected else { return }
        isConnected = true

        if streaming {
            // Start listening to server events
            streamingTask = Task.detached { await self.startListeningForServerEvents() }
        }

        // wait for the connection to happen with a valid endpoint
        let timeoutNs = 45_000_000_000 // 45 seconds
        let sleepIntervalNs: UInt64 = 50_000_000 // 50 ms
        var elapsedNs: UInt64 = 0

        while endpointPostURL == nil, eventListeningError == nil {
            if elapsedNs >= timeoutNs {
                throw MCPError.internalError("Timeout waiting for valid endpoint from SSE")
            }
            try await Task.sleep(nanoseconds: sleepIntervalNs)
            elapsedNs += sleepIntervalNs
        }

        if let eventListeningError {
            logger.error(
                "HTTP transport failed to connect: \(eventListeningError.localizedDescription)")
            throw eventListeningError
        }

        logger.info("HTTP transport connected")
    }

    /// Disconnects from the transport
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        // Cancel streaming task if active
        streamingTask?.cancel()
        streamingTask = nil

        // Finish outstanding tasks and invalidate the session
        session.finishTasksAndInvalidate()

        // Clean up message stream
        messageContinuation.finish()

        logger.info("HTTP clienttransport disconnected")
    }

    /// Sends data through an HTTP POST request
    public func send(_ data: Data) async throws {
        var request = URLRequest(url: endpointPostURL ?? endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = data

        // Add session ID if available
        if let sessionID {
            request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        if let requestModifier {
            request = await requestModifier(request)
        }

        let repr = """
        \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "<no url>")
        \(request.allHTTPHeaderFields?.map { "\($0.0): \($0.1)" }.joined(separator: "\n") ?? "")

        \(String(data: data, encoding: .utf8) ?? "<no-data>")
        """

        logger.info("SENDING: \(repr)")

        let (stream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPError.internalError("Invalid HTTP response")
        }

        // Process the response based on content type and status code
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

        // Extract session ID if present
        if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSessionID
            logger.info("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
        }

        // Handle different response types
        switch httpResponse.statusCode {
        case 200, 201, 202:
            // For SSE, the processing happens in the streaming task
            if contentType.contains("text/event-stream") {
                logger.info("Received SSE response, processing in streaming task")

                try await decodeSSEStream(stream) { message in
                    self.logger.info("Received Streamed message \(String(data: message, encoding: .utf8) ?? "<binary data>")")
                    self.messageContinuation.yield(message)
                }
                return
            }

            // For JSON responses, deliver the data directly
            if contentType.contains("application/json") {
                var data = Data()
                for try await byte in stream {
                    data.append(byte)
                }

                logger.info("Received JSON response", metadata: ["size": "\(data.count)"])
                messageContinuation.yield(data)
            }

        case 401:
            let wwwAuthenticate = httpResponse.value(forHTTPHeaderField: "WWW-Authenticate")
            throw MCPError.unauthorized(wwwAuthenticate)

        case 404:
            // If we get a 404 with a session ID, it means our session is invalid
            if sessionID != nil {
                logger.warning("Session has expired")
                sessionID = nil
                throw MCPError.internalError("Session expired")
            }
            throw MCPError.invalidRequest("Endpoint not found")

        case 405:
            throw MCPError.methodNotFound("Method not found")

        default:
            throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
        }
    }

    /// Receives data in an async sequence
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    // MARK: - SSE

    /// Starts listening for server events using SSE
    private func startListeningForServerEvents() async {
        guard isConnected else { return }

        // Retry loop for connection drops
        while isConnected, !Task.isCancelled {
            do {
                try await connectToEventStream()
            } catch let MCPError.invalidParams(error) {
                logger.error("Invalid connection parameters: \(error ?? "unknow")")
                self.eventListeningError = MCPError.invalidParams(error)
                break
            } catch let MCPError.unauthorized(wwwAuthenticateHeader) {
                eventListeningError = MCPError.unauthorized(wwwAuthenticateHeader)
                logger.error("Unauthorized")
                break
            } catch MCPError.unsupportedMethod {
                eventListeningError = MCPError.unsupportedMethod
                logger.warning("Connection to MCP server does not support this method")
                break
            } catch {
                if !Task.isCancelled {
                    logger.error("SSE connection error: \(error)")
                    // Wait before retrying
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
            }
        }
    }

    #if canImport(FoundationNetworking)
        private func connectToEventStream() async throws {
            logger.warning("SSE is not supported on this platform")
        }
    #else
        /// Establishes an SSE connection to the server
        private func connectToEventStream() async throws {
            guard isConnected else { return }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.addValue("text/event-stream", forHTTPHeaderField: "Accept")

            request.addValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")

            // Add session ID if available
            if let sessionID {
                request.addValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            }

            // Add Last-Event-ID header for resumability if available
            if let lastEventID {
                request.addValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
            }

            if let requestModifier {
                request = await requestModifier(request)
            }

            logger.debug("Starting SSE connection")

            // Create URLSession task for SSE
            let (stream, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            func consumeBody(_ stream: URLSession.AsyncBytes) async throws -> String {
                var data = Data()
                for try await byte in stream {
                    data.append(byte)
                }
                return String(data: data, encoding: .utf8) ?? ""
            }

            switch httpResponse.statusCode {
            case 200: break

            case 400:
                let rawBody = try? await consumeBody(stream)

                endpointPostURL = endpoint
                logger.error("MCP Connection invalid params BODY: \(rawBody)")
                throw MCPError.invalidParams("Invalid parameters provided")

            case 401:
                let wwwAuthenticateHeader = httpResponse.value(
                    forHTTPHeaderField: "WWW-Authenticate")
                throw MCPError.unauthorized(wwwAuthenticateHeader)

            case 404:
                let rawBody = try? await consumeBody(stream)
                logger.error("MCP Connection Endpoint not found BODY: \(rawBody)")
                throw MCPError.internalError("Endpoint not found")

            case 405:
                throw MCPError.unsupportedMethod

            default:
                throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
            }

            // Extract session ID if present
            if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
                sessionID = newSessionID
            }

            // Process the SSE stream
            try await decodeSSEStream(stream) { message in
                self.messageContinuation.yield(message)
            }
        }
    #endif

    private func decodeSSEStream(
        _ stream: URLSession.AsyncBytes, handleMessage: @escaping @Sendable (Data) -> Void
    ) async throws {
        var buffer: [UInt8] = []
        var eventType = ""
        var eventID: String?
        var eventData = ""

        for try await byte in stream {
            if Task.isCancelled { break }

            buffer.append(byte)

            if String(bytes: [byte], encoding: .utf8) == "\n" {
                // Process complete lines
                Task(priority: .userInitiated) {
                    guard let lines = String(bytes: buffer, encoding: .utf8)
                    else {
                        buffer.removeAll()
                        return
                    }
                    buffer.removeAll()

                    for line in lines.split(separator: "\n", omittingEmptySubsequences: false) {
                        // Empty line marks the end of an event
                        if line.isEmpty || line == "\r" || line == "\n" || line == "\r\n" {
                            if !eventData.isEmpty {
                                // Process the event
                                if eventType == "id" {
                                    lastEventID = eventID
                                } else if eventType == "endpoint" {
                                    if let endpointCommunication {
                                        if let newEndpoint = URL(
                                            string:
                                            "\(endpointCommunication.absoluteString)\(eventData)"
                                        ) {
                                            endpointPostURL = newEndpoint
                                            logger.info(
                                                "Received new endpoint via SSE with endpointCommunication: \(newEndpoint.absoluteString)"
                                            )
                                        } else {
                                            logger.error(
                                                "Failed to construct new endpoint URL from SSE data: \(eventData)"
                                            )
                                        }
                                    } else if let scheme = endpoint.scheme, let host = endpoint.host {
                                        // Construct the new endpoint URL using the original scheme and host
                                        let portString = endpoint.port.map { ":\($0)" } ?? ""
                                        if let newEndpoint = URL(
                                            string: "\(scheme)://\(host)\(portString)\(eventData)")
                                        {
                                            endpointPostURL = newEndpoint
                                            logger.info(
                                                "Received new endpoint via SSE: \(newEndpoint.absoluteString)"
                                            )
                                        } else {
                                            logger.error(
                                                "Failed to construct new endpoint URL from SSE data: \(eventData)"
                                            )
                                        }
                                    } else {
                                        logger.error(
                                            "Original endpoint is missing scheme or host, cannot construct new endpoint."
                                        )
                                    }
                                } else {
                                    // Default event type is "message" if not specified
                                    if let data = eventData.data(using: .utf8) {
                                        logger.debug(
                                            "SSE event received",
                                            metadata: [
                                                "type":
                                                    "\(eventType.isEmpty ? "message" : eventType)",
                                                "id": "\(eventID ?? "none")",
                                            ]
                                        )
                                        handleMessage(data)
                                    }
                                }

                                // Reset for next event
                                eventType = ""
                                eventData = ""
                            }
                            return
                        }

                        // Lines starting with ":" are comments
                        if line.hasPrefix(":") { return }

                        // Parse field: value format
                        if let colonIndex = line.firstIndex(of: ":") {
                            let field = String(line[..<colonIndex])
                            var value = String(line[line.index(after: colonIndex)...])

                            // Trim leading space
                            if value.hasPrefix(" ") {
                                value = String(value.dropFirst())
                            }

                            // Process based on field
                            switch field {
                            case "event":
                                eventType = value

                            case "data":
                                if !eventData.isEmpty {
                                    eventData.append("\n")
                                }
                                eventData.append(value)

                            case "id":
                                if !value.contains("\0") { // ID must not contain NULL
                                    eventID = value
                                    lastEventID = value
                                }

                            case "retry":
                                // Retry timing not implemented
                                break

                            default:
                                // Unknown fields are ignored per SSE spec
                                break
                            }
                        }
                    }
                }
            }
        }
    }
}
