import Darwin
import Logging
import SystemPackage

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

/// Protocol defining the transport layer for MCP communication
public protocol Transport: Actor {
    var logger: Logger { get }

    /// Establishes connection with the transport
    func connect() async throws

    /// Disconnects from the transport
    func disconnect() async

    /// Sends a message string
    func send(_ message: String) async throws

    /// Receives message strings as an async sequence
    func receive() -> AsyncThrowingStream<String, Swift.Error>
}

/// Standard input/output transport implementation
public actor StdioTransport: Transport {
    private let input: FileDescriptor
    private let output: FileDescriptor
    public nonisolated let logger: Logger

    private var isConnected = false
    private let messageStream: AsyncStream<String>
    private let messageContinuation: AsyncStream<String>.Continuation

    public init(
        input: FileDescriptor = FileDescriptor.standardInput,
        output: FileDescriptor = FileDescriptor.standardOutput,
        logger: Logger? = nil
    ) {
        self.input = input
        self.output = output
        self.logger =
            logger
            ?? Logger(
                label: "mcp.transport.stdio",
                factory: { _ in SwiftLogNoOpLogHandler() })

        // Create message stream
        var continuation: AsyncStream<String>.Continuation!
        self.messageStream = AsyncStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    public func connect() async throws {
        guard !isConnected else { return }

        // Set non-blocking mode
        try setNonBlocking(fileDescriptor: input)
        try setNonBlocking(fileDescriptor: output)

        isConnected = true
        logger.info("Transport connected successfully")

        // Start reading loop in background
        Task {
            await readLoop()
        }
    }

    private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags >= 0 else {
            throw Error.transportError(Errno.badFileDescriptor)
        }
        let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw Error.transportError(Errno.badFileDescriptor)
        }
    }

    private func readLoop() async {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()

        while isConnected && !Task.isCancelled {
            do {
                let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try input.read(into: UnsafeMutableRawBufferPointer(pointer))
                }

                if bytesRead == 0 {
                    logger.notice("EOF received")
                    break
                }

                pendingData.append(Data(buffer[..<bytesRead]))

                // Process complete messages
                while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = pendingData[..<newlineIndex]
                    pendingData = pendingData[(newlineIndex + 1)...]

                    if let message = String(data: messageData, encoding: .utf8),
                        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        logger.debug("Message received", metadata: ["message": "\(message)"])
                        messageContinuation.yield(message)
                    }
                }
            } catch let error as Errno where error == .resourceTemporarilyUnavailable {
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms backoff
                continue
            } catch {
                if !Task.isCancelled {
                    logger.error("Read error occurred", metadata: ["error": "\(error)"])
                }
                break
            }
        }

        messageContinuation.finish()
    }

    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        messageContinuation.finish()
        logger.info("Transport disconnected")
    }

    public func send(_ message: String) async throws {
        guard isConnected else {
            throw Error.transportError(Errno.socketNotConnected)
        }

        let message = message + "\n"
        guard let data = message.data(using: .utf8) else {
            throw Error.transportError(Errno.invalidArgument)
        }

        var remaining = data
        while !remaining.isEmpty {
            do {
                let written = try remaining.withUnsafeBytes { buffer in
                    try output.write(UnsafeRawBufferPointer(buffer))
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                }
            } catch let error as Errno where error == .resourceTemporarilyUnavailable {
                try await Task.sleep(nanoseconds: 10_000_000)  // 10ms backoff
                continue
            } catch {
                throw Error.transportError(error)
            }
        }
    }

    public func receive() -> AsyncThrowingStream<String, Swift.Error> {
        return AsyncThrowingStream { continuation in
            Task {
                for await message in messageStream {
                    continuation.yield(message)
                }
                continuation.finish()
            }
        }
    }
}
