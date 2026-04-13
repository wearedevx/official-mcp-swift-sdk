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
    private var isListeningForServerEvents = false
    private var eventListeningError: MCPError?
    private var messageStream: AsyncThrowingStream<Data, Swift.Error>
    private var messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

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
        guard !isConnected else { return }
        isConnected = true

        guard streaming else {
            logger.info("HTTP transport connected")
            return
        }

        eventListeningError = nil

        // Start listening to server events
        streamingTask = Task { await startListeningForServerEvents() }

        // wait for the connection to happen with a valid endpoint
        let timeoutNs = 45_000_000_000 // 45 seconds
        let sleepIntervalNs: UInt64 = 50_000_000 // 50 ms
        var elapsedNs: UInt64 = 0

        while !isListeningForServerEvents, eventListeningError == nil {
            if elapsedNs >= timeoutNs {
                throw MCPError.internalError("Timeout waiting for valid endpoint from SSE")
            }
            try await Task.sleep(nanoseconds: sleepIntervalNs)
            elapsedNs += sleepIntervalNs
        }

        if let eventListeningError {
            logger.warning(
                "HTTP transport failed to connect: \(eventListeningError.localizedDescription)"
            )
        }

        logger.info("HTTP transport connected")
    }

    /// Disconnects from the transport
    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false

        // Cancel streaming task if active
        streamingTask?.cancel()
        await streamingTask?.value
        streamingTask = nil

        // Finish outstanding tasks and invalidate the session
        session.finishTasksAndInvalidate()

        // Clean up message stream
        messageContinuation.finish()

        logger.info("HTTP clienttransport disconnected")
    }

    /// Sends data through an HTTP POST request
    public func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.internalError("Transport not connected")
        }

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

        logger.info("Sending request", metadata: ["url": "\(request.url!.absoluteString)"])

        let (responseData, response) = try await session.data(for: request)

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
                // The streaming is handled by the SSE task if active
                return
            }

            // For JSON responses, deliver the data directly
            if contentType.contains("application/json"), !responseData.isEmpty {
                logger.info("Received JSON response", metadata: ["size": "\(responseData.count)"])
                messageContinuation.yield(responseData)
            }

        case 400:
            let rawBody = String(data: responseData, encoding: .utf8) ?? "<nil>"
            logger.error("MCP invalid request body: \(rawBody)")
            throw MCPError.invalidRequest(rawBody)

        case 404:
            // If we get a 404 with a session ID, it means our session is invalid
            if sessionID != nil {
                logger.warning("Session has expired")
                sessionID = nil
                throw MCPError.internalError("Session expired")
            }
            throw MCPError.internalError("Endpoint not found")

        case 405:
            throw MCPError.methodNotFound("Method not found")

        default:
            throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
        }
    }

    /// Receives data in an async sequence
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - SSE

    /// Starts listening for server events using SSE
    private func startListeningForServerEvents() async {
        guard isConnected else { return }
        isListeningForServerEvents = false

        // Retry loop for connection drops
        while isConnected, !Task.isCancelled {
            do {
                try await connectToEventStream()
            } catch let MCPError.invalidParams(error) {
                eventListeningError = MCPError.invalidParams(error)
                logger.error("Invalid connection parameters: \(error ?? "unknow")")
                break
            } catch let MCPError.unauthorized(wwwAuthenticateHeader) {
                eventListeningError = MCPError.unauthorized(wwwAuthenticateHeader)
                logger.error("Unauthorized")
                break
            } catch MCPError.methodNotFound {
                eventListeningError = MCPError.methodNotFound("Method not found")
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

            logger.info("Starting SSE connection")

            guard isConnected else { return }
            // Create URLSession task for SSE
            let (stream, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPError.internalError("Invalid HTTP response")
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""

            func consumeBody(_ stream: URLSession.AsyncBytes) async -> String {
                var data = Data()
                do {
                    for try await byte in stream {
                        data.append(byte)
                    }
                } catch {
                    return "<unreadable: \(error)>"
                }
                return String(data: data, encoding: .utf8) ?? ""
            }

            switch httpResponse.statusCode {
            case 200:
                if contentType.starts(with: "text/event-stream") {
                    isListeningForServerEvents = true
                } else {
                    throw MCPError.methodNotFound("Returned content type: \(contentType)")
                }

            case 400:
                let rawBody = await consumeBody(stream)
                throw MCPError.invalidParams("Invalid parameters provided \(rawBody)")

            case 401:
                let wwwAuthHeader = httpResponse.value(forHTTPHeaderField: "WWW-Authenticate")
                throw MCPError.unauthorized(wwwAuthHeader)

            case 405:
                throw MCPError.methodNotFound("Method not found")

            default:
                throw MCPError.internalError("HTTP error: \(httpResponse.statusCode)")
            }

            // Extract session ID if present
            if let newSessionID = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
                sessionID = newSessionID
            }

            // Process the SSE stream
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
                                        } else if let scheme = endpoint.scheme,
                                                  let host = endpoint.host
                                        {
                                            // Construct the new endpoint URL using the original scheme and host
                                            let portString = endpoint.port.map { ":\($0)" } ?? ""
                                            if let newEndpoint = URL(
                                                string:
                                                "\(scheme)://\(host)\(portString)\(eventData)"
                                            ) {
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
                                            logger.info(
                                                "SSE event received",
                                                metadata: [
                                                    "type":
                                                        "\(eventType.isEmpty ? "message" : eventType)",
                                                    "id": "\(eventID ?? "none")",
                                                ]
                                            )
                                            messageContinuation.yield(data)
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
    #endif
}
