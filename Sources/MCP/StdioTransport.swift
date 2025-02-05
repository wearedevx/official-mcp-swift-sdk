import Foundation

/// A transport implementation that communicates over standard input/output
public actor StdioTransport: MCPTransport {
    private var isConnected = false
    private let processQueue = DispatchQueue(label: "com.mcp.stdio", qos: .userInitiated)
    private let process: Process
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    
    public init(command: String, arguments: [String] = [], environment: [String: String]? = nil) {
        self.process = Process()
        self.process.executableURL = URL(fileURLWithPath: command)
        self.process.arguments = arguments
        if let env = environment {
            self.process.environment = env
        }
        
        self.process.standardInput = inputPipe
        self.process.standardOutput = outputPipe
        self.process.standardError = errorPipe
    }
    
    public func connect() async throws {
        guard !isConnected else { return }
        
        try process.run()
        isConnected = true
        
        // Start reading output asynchronously
        Task {
            await readOutput()
        }
    }
    
    public func disconnect() async {
        guard isConnected else { return }
        
        process.terminate()
        isConnected = false
    }
    
    public func sendRequest(_ data: Data) async throws -> Data {
        guard isConnected else {
            throw MCPError.connectionClosed
        }
        
        // Write request
        try await withCheckedThrowingContinuation { continuation in
            processQueue.async {
                do {
                    let message = data + "\n".data(using: .utf8)!
                    try self.inputPipe.fileHandleForWriting.write(contentsOf: message)
                    
                    // Read response
                    if let response = try self.outputPipe.fileHandleForReading.readToEnd() {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(throwing: MCPError.invalidResponse)
                    }
                } catch {
                    continuation.resume(throwing: MCPError.transportError(error))
                }
            }
        }
    }
    
    public func sendNotification(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.connectionClosed
        }
        
        try await withCheckedThrowingContinuation { continuation in
            processQueue.async {
                do {
                    let message = data + "\n".data(using: .utf8)!
                    try self.inputPipe.fileHandleForWriting.write(contentsOf: message)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: MCPError.transportError(error))
                }
            }
        }
    }
    
    private func readOutput() async {
        let handle = outputPipe.fileHandleForReading
        
        while isConnected {
            do {
                let data = try handle.read(upToCount: 4096)
                if let data = data, !data.isEmpty {
                    // Process received data
                    // In a real implementation, you would parse the JSON-RPC messages
                    // and handle them appropriately
                    print("Received data: \(String(data: data, encoding: .utf8) ?? "")")
                }
            } catch {
                print("Error reading output: \(error)")
                break
            }
        }
    }
} 