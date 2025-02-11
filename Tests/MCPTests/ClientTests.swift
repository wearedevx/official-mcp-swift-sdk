import Testing

@testable import MCP

@Suite("Client Tests")
struct ClientTests {
    @Test("Client connect and disconnect")
    func testClientConnectAndDisconnect() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        #expect(await transport.isConnected == false)
        try await client.connect(transport: transport)
        #expect(await transport.isConnected == true)
        await client.disconnect()
        #expect(await transport.isConnected == false)
    }

    @Test(
        "Initialize request",
        .timeLimit(.minutes(1))
    )
    func testClientInitialize() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await client.connect(transport: transport)
        // Small delay to ensure message loop is started
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        // Create a task for initialize that we'll cancel
        let initTask = Task {
            try await client.initialize()
        }

        // Give it a moment to send the request
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        #expect(await transport.sentMessages.count == 1)
        #expect(await transport.sentMessages[0].contains(Initialize.name))
        #expect(await transport.sentMessages[0].contains(client.name))
        #expect(await transport.sentMessages[0].contains(client.version))

        // Cancel the initialize task
        initTask.cancel()

        // Disconnect client to clean up message loop and give time for continuation cleanup
        await client.disconnect()
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    }

    @Test(
        "Ping request",
        .timeLimit(.minutes(1))
    )
    func testClientPing() async throws {
        let transport = MockTransport()
        let client = Client(name: "TestClient", version: "1.0")

        try await client.connect(transport: transport)
        // Small delay to ensure message loop is started
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        // Create a task for the ping that we'll cancel
        let pingTask = Task {
            try await client.ping()
        }

        // Give it a moment to send the request
        try await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        #expect(await transport.sentMessages.count == 1)
        #expect(await transport.sentMessages[0].contains(Ping.name))

        // Cancel the ping task
        pingTask.cancel()

        // Disconnect client to clean up message loop and give time for continuation cleanup
        await client.disconnect()
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    }

    @Test("Connection failure handling")
    func testClientConnectionFailure() async {
        let transport = MockTransport()
        await transport.setFailConnect(true)
        let client = Client(name: "TestClient", version: "1.0")

        do {
            try await client.connect(transport: transport)
            #expect(Bool(false), "Expected connection to fail")
        } catch let error as Error {
            if case Error.transportError = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected transport error")
            }
        } catch {
            #expect(Bool(false), "Expected MCP.Error")
        }
    }

    @Test("Send failure handling")
    func testClientSendFailure() async throws {
        let transport = MockTransport()
        await transport.setFailSend(true)
        let client = Client(name: "TestClient", version: "1.0")

        try await client.connect(transport: transport)

        do {
            try await client.ping()
            #expect(Bool(false), "Expected ping to fail")
        } catch let error as Error {
            if case Error.transportError = error {
                #expect(Bool(true))
            } else {
                #expect(Bool(false), "Expected transport error")
            }
        } catch {
            #expect(Bool(false), "Expected MCP.Error")
        }
    }
}
