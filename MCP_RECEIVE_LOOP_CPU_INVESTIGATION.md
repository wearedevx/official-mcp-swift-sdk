# MCP Receive Loop CPU Investigation Handoff

Date: 2026-06-15

Repository: `wearedevx/official-mcp-swift-sdk`

Status: Investigation notes only. No SDK behavior was changed during this handoff.

## Summary

An app-side investigation reported 100% CPU usage caused by this SDK. The reported root cause is credible: `Client.listenForMessages()` can enter a tight loop when `connection.receive()` returns a stream that has already completed or completes normally without yielding more data.

The important protocol conclusion is that this outer infinite re-entry loop is not required by MCP 2025-03-26. The protocol requires clients and servers to exchange JSON-RPC messages over the active transport, and Streamable HTTP allows SSE streams to close. Reconnection/resumption, where applicable, is a transport-level behavior, not a generic client message-decoder behavior.

Any fix must preserve MCP conformance by keeping Streamable HTTP reconnection/resumption inside the HTTP transport layer and by preventing OAuth internal base-transport replacement from surfacing as a terminal EOF to `Client`.

## Main Finding

`Client.listenForMessages()` currently has two loops:

1. The inner `for try await data in stream` loop consumes messages from one `AsyncThrowingStream`.
2. The outer `repeat { ... } while true` loop immediately calls `connection.receive()` again after normal stream completion.

If a transport returns an already-finished stream, or if `receive()` exposes a stream that has just finished normally, the outer `repeat` can call `receive()` again immediately. That creates a busy loop and can explain the observed 100% CPU profile.

Relevant code:

- `Sources/MCP/Client/Client.swift:214`: `public func listenForMessages()`.
- `Sources/MCP/Client/Client.swift:218`: listener task starts.
- `Sources/MCP/Client/Client.swift:220`: `repeat {` begins.
- `Sources/MCP/Client/Client.swift:225`: `let stream = await connection.receive()`.
- `Sources/MCP/Client/Client.swift:226`: `for try await data in stream { ... }`.
- `Sources/MCP/Client/Client.swift:270`: `resourceTemporarilyUnavailable` retry sleeps and continues.
- `Sources/MCP/Client/Client.swift:279`: `} while true` causes immediate re-entry after normal stream completion.

## Why The Repeat Loop Was Likely Added

The outer `repeat` appears to be historical, not protocol-driven.

Git history shows the `repeat` loop already existed in the initial implementation:

- Commit: `be1e958 Initial implementation`.
- In that commit, `Client.connect(transport:)` started a message handling task with the same pattern: `repeat`, `connection.receive()`, `for try await`, retry on `Errno.resourceTemporarilyUnavailable`, `while true`.

Streamable HTTP support came later:

- `3e481fd wip: streamable http transport` renamed/reused the listener as `listenForMessages()` and added Streamable HTTP code.
- `096cc41 streamable http transport ?` made `connect()` call `listenForMessages()`.

This suggests the original intent was probably just "keep receiving messages forever" or "recover from temporary non-blocking read errors." In Swift, the `for try await` over the `AsyncThrowingStream` already is the message receive loop. Wrapping that in an unconditional outer loop conflates message iteration with stream lifetime/reconnection.

The only clearly intentional retry behavior in `Client.listenForMessages()` is the `resourceTemporarilyUnavailable` path, which sleeps briefly and continues. That behavior can be preserved without re-entering after normal stream completion.

## Protocol Conformance Notes

Reference: MCP 2025-03-26 transport and lifecycle specifications.

### Stdio

For stdio, messages are newline-delimited JSON-RPC objects on stdin/stdout. Shutdown is indicated by closing the underlying streams. If the server closes stdout or exits, the client's receive stream ending normally is a terminal transport condition. Re-entering `receive()` after EOF is not required by the spec.

### Streamable HTTP POST

For Streamable HTTP, every client-to-server JSON-RPC message is sent via HTTP POST. If the POST contains a request, the server can respond with either `application/json` or an SSE stream. If the server uses SSE for the POST response, the stream should eventually include one response per request and then should close after responses are sent.

This means a POST-associated SSE stream ending normally is expected behavior and should be handled by the HTTP transport. It is not a reason for the generic client listener to spin.

### Streamable HTTP GET

The client may issue a GET to open an SSE stream for server-to-client messages. The server may close that stream at any time, and the client may close it at any time. If the client wants to resume after a broken connection, it should issue another GET with `Last-Event-ID`.

This reconnection/resumption belongs in `StreamableHTTPTransport`. The transport already has a `startListeningForServerEvents()` loop and stores `lastEventID`. The generic `Client` should decode messages delivered by the transport; it should not implement blind stream recreation with no backoff and no knowledge of SSE event IDs.

### Disconnection And Pending Requests

The spec says disconnection may occur at any time and should not be interpreted as request cancellation. To cancel a request, a client should explicitly send `notifications/cancelled`.

Therefore, a fix should not automatically send cancellation notifications when the listener ends. It is acceptable for the local SDK to fail pending continuations with a transport-closed error if the receive channel terminates unexpectedly, because otherwise callers can hang indefinitely. The SDK should also support/request timeouts separately, as recommended by the lifecycle spec.

## OAuth Transport Issue

The OAuth transport has a related bug and must be fixed together with the client loop.

Current behavior:

- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:341`: `currentStream` caches an `AsyncThrowingStream<Data, Error>`.
- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:344`: `receive()` returns the cached `currentStream` if present.
- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:349`: otherwise it creates a wrapper stream.
- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:353`: the wrapper forwards data from `await baseTransport.receive()`.
- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:356`: the wrapper finishes normally when the base stream finishes.
- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:358`: the wrapper finishes throwing if the base stream throws.

The problem is that `currentStream` is not cleared when that wrapper finishes or throws. Once the wrapper has finished, later `receive()` calls can return the same already-finished stream.

There is a second OAuth-specific lifecycle problem:

- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:697`: `updateTransportWithToken(_:)` disconnects the old `baseTransport`.
- `HTTPClientTransport.disconnect()` and `StreamableHTTPTransport.disconnect()` finish their message continuations.
- If `OAuthHTTPClientTransport.receive()` is actively forwarding the old base transport, this internal disconnect can finish the OAuth wrapper stream.
- That EOF is not necessarily a real OAuth transport disconnect. It can be an internal token/auth transport replacement.

If the client fix treats normal receive-stream completion as terminal, OAuth must not expose internal base-transport replacement as normal terminal completion.

`OAuthHTTPClientTransport.disconnect()` also currently disconnects the base transport but does not set its own `isConnected = false` or clear `currentStream`. That should be corrected.

Relevant code:

- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:39`: `private var isConnected = false`.
- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:310`: `public func disconnect() async`.
- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:314`: disconnects base transport only.
- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:341`: cached `currentStream`.
- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:697`: token update disconnects old base transport.
- `Sources/MCP/Base/OAuth/OAuthHTTPClientTransport.swift:705`: reconnects new base only if `isConnected`.

## Other Transport Evidence

Several transports finish their message stream on disconnect or EOF. This is normal transport behavior, but it makes the client outer `repeat` dangerous if `receive()` is called after the stream is terminal.

Relevant code:

- `Sources/MCP/Base/Transports/HTTPClientTransport.swift:128`: `disconnect()`.
- `Sources/MCP/Base/Transports/HTTPClientTransport.swift:141`: `messageContinuation.finish()`.
- `Sources/MCP/Base/Transports/HTTPClientTransport.swift:231`: `receive()` returns `messageStream`.
- `Sources/MCP/Base/Transports/StreamableHTTPTransport.swift:132`: `disconnect()`.
- `Sources/MCP/Base/Transports/StreamableHTTPTransport.swift:133`: `messageContinuation.finish()`.
- `Sources/MCP/Base/Transports/StreamableHTTPTransport.swift:269`: `receive()` returns `messageStream`.
- `Sources/MCP/Base/Transports/StdioTransport.swift:130`: read loop finishes message continuation.
- `Sources/MCP/Base/Transports/StdioTransport.swift:136`: disconnect finishes message continuation.
- `Sources/MCP/Base/Transports/StdioTransport.swift:179`: `receive()` wraps `messageStream`.
- `Sources/MCP/Base/Transports/NetworkTransport.swift:146`: disconnect finishes message continuation.
- `Sources/MCP/Base/Transports/NetworkTransport.swift:188`: `receive()` wraps `messageStream`.

## Recommended Fix Shape

### Client.listenForMessages()

Preserve the `resourceTemporarilyUnavailable` retry path, but do not re-enter `receive()` after normal stream completion.

Recommended shape:

```swift
public func listenForMessages() {
    guard task == nil else { return }

    task = Task {
        defer {
            Task { await self.listenerDidTerminate() }
        }

        guard let connection = self.connection else { return }

        while !Task.isCancelled {
            do {
                let stream = await connection.receive()

                for try await data in stream {
                    if Task.isCancelled { break }
                    // Existing decode and dispatch logic stays here.
                }

                break
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                try? await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                await logger?.error(
                    "Error in message handling loop",
                    metadata: ["error": "\(error)"]
                )
                break
            }
        }
    }
}
```

The exact implementation should respect actor isolation. A small isolated helper such as `listenerDidTerminate()` can clear `task` and fail pending requests.

Recommended client cleanup behavior:

- Clear `task` when the listener exits so future `listenForMessages()` calls are not blocked forever by a completed task.
- If the listener terminates while there are pending requests and the client is not intentionally disconnecting, resume those pending requests with a transport-closed/internal error.
- Do not automatically send `notifications/cancelled` for those requests. Local continuation failure is not protocol cancellation.
- Keep explicit `disconnect()` behavior as the intentional shutdown path.

Potential helper:

```swift
private func failPendingRequests(_ error: Swift.Error) {
    for (id, request) in pendingRequests {
        request.resume(throwing: error)
        pendingRequests.removeValue(forKey: id)
    }
}
```

Be careful not to double-resume requests if `disconnect()` races with listener termination. The existing `AnyPendingRequest` wrapper guards against double-resume at the individual continuation level, but dictionary mutation should still be serialized on the actor.

### OAuthHTTPClientTransport.receive()

Recommended properties:

- Clear `currentStream` when the wrapper stream terminates or throws.
- Mark explicit disconnect with a dedicated flag or by setting `isConnected = false`.
- Do not let internal base-transport replacement during token update expose terminal EOF to `Client`.

Possible approaches:

1. Track `isDisconnected` or `isConnected` and only finish the OAuth wrapper when the OAuth transport itself is explicitly disconnected.
2. When the base transport finishes because it was internally replaced, restart forwarding from the new base transport inside `OAuthHTTPClientTransport.receive()` instead of finishing the wrapper.
3. Use a generation counter for base transports. Increment the generation before replacement. The receive-forwarding task can compare generations and decide whether base EOF is terminal or just an internal replacement.

The minimal safe approach is likely a generation/disconnect flag:

- Add `private var isDisconnected = false`.
- Set `isConnected = true` and `isDisconnected = false` on successful `connect()`.
- Set `isConnected = false`, `isDisconnected = true`, and `currentStream = nil` on explicit `disconnect()`.
- Increment a `baseTransportGeneration` before replacing base transport.
- In the receive wrapper, if the observed generation has changed and the OAuth transport was not disconnected, continue forwarding from the new base transport instead of finishing.

Do not implement backwards-compatibility code unless tests or concrete behavior require it.

## Suggested Tests

### Client Tests

Add a mock transport whose `receive()` returns an immediately finished stream and increments a counter each time it is called.

Test expectations:

- `Client.listenForMessages()` or `client.connect()` should call `receive()` once.
- After a short delay, `receive()` count should still be `1`, not thousands.
- The client listener should not consume CPU.
- A later `listenForMessages()` call after task cleanup should be possible if the transport is still valid.

Add a pending-request test if feasible:

- Transport accepts `send`, then its receive stream ends before a response arrives.
- The SDK should resume the pending request with an error instead of hanging indefinitely.
- Do not expect a cancellation notification to be sent.

### OAuth Tests

Add or extend OAuth transport coverage for token/auth replacement:

- Start a receive stream before a send triggers OAuth discovery/token update.
- Make token update replace/disconnect the old base transport.
- Ensure the OAuth wrapper does not complete merely because of that internal replacement.
- Ensure the retried authenticated request still delivers the JSON-RPC response to the client.

Existing relevant test file:

- `Tests/MCPTests/OAuthHTTPClientTransportTests.swift`.

Existing relevant tests include:

- `Initialize Before Connect Flow`.
- `Dynamic discovery resolves redirect URI only when interactive auth begins`.
- `Dynamic registration resolves redirect URI once per auth session`.

### Focused Validation Commands

Use focused tests first:

```sh
swift test --filter ClientTests
swift test --filter OAuthHTTPClientTransportTests
```

If validating against the app checkout mentioned in the original report, run the app's focused MCP tests after updating its package resolution:

```sh
xcodebuild -quiet -scheme Alter -destination 'platform=macOS,arch=arm64' -destination-timeout 1 -configuration Debug test -only-testing:AlterTests/MCPToolListingPageGuardTests -only-testing:AlterTests/MCPClientRemoteConfigurationTests
```

## Risks

The main risk is breaking OAuth initialization or token refresh by treating an internal OAuth base-transport EOF as a real client transport EOF. Fix OAuth stream lifecycle in the same patch as the client loop.

A second risk is hanging pending requests if the listener exits but pending continuations are not failed. The current SDK has no obvious per-request timeout implementation in `Client`, although the MCP lifecycle spec recommends request timeouts. Failing pending requests on unexpected listener termination is safer than silently hanging.

A third risk is moving reconnection responsibility to the wrong layer. Streamable HTTP GET SSE reconnect/resume should stay inside `StreamableHTTPTransport`, where `lastEventID`, session ID, and SSE retry behavior are available.

## Follow-Up Action Checklist

1. Patch `Client.listenForMessages()` to stop re-entering `receive()` after normal stream completion.
2. Add listener termination cleanup so `task` is cleared when the listener task exits.
3. Fail pending requests on unexpected listener termination without sending protocol cancellation notifications.
4. Keep the `resourceTemporarilyUnavailable` retry path with a short sleep/backoff.
5. Patch `OAuthHTTPClientTransport.receive()` so it clears `currentStream` on terminal finish/throw.
6. Patch `OAuthHTTPClientTransport.disconnect()` to mark the OAuth transport disconnected and clear cached stream state.
7. Ensure OAuth base-transport replacement during authentication/token refresh does not expose terminal EOF to `Client`.
8. Add focused client tests for an immediately finished receive stream and pending request failure on listener termination.
9. Add or extend OAuth tests for auth/token transport replacement while a receive stream is active.
10. Run `swift test --filter ClientTests` and `swift test --filter OAuthHTTPClientTransportTests`.
11. If this SDK is consumed by Alter, commit the SDK fix and update Alter's `Package.resolved` to the new SDK revision.

## Notes About Local Git State

`git status --short` emitted only this Git alternate-object warning in this checkout:

```text
error: unable to normalize alternate object path: /Users/gaelphilippe/Library/Developer/Xcode/DerivedData/Alter-crcseqesvultfnbhtyulwfibckaq/SourcePackages/repositories/official-mcp-swift-sdk-d90684f6/objects
```

The referenced app-side commit `e80096ef1` was not present in this SDK checkout when checked with `git show e80096ef1`.
