import Logging

import Foundation

actor StreamableHTTPTransport: Transport {
    var logger: Logging.Logger {
        Logger(label: "mcp.transport.streamaable-http.client")
    }

    var endpoint: URL

    private var sessionID: String?
    private var lastEventID: String?

    private var session: URLSession
    private var isConnected = false

    private var error: MCPError?

    private let requestModifier: (@Sendable (URLRequest) async -> URLRequest)?

    private var streamID: UUID = .init()
    private var messageStream: AsyncThrowingStream<Data, Swift.Error>
    private var messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    init(
        endpoint: URL,
        configuration: URLSessionConfiguration = .default,
        requestModifier: (@Sendable (URLRequest) async -> URLRequest)? = nil
    ) {
        self.endpoint = endpoint
        self.requestModifier = requestModifier
        session = URLSession(configuration: configuration)

        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()

        messageStream = stream
        messageContinuation = continuation
    }

    func connect() async throws {
        isConnected = true
    }

    func disconnect() async {
        streamID = UUID()
        messageContinuation.finish()
        isConnected = false

        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()

        messageStream = stream
        messageContinuation = continuation
    }

    func send(_ data: Data) async throws {
        guard isConnected else { return }

        var request = URLRequest(url: endpoint)
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
            logger.debug("Session ID received", metadata: ["sessionID": "\(newSessionID)"])
        }

        // Handle different response types
        switch httpResponse.statusCode {
        case 200, 201, 202:
            // For SSE, the processing happens in the streaming task
            if contentType.contains("text/event-stream") {
                logger.debug("Received SSE response, processing in streaming task")

                let streamID = self.streamID
                let continuation = messageContinuation
                try await decodeSSEStream(stream) { [weak self] message in
                    guard let self,
                          await streamID == self.streamID
                    else { return }
                    continuation.yield(message)
                }
                return
            }

            // For JSON responses, deliver the data directly
            if contentType.contains("application/json") {
                var data = Data()
                for try await byte in stream {
                    data.append(byte)
                }

                logger.debug("Received JSON response", metadata: ["size": "\(data.count)"])
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

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    private func decodeSSEStream(
        _ stream: URLSession.AsyncBytes, handleMessage: @escaping @Sendable (Data) async -> Void
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
                                        await handleMessage(data)
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
