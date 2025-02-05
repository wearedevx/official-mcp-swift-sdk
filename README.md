# MCP Swift SDK

A Swift implementation of the Model Context Protocol (MCP) client. This SDK provides a modern, Swift-native way to interact with MCP servers.

## Features

- Full async/await support
- Type-safe API
- Resource management
- Tool integration
- Configurable transport layer
- Swift concurrency with actor-based design

## Requirements

- Swift 5.7+
- macOS 12.0+
- iOS 15.0+
- tvOS 15.0+
- watchOS 8.0+

## Installation

### Swift Package Manager

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/mcp-swift-sdk.git", from: "1.0.0")
]
```

## Usage

### Basic Setup

```swift
import MCP

// Create a transport (e.g., StdioTransport)
let transport = StdioTransport(command: "/path/to/server")

// Create client info
let clientInfo = Implementation(name: "MyApp", version: "1.0.0")

// Initialize the client
let client = MCPClient(transport: transport, clientInfo: clientInfo)

// Connect and initialize
try await client.connect()
let result = try await client.initialize()
```

### Working with Resources

```swift
// List available resources
let resources = try await client.listResources()

// Read a resource
let resource = try await client.readResource("resource://example")

// Subscribe to resource updates
try await client.subscribeResource("resource://example")

// Unsubscribe from resource updates
try await client.unsubscribeResource("resource://example")
```

### Working with Tools

```swift
// List available tools
let tools = try await client.listTools()

// Call a tool
let result = try await client.callTool(name: "example-tool", arguments: ["key": "value"])
```

### Custom Transport

You can create your own transport by implementing the `MCPTransport` protocol:

```swift
public protocol MCPTransport {
    func connect() async throws
    func disconnect() async
    func sendRequest(_ data: Data) async throws -> Data
    func sendNotification(_ data: Data) async throws
}
```

## Error Handling

The SDK uses the `MCPError` type for error handling:

```swift
public enum MCPError: LocalizedError {
    case connectionClosed
    case invalidResponse
    case invalidParams(String)
    case serverError(String)
    case protocolError(String)
    case transportError(Error)
}
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details. 