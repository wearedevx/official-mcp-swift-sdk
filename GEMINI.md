# GEMINI.md

## Project Overview

This project is a Swift SDK for the Model Context Protocol (MCP). It provides a client and server implementation for MCP, allowing developers to build applications that can communicate with each other using this protocol.

The SDK is built using Swift and has dependencies on `swift-system` and `swift-log`. It supports various platforms, including macOS, iOS, watchOS, tvOS, visionOS, Linux, and Windows.

The architecture is based on a client-server model, with a transport layer that handles the communication between them. The SDK provides two transport implementations:

*   **`StdioTransport`**: For communication over standard input/output.
*   **`HTTPClientTransport`**: For communication over HTTP, with support for Server-Sent Events (SSE) for real-time updates.

## Building and Running

### Building

To build the project, you can use the Swift Package Manager. From the root of the project, run the following command:

```bash
swift build
```

### Testing

To run the tests, use the following command:

```bash
swift test
```

## Development Conventions

The project follows standard Swift coding conventions. The code is well-structured and organized into modules for the client, server, and base components.

The SDK makes extensive use of Swift's concurrency features, including `async/await` and actors, to handle asynchronous operations and ensure thread safety.

The project has a comprehensive test suite that covers the core functionality of the SDK, including the client, server, and transport layers.
