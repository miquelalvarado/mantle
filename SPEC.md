# Mantle — Technical Specification

## What is Mantle?

Mantle is a macOS 14+ Menu Bar utility that acts as a local HTTP reverse-proxy. It accepts
OpenAI-formatted chat completion requests (the kind Xcode's built-in AI Coding Agent sends)
and translates them in real time to AWS Bedrock `converseStream` API calls, streaming responses
back as Server-Sent Events (SSE) in OpenAI format.

The app lives exclusively in the menu bar (no Dock icon, no main window). All configuration is
done via a standard macOS Settings scene.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Xcode AI Agent                       │
│     POST http://127.0.0.1:8080/v1/chat/completions       │
└────────────────────────┬────────────────────────────────┘
                         │ HTTP/1.1 (OpenAI SSE)
                         ▼
┌─────────────────────────────────────────────────────────┐
│              ProxyServer (actor)                         │
│         Hummingbird v2 Application on 127.0.0.1          │
│  ┌───────────────┐    ┌──────────────────────────────┐  │
│  │ ModelsHandler │    │       ChatHandler             │  │
│  │GET /v1/models │    │POST /v1/chat/completions       │  │
│  └───────────────┘    └──────────────┬───────────────┘  │
└─────────────────────────────────────┼───────────────────┘
                         │ ConverseStreamInput
                         ▼
┌─────────────────────────────────────────────────────────┐
│             BedrockService (actor)                       │
│   ProfileAWSCredentialIdentityResolver + region config   │
│   BedrockRuntimeClient → AWS Bedrock                     │
└─────────────────────────────────────┬───────────────────┘
                         │ event stream
                         ▼
┌─────────────────────────────────────────────────────────┐
│            StreamMapper (struct)                         │
│  Bedrock events → OpenAI SSE ByteBuffers                 │
│  keep-alive timer (15 s `: keep-alive\n\n`)              │
└─────────────────────────────────────────────────────────┘

State & UI
┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐
│SettingsStore │  │  LogStore    │  │  MantleApp            │
│ @AppStorage  │  │  (actor,     │  │  MenuBarExtra + Scene │
│ region/port/ │  │  ring[200])  │  │  Settings {}          │
│ profile/model│  └──────────────┘  └──────────────────────┘
└──────────────┘
```

---

## Technology Stack

| Concern | Technology | SPM Product |
|---|---|---|
| UI | SwiftUI + MenuBarExtra (macOS 14+) | built-in |
| HTTP Server | Hummingbird 2.x | `Hummingbird` |
| AWS | aws-sdk-swift 1.x | `AWSBedrockRuntime` |
| Concurrency | Swift 6 strict concurrency | built-in |
| Persistence | UserDefaults via `@AppStorage` | built-in |

### SPM Dependencies

```
https://github.com/hummingbird-project/hummingbird  — up to next major from 2.25.0
https://github.com/awslabs/aws-sdk-swift            — up to next major from 1.0.0
```

Products to link: `Hummingbird`, `AWSBedrockRuntime`.

`AWSSDKIdentity` (which contains `ProfileAWSCredentialIdentityResolver`) is a transitive
dependency of `AWSBedrockRuntime` — no explicit product entry needed.

---

## Key Design Decisions

| Decision | Choice |
|---|---|
| Model routing | Incoming `model` field is **ignored**; always routes to Settings `defaultModelId` |
| Tool/function calling | Return `501 Not Implemented` if `tools` field is present (v1 scope) |
| Binding address | `127.0.0.1` only (not `0.0.0.0`) |
| Credential provider | `ProfileAWSCredentialIdentityResolver`; client recreated when region/profile changes |
| App Sandbox | Disabled; entitlements: `network.client=true`, `network.server=true` |
| Streaming | SSE-only; non-streaming not supported (Xcode always streams) |
| Dock icon | `LSUIElement=YES` in `Info.plist` |

---

## Critical Edge Cases

1. **System message extraction** — OpenAI sends `role:"system"` inside `messages[]`. Bedrock
   takes system content via a separate `system` parameter. Must filter and remap.

2. **Message alternation** — Bedrock requires strict user/assistant alternation starting with
   user. Merge consecutive same-role messages by concatenating content with `"\n"`.

3. **Bedrock stream event mapping**:
   - `.contentBlockDelta` + `.text(t)` → emit content SSE chunk
   - `.metadata` → capture `inputTokens`/`outputTokens` for the final chunk's `usage` field
   - `.messageStop` → map `stopReason`, emit final chunk + `data: [DONE]\n\n`
   - Stop reason: `end_turn`/nil → `"stop"`, `max_tokens` → `"length"`, `stop_sequence` → `"stop"`

4. **SSE keep-alive** — emit `: keep-alive\n\n` every 15 s if no data, to prevent Xcode timeout.

5. **Port conflict** — catch `EADDRINUSE` on server bind; surface human-readable error in menu bar.

6. **Stream error mid-flight** — if Bedrock throws after SSE has started (200 already sent), emit
   `data: {"error":{...}}\n\n` then `data: [DONE]\n\n`. Never call `finish(throwing:)` mid-stream.

7. **AWS client recreation** — `ensureClient(region:profile:)` compares stored values; recreates
   `BedrockRuntimeClient` only when they change.

8. **Content field format** — OpenAI `content` can be a plain `String` or
   `[{"type":"text","text":"..."}]`. Custom `Codable` enum handles both.

9. **First SSE chunk** — must yield `delta:{role:"assistant",content:""}` as the very first chunk
   so clients initialise their streaming state correctly.

---

## File Structure

```
Mantle/
├── Mantle.xcodeproj
├── SPEC.md
└── Mantle/
    ├── App/
    │   └── MantleApp.swift
    ├── Server/
    │   ├── ProxyServer.swift
    │   ├── ModelsHandler.swift
    │   └── ChatHandler.swift
    ├── Bedrock/
    │   ├── BedrockService.swift
    │   └── StreamMapper.swift
    ├── Models/
    │   ├── OpenAITypes.swift
    │   ├── HardcodedModels.swift
    │   └── OpenAIToBedrockMapper.swift
    ├── Store/
    │   ├── SettingsStore.swift
    │   └── LogStore.swift
    ├── Views/
    │   ├── MenuBarView.swift
    │   ├── SettingsView.swift
    │   └── LogConsoleView.swift
    ├── Assets.xcassets
    ├── Info.plist
    └── Mantle.entitlements
```

---

## Component Specifications

### SettingsStore

```swift
@MainActor final class SettingsStore: ObservableObject {
    @AppStorage("awsRegion")      var region:       String = "us-east-1"
    @AppStorage("awsProfile")     var profile:      String = "default"
    @AppStorage("localPort")      var port:         Int    = 8080
    @AppStorage("defaultModelId") var defaultModel: String =
        "anthropic.claude-3-5-sonnet-20241022-v2:0"
}
```

### LogStore

```swift
actor LogStore {
    static let shared = LogStore()
    private(set) var entries: [LogEntry] = []     // ring buffer, cap 200
    func append(_ entry: LogEntry)
    func clear()
}

struct LogEntry: Identifiable, Sendable {
    let id    = UUID()
    let date  : Date
    let level : LogLevel
    let text  : String
}

enum LogLevel: String, Sendable { case info, warn, error }
```

### OpenAITypes (all `Codable + Sendable`)

- `OpenAIChatRequest` — model, messages, stream?, maxTokens?, temperature?, topP?, tools?
- `OpenAIMessage` — role, content: `OpenAIContent`
- `OpenAIContent` — enum `.text(String)` / `.blocks([OpenAIContentBlock])` with custom `Codable`
  (`init(from:)` tries `String` first, falls back to `[OpenAIContentBlock]`)
- `OpenAIContentBlock` — type, text?
- `OpenAIChunk` — id, object, created, model, choices, usage?
- `OpenAIChoice` — index, delta, finish_reason (snake_case CodingKey)
- `OpenAIDelta` — role?, content?
- `OpenAIUsage` — prompt_tokens, completion_tokens, total_tokens (snake_case CodingKeys)
- `OpenAIErrorResponse` / `OpenAIError` — message, type, code?

### HardcodedModels

Six entries in `HardcodedModels.all: [OpenAIModel]`:
- `anthropic.claude-3-5-sonnet-20241022-v2:0`
- `anthropic.claude-3-5-haiku-20241022-v1:0`
- `anthropic.claude-3-haiku-20240307-v1:0`
- `anthropic.claude-3-opus-20240229-v1:0`
- `amazon.nova-pro-v1:0`
- `amazon.nova-lite-v1:0`

### OpenAIToBedrockMapper

```swift
struct OpenAIToBedrockMapper {
    // Splits OpenAI messages → Bedrock system blocks + conversation messages.
    // Validates/coerces strict user/assistant alternation.
    static func map(_ messages: [OpenAIMessage]) throws
        -> (system: [SystemContentBlock], messages: [BedrockMessage])

    // Resolves String or [ContentBlock] → plain concatenated String
    static func extractText(from content: OpenAIContent) -> String

    // end_turn/nil → "stop", max_tokens → "length", stop_sequence → "stop"
    static func finishReason(from stopReason: StopReason?) -> String
}
```

`map(_:)` logic:
1. Separate `role=="system"` → `SystemContentBlock.text`
2. Convert remaining: `"user"` → `.user`, `"assistant"` → `.model`
3. Merge consecutive same-role messages (concatenate text with `"\n"`)
4. Throw `MappingError.mustStartWithUser` if first message is not `.user`

### BedrockService

```swift
actor BedrockService {
    private var client        : BedrockRuntimeClient?
    private var currentRegion : String = ""
    private var currentProfile: String = ""

    func ensureClient(region: String, profile: String) throws
    func stream(input: ConverseStreamInput)
        async throws -> AsyncThrowingStream<ConverseStreamOutput, Error>
}
```

`ensureClient`: if region/profile changed or client is nil, build
`ProfileAWSCredentialIdentityResolver(profileName: profile == "default" ? nil : profile)`,
then `BedrockRuntimeClientConfig(awsCredentialIdentityResolver:region:)`,
then `BedrockRuntimeClient(config:)`.

`stream`: unwrap `output.stream` (throw `BedrockError.noStream` if nil); bridge to
`AsyncThrowingStream`.

### StreamMapper

```swift
struct StreamMapper {
    let completionId : String   // "chatcmpl-{UUID}"
    let created      : Int      // Unix timestamp at request time
    let modelId      : String

    func makeSSESequence(
        bedrockEvents     : some AsyncSequence<ConverseStreamOutput, Error>,
        keepAliveInterval : Duration = .seconds(15)
    ) -> AsyncThrowingStream<ByteBuffer, Error>
}
```

`makeSSESequence` internal flow:
1. Yield the **role-announcement chunk** immediately (before iterating Bedrock events).
2. Accumulate `promptTokens` / `completionTokens` from `.metadata` events.
3. On `.contentBlockDelta` + `.text(t)`: yield content chunk `ByteBuffer`.
4. On `.messageStop`: yield final chunk (with accumulated usage) + `data: [DONE]\n\n`, finish.
5. Keep-alive `Task`: every 1 s, if `Date().timeIntervalSince(lastYield) >= interval`, yield
   `: keep-alive\n\n`. Cancel this task when the main loop finishes.
6. On error mid-flight: yield error SSE chunk + `data: [DONE]\n\n`, call `continuation.finish()`
   (never `finish(throwing:)` after SSE headers are sent).

Helper:
```swift
private func sseData(_ value: some Encodable) throws -> ByteBuffer {
    let json = try JSONEncoder().encode(value)
    var buf  = ByteBuffer()
    buf.writeString("data: \(String(decoding: json, as: UTF8.self))\n\n")
    return buf
}
```

### ProxyServer

```swift
actor ProxyServer {
    private var runningTask: Task<Void, Error>?
    var isRunning: Bool { runningTask != nil }

    func start() async throws   // throws ProxyError.portInUse(Int) on EADDRINUSE
    func stop()
}
```

`start()`: build `Router`, register handlers, create `Application` bound to
`127.0.0.1:\(port)`, store running `Task { try await app.runService() }`.
Catch NIO bind error → rethrow as `ProxyError.portInUse(port)`.

`stop()`: cancel `runningTask`, set to `nil`.

### ServerManager (`@MainActor` SwiftUI bridge)

```swift
@MainActor final class ServerManager: ObservableObject {
    @Published var isRunning     : Bool   = false
    @Published var statusMessage : String = "Stopped"
    var iconName: String { isRunning ? "circle.fill" : "circle" }

    func toggle() async
}
```

`toggle()` error handling:
- `ProxyError.portInUse(let p)` → `statusMessage = "Error: port \(p) in use"`
- Other → `statusMessage = "Error: \(error.localizedDescription)"`

---

## SSE Wire Format

```
// First chunk — role announcement
data: {"id":"chatcmpl-X","object":"chat.completion.chunk","created":T,
       "model":"M","choices":[{"index":0,"delta":{"role":"assistant","content":""},
       "finish_reason":null}]}\n\n

// Content chunk
data: {"id":"chatcmpl-X","object":"chat.completion.chunk","created":T,
       "model":"M","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}\n\n

// Final chunk (with usage)
data: {"id":"chatcmpl-X","object":"chat.completion.chunk","created":T,
       "model":"M","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],
       "usage":{"prompt_tokens":N,"completion_tokens":M,"total_tokens":T}}\n\n

// Terminator
data: [DONE]\n\n

// Keep-alive comment (emitted every 15 s of silence)
: keep-alive\n\n
```

SSE response headers:
```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```

---

## Entitlements (`Mantle.entitlements`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
```

---

## Implementation Checklist

### Phase 0 — Xcode Project Scaffolding

- [ ] **0.1** Create new Xcode project: macOS → App. Bundle ID `com.yourname.Mantle`.
  Deployment target macOS 14.0. Language Swift. Interface SwiftUI.
- [ ] **0.2** In Signing & Capabilities, remove the App Sandbox capability entirely.
- [ ] **0.3** Create `Mantle/Mantle.entitlements` with the three keys above.
  Set it as Code Signing Entitlements in Build Settings (`CODE_SIGN_ENTITLEMENTS`).
- [ ] **0.4** In `Info.plist`, add key `LSUIElement` (Application is agent) = `YES` (Boolean).
  This suppresses the Dock icon.
- [ ] **0.5** Add SPM packages via File → Add Package Dependencies:
  - `https://github.com/hummingbird-project/hummingbird` — up to next major from `2.25.0` → add product `Hummingbird`
  - `https://github.com/awslabs/aws-sdk-swift` — up to next major from `1.0.0` → add product `AWSBedrockRuntime`
- [ ] **0.6** In Build Settings set `SWIFT_STRICT_CONCURRENCY = complete`.
- [ ] **0.7** Create source groups in Xcode: `App/`, `Server/`, `Bedrock/`, `Models/`, `Store/`, `Views/`.
- [ ] **0.8** Stub `MantleApp.swift`:
  ```swift
  @main struct MantleApp: App {
      var body: some Scene {
          MenuBarExtra("Mantle", systemImage: "circle") { Text("Hello") }
          Settings { EmptyView() }
      }
  }
  ```
  Build and run — confirm menu bar icon appears, no Dock icon.

**Verify**: App in menu bar. No Dock icon. No sandbox errors in Console.app.

---

### Phase 1 — Settings & Log Infrastructure

- [ ] **1.1** Create `Store/SettingsStore.swift` per the specification above.
- [ ] **1.2** Create `Store/LogStore.swift`: actor with ring buffer (cap 200), `LogEntry` struct,
  `LogLevel` enum. Include `append(_:)` and `clear()` methods.
- [ ] **1.3** Create `Views/SettingsView.swift` — `TabView` with General and Log tabs.
  General tab uses `Form` with `TextField` for region, profile, default model; integer
  `TextField` with `NumberFormatter` for port.
- [ ] **1.4** Create `Views/LogConsoleView.swift` — `ScrollView` + `LazyVStack` of monospaced
  `Text` entries. Auto-scroll to bottom on new entry. Include a "Clear" button.
- [ ] **1.5** Create `LogStoreBridge: ObservableObject` (`@MainActor`) that polls `LogStore.shared`
  every 0.5 s inside a background `Task`, publishing to `@Published var entries: [LogEntry]`.
  Wire `LogConsoleView` to use `@StateObject private var bridge = LogStoreBridge()`.
- [ ] **1.6** Update `MantleApp.swift`: add `@StateObject var settings = SettingsStore()`.
  Pass to `SettingsView` via `.environmentObject(settings)`.

**Verify**: Cmd+, opens Settings. Change region, quit, relaunch → value persisted. Log tab
renders with monospaced font. "Clear" empties the list.

---

### Phase 2 — OpenAI Types & Bedrock Mapper

- [ ] **2.1** Create `Models/OpenAITypes.swift`. All types `Codable + Sendable`.
  `OpenAIContent.init(from:)`: try decoding as `String` first, fall back to `[OpenAIContentBlock]`.
- [ ] **2.2** Create `Models/HardcodedModels.swift`. `OpenAIModel` uses `owned_by` CodingKey.
  Populate `HardcodedModels.all` with the six model IDs listed above.
- [ ] **2.3** Create `Models/OpenAIToBedrockMapper.swift` with the three static methods specified.
  `map(_:)`: separate system messages, convert roles, merge consecutive same-role, validate order.
- [ ] **2.4** Write XCTest unit tests covering:
  - System message → appears in `systemBlocks`, not in `messages`
  - Two consecutive user messages → merged into one message
  - Messages starting with assistant role → throws `MappingError.mustStartWithUser`
  - `OpenAIContent` plain string `"hello"` and `[{"type":"text","text":"hello"}]` → both
    return `"hello"` from `extractText`

**Verify**: All unit tests pass (`Cmd+U` in Xcode).

---

### Phase 3 — Bedrock Service & Stream Mapper

- [ ] **3.1** Create `Bedrock/BedrockService.swift` with actor, `ensureClient`, and `stream`
  methods as specified. Handle `profile == "default"` by passing `nil` to
  `ProfileAWSCredentialIdentityResolver`.
- [ ] **3.2** Create `Bedrock/StreamMapper.swift`. Implement `makeSSESequence` with:
  - Role-announcement first yield
  - Full Bedrock event switch (contentBlockDelta, metadata, messageStop, default)
  - Keep-alive background `Task`
  - Mid-flight error catch → error SSE + `[DONE]` + `continuation.finish()`
  - `sseData(_:)` helper
- [ ] **3.3** Write a small command-line Swift script (outside the app target, not committed) that
  instantiates `BedrockService`, calls `ensureClient("us-east-1", "default")`, builds a minimal
  `ConverseStreamInput` with one user message ("Say hello in one word"), iterates the stream,
  and prints each event type to stdout.

**Verify**: Script prints `contentBlockDelta` text events and a `messageStop` event using
real AWS credentials.

---

### Phase 4 — HTTP Server & Handlers

- [ ] **4.1** Create `Server/ModelsHandler.swift`. Register `GET /v1/models` on the router.
  Return JSON-encoded `OpenAIModelList(object: "list", data: HardcodedModels.all)` with
  `Content-Type: application/json`.

- [ ] **4.2** Create `Server/ChatHandler.swift`:
  1. Collect body up to 1 MB: `request.body.collect(upTo: 1_048_576)`
  2. Decode `OpenAIChatRequest`
  3. Guard `request.tools == nil` else return `Response(status: .notImplemented, ...)` with
     `OpenAIErrorResponse(error: .init(message: "Tool use not supported", type: "not_implemented", code: "tools_not_supported"))`
  4. Call `OpenAIToBedrockMapper.map(request.messages)` — on error return 400
  5. Build `ConverseStreamInput` using `settings.defaultModel` (ignore `request.model`)
  6. `await bedrock.ensureClient(region: settings.region, profile: settings.profile)`
  7. Get event stream from `bedrock.stream(input:)`
  8. Create `StreamMapper(completionId: "chatcmpl-\(UUID())", created: Int(Date().timeIntervalSince1970), modelId: settings.defaultModel)`
  9. `return Response(status: .ok, headers: sseHeaders, body: .init(asyncSequence: mapper.makeSSESequence(bedrockEvents: stream)))`
  10. Log `[INFO] POST /v1/chat/completions → \(settings.defaultModel)` to `LogStore.shared`

- [ ] **4.3** Create `Server/ProxyServer.swift`. Actor wrapping a `Task` that runs
  `app.runService()`. Catch NIO `EADDRINUSE` → throw `ProxyError.portInUse(port)`.

- [ ] **4.4** Create `ServerManager` (`@MainActor ObservableObject`). Wrap `ProxyServer`.
  Expose `isRunning`, `statusMessage`, `iconName`, `toggle() async`.

**Verify (curl)**:
```bash
# Model list
curl http://127.0.0.1:8080/v1/models

# SSE stream (press Ctrl+C after [DONE])
curl -N -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"Say hello"}],"stream":true}'

# 501 for tools
curl -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}],"tools":[]}'
```

---

### Phase 5 — Menu Bar UI

- [ ] **5.1** Create `Views/MenuBarView.swift`:
  ```
  [status text — disabled label]
  Divider
  [Start Server / Stop Server button]
  Divider
  [Settings... button]
  Divider
  [Quit Mantle button]
  ```
  Start/Stop wraps in `Task { await serverMgr.toggle() }`.
  Settings uses `NSApp.sendAction(Selector("showSettingsWindow:"), to: nil, from: nil)`.

- [ ] **5.2** Update `MantleApp.swift` to final form:
  ```swift
  @main struct MantleApp: App {
      @StateObject private var settings  = SettingsStore()
      @StateObject private var serverMgr = ServerManager()

      var body: some Scene {
          MenuBarExtra("Mantle", systemImage: serverMgr.iconName) {
              MenuBarView()
                  .environmentObject(settings)
                  .environmentObject(serverMgr)
          }
          Settings {
              SettingsView()
                  .environmentObject(settings)
          }
      }
  }
  ```

- [ ] **5.3** Status text in `MenuBarView`:
  - Running: `"Running on port \(settings.port)"`
  - Stopped: `"Stopped"`
  - Error: `serverMgr.statusMessage` (already includes "Error: ..." prefix)

**Verify**: Start → `circle.fill` icon. Stop → `circle` icon. Curl works while running.
Change port to 8081, restart → binds on 8081. Start with occupied port → error in menu.

---

### Phase 6 — Edge Case Hardening

- [ ] **6.1** Unit test: input with `role:"system"` message → `systemBlocks` non-empty,
  `messages` array has no system entry.
- [ ] **6.2** Unit test: two consecutive `role:"user"` messages → merged into one Bedrock message.
- [ ] **6.3** Unit test `StreamMapper` with a mock `AsyncThrowingStream` of canned Bedrock events
  (one `contentBlockDelta`, one `metadata`, one `messageStop`); decode emitted `ByteBuffer`s and
  assert correct SSE JSON including `usage` fields in the final chunk.
- [ ] **6.4** Unit test keep-alive: mock stream with a 20 s delay before first event; assert
  `: keep-alive\n\n` ByteBuffer is emitted within 15 s.
- [ ] **6.5** Unit test port conflict: verify `ProxyServer` translates NIO bind error to
  `ProxyError.portInUse` and `ServerManager` sets `statusMessage` accordingly.
- [ ] **6.6** Unit test mid-flight error: mock stream throws after 2 events; assert error SSE
  chunk and `[DONE]` are yielded, and `continuation.finish()` (not `finish(throwing:)`) is called.
- [ ] **6.7** Unit test client recreation: call `ensureClient` with region A, then region B;
  assert client object identity changes on the second call.

---

### Phase 7 — Polish

- [ ] **7.1** Add a template menu bar icon (18×18pt SVG, solid black) to `Assets.xcassets`.
  Use `Image("MenuBarIcon")` as the `MenuBarExtra` label if available; keep `circle.fill` fallback.
- [ ] **7.2** Log token usage after stream completes. Pass an `onUsage: (Int, Int) -> Void`
  callback from `ChatHandler` into `StreamMapper`; call it when final chunk is assembled.
  `ChatHandler` logs `[INFO] tokens prompt=N completion=M` to `LogStore`.
- [ ] **7.3** Set `CFBundleName = Mantle`, `CFBundleShortVersionString = 1.0.0`,
  `CFBundleVersion = 1` in `Info.plist`.
- [ ] **7.4** Full end-to-end integration test:
  1. Start Mantle.
  2. In Xcode Settings → AI → set model endpoint to `http://127.0.0.1:8080/v1`.
  3. Set model name to anything (it is ignored by Mantle).
  4. Open a Swift file in Xcode, invoke the AI coding assistant.
  5. Verify the response streams in correctly and Mantle's log console shows the request.

---

## Files Created by Phase

| File | Phase |
|---|---|
| `Mantle/Mantle.entitlements` | 0 |
| `Mantle/App/MantleApp.swift` | 0 → updated in 5 |
| `Mantle/Store/SettingsStore.swift` | 1 |
| `Mantle/Store/LogStore.swift` | 1 |
| `Mantle/Views/SettingsView.swift` | 1 |
| `Mantle/Views/LogConsoleView.swift` | 1 |
| `Mantle/Models/OpenAITypes.swift` | 2 |
| `Mantle/Models/HardcodedModels.swift` | 2 |
| `Mantle/Models/OpenAIToBedrockMapper.swift` | 2 |
| `Mantle/Bedrock/BedrockService.swift` | 3 |
| `Mantle/Bedrock/StreamMapper.swift` | 3 |
| `Mantle/Server/ModelsHandler.swift` | 4 |
| `Mantle/Server/ChatHandler.swift` | 4 |
| `Mantle/Server/ProxyServer.swift` | 4 |
| `Mantle/Views/MenuBarView.swift` | 5 |

---

## Phase 8 — Xcode 27 MCP Server Integration

### Overview

Phase 8 adds an MCP (Model Context Protocol) server transport alongside the existing OpenAI
REST proxy. Both modes run simultaneously on the same port. Xcode 27 connects via
`GET /mcp/sse` (SSE channel) and `POST /mcp/message` (client→server channel) using
JSON-RPC 2.0. Mantle exposes AWS Bedrock models via MCP's provider registry and streams
completions as `notifications/progress` events.

**No new SPM dependency is required.** Hummingbird's existing SSE and route capabilities are
sufficient. The MCP wire protocol is implemented from scratch using Foundation's `JSONEncoder`/
`JSONDecoder`.

---

### New File Structure

```
Mantle/
└── MCP/
    ├── MCPTypes.swift           — JSON-RPC 2.0 + MCP protocol types (Codable + Sendable)
    ├── MCPSession.swift         — per-connection actor (SSE continuation + lifecycle state)
    ├── MCPSessionRegistry.swift — actor; manages [UUID: MCPSession] across connections
    ├── MCPRouter.swift          — dispatches JSON-RPC methods; enforces initialize lifecycle
    ├── MCPHandler.swift         — implements initialize, tools/list, tools/call
    └── MCPStreamAdapter.swift   — wraps Bedrock AsyncThrowingStream → MCP progress notifications
```

Updates to existing files:
- `Store/SettingsStore.swift` — add `@AppStorage("mcpEnabled") var mcpEnabled: Bool = false`
- `Server/ProxyServer.swift` — register `/mcp/sse` and `/mcp/message` routes; pass registry
- `Views/SettingsView.swift` — add "Mode" tab with the Legacy / MCP toggle
- `Views/LogConsoleView.swift` — pretty-print JSON-RPC payloads with method label prefix

---

### Component Specifications

#### MCPTypes.swift

All types `Codable + Sendable`.

```swift
// Polymorphic JSON-RPC ID: string | number | null
enum JSONRPCId: Codable, Sendable, Equatable {
    case string(String)
    case number(Int)
    case null
    // Custom init(from:) tries Int first, then String, falls back to .null
}

struct JSONRPCRequest<P: Codable & Sendable>: Codable, Sendable {
    let jsonrpc : String       // always "2.0"
    let id      : JSONRPCId?   // nil → notification (no response expected)
    let method  : String
    let params  : P?
}

struct JSONRPCResponse<R: Codable & Sendable>: Codable, Sendable {
    let jsonrpc : String
    let id      : JSONRPCId
    let result  : R?
    let error   : JSONRPCErrorObject?
}

struct JSONRPCErrorObject: Codable, Sendable {
    let code    : Int
    let message : String
    let data    : AnyCodable?   // reuse existing AnyCodable from OpenAITypes.swift
}

struct JSONRPCNotification<P: Codable & Sendable>: Codable, Sendable {
    let jsonrpc : String
    let method  : String
    let params  : P?
}

// MCP initialize
struct MCPInitializeParams: Codable, Sendable {
    let protocolVersion : String
    let capabilities    : [String: AnyCodable]?
    let clientInfo      : MCPClientInfo
}
struct MCPClientInfo: Codable, Sendable { let name: String; let version: String }
struct MCPInitializeResult: Codable, Sendable {
    let protocolVersion : String
    let capabilities    : MCPServerCapabilities
    let serverInfo      : MCPServerInfo
}
struct MCPServerCapabilities: Codable, Sendable {
    let tools        : MCPToolsCapability?
    let experimental : [String: AnyCodable]?
}
struct MCPToolsCapability: Codable, Sendable { let listChanged: Bool? }
struct MCPServerInfo: Codable, Sendable { let name: String; let version: String }

// MCP tools/list
struct MCPTool: Codable, Sendable {
    let name        : String
    let description : String
    let inputSchema : [String: AnyCodable]   // JSON Schema object
}
struct MCPToolsListResult: Codable, Sendable { let tools: [MCPTool] }

// MCP tools/call
struct MCPToolCallParams: Codable, Sendable {
    let name          : String
    let arguments     : [String: AnyCodable]?
    let progressToken : JSONRPCId?
    // Xcode 27 workspace context (extensible bag — unknown keys silently dropped by decoder)
    let context       : MCPXcodeContext?
}
struct MCPXcodeContext: Codable, Sendable {
    let workspaceState  : AnyCodable?
    let swiftUIPreviews : AnyCodable?
    let testLogs        : AnyCodable?
    // CodingKeys: workspaceState, swiftUIPreviews, testLogs
    // Unknown keys must be silently ignored — custom init(from:) uses KeyedDecodingContainer
    //   and reads only the three known keys; all others are discarded without throwing.
}

// notifications/progress
struct MCPProgressParams: Codable, Sendable {
    let progressToken : JSONRPCId
    let progress      : Int
    let total         : Int?
    let value         : MCPProgressValue
}
struct MCPProgressValue: Codable, Sendable {
    let delta        : String?   // streamed text token; nil on final notification
    let finishReason : String?   // set on final progress notification
    let usage        : MCPUsage?
}
struct MCPUsage: Codable, Sendable { let inputTokens: Int; let outputTokens: Int }

// Standard JSON-RPC 2.0 error codes + MCP extension
enum JSONRPCErrorCode: Int {
    case parseError           = -32700
    case invalidRequest       = -32600
    case methodNotFound       = -32601
    case invalidParams        = -32602
    case internalError        = -32603
    case serverNotInitialized = -32002
}
```

---

#### MCPSession.swift

```swift
actor MCPSession {
    enum Lifecycle { case awaitingInitialize, ready }

    let sessionId: UUID
    private(set) var lifecycle: Lifecycle = .awaitingInitialize
    private var continuation: AsyncStream<String>.Continuation?

    init(sessionId: UUID)

    // Called by the SSE route handler immediately after creating the AsyncStream
    func attach(continuation: AsyncStream<String>.Continuation)

    // Frames value as "event: message\ndata: <json>\n\n" and yields to continuation
    func send<T: Encodable>(_ value: T) throws

    // Yields "event: endpoint\ndata: /mcp/message?sessionId=<id>\n\n"
    func sendEndpointEvent(port: Int)

    // Yields ": keep-alive\n\n"
    func sendKeepAlive()

    // Transitions lifecycle to .ready; called by MCPRouter after "initialized" notification
    func markReady()

    // Finishes the AsyncStream continuation (client disconnect cleanup)
    func close()
}
```

---

#### MCPSessionRegistry.swift

```swift
actor MCPSessionRegistry {
    static let shared = MCPSessionRegistry()
    private var sessions: [UUID: MCPSession] = [:]

    func register(_ session: MCPSession)
    func remove(sessionId: UUID)
    func session(for sessionId: UUID) -> MCPSession?
}
```

---

#### MCPRouter.swift

Receives a raw `Data` body from `POST /mcp/message`, decodes the JSON-RPC envelope, enforces
the lifecycle state machine, and dispatches to `MCPHandler`.

```swift
struct MCPRouter {
    let handler  : MCPHandler
    let registry : MCPSessionRegistry

    // Entry point called by the POST /mcp/message route handler.
    // sessionId comes from the ?sessionId= query parameter.
    func handle(body: Data, sessionId: UUID) async
}
```

Dispatch rules (executed in order):
1. Decode `JSONRPCRequest<AnyCodable>` — on parse failure send `parseError` (-32700) and return.
2. Look up session in registry — on miss return silently (SSE channel already gone).
3. If `session.lifecycle == .awaitingInitialize` AND `method != "initialize"` → send
   `serverNotInitialized` error (-32002).
4. If `id == nil` → notification path (never send a response):
   - `"initialized"` → `session.markReady()`
   - `"notifications/cancelled"` → cancel in-flight stream (reserved for future implementation)
   - unknown → silently ignore
5. Request path — dispatch by `method`:
   - `"initialize"` → `handler.initialize(params:session:id:)`
   - `"tools/list"` → `handler.toolsList(session:id:)`
   - `"tools/call"` → `handler.toolsCall(params:session:id:)`
   - unknown → send `methodNotFound` error (-32601)

---

#### MCPHandler.swift

```swift
struct MCPHandler {
    let settings : SettingsStore
    let bedrock  : BedrockService

    // "initialize" — reply with MCPInitializeResult.
    // Do NOT call session.markReady() here; wait for the "initialized" notification
    // (MCPRouter handles that transition).
    func initialize(
        params  : MCPInitializeParams,
        session : MCPSession,
        id      : JSONRPCId
    ) async throws

    // "tools/list" — return one tool named "completion" with JSON Schema:
    //   { model?: string, messages: [{role, content}], context?: MCPXcodeContext }
    func toolsList(session: MCPSession, id: JSONRPCId) async throws

    // "tools/call" where params.name == "completion":
    // 1. Extract messages from params.arguments["messages"]
    // 2. Extract optional context (unknown fields silently dropped by MCPXcodeContext decoder)
    // 3. Map context fields → additional SystemContentBlocks (truncated to 8,000 chars each):
    //      testLogs        → "Test logs:\n<value>"
    //      workspaceState  → "Workspace:\n<value>"
    //      swiftUIPreviews → "SwiftUI previews:\n<value>"
    //    Log [WARN] if truncation occurs.
    // 4. Call OpenAIToBedrockMapper.map(messages) — on error send invalidParams (-32602)
    // 5. Append context SystemContentBlocks to the mapped system array
    // 6. Guard: if arguments["tools"] present → send invalidParams, log [WARN]
    // 7. ensureClient, stream from BedrockService
    // 8. Create MCPStreamAdapter and stream progress notifications to session
    // 9. On completion send final tools/call result: {content:[{type:"text",text:""}]}
    func toolsCall(
        params  : MCPToolCallParams,
        session : MCPSession,
        id      : JSONRPCId
    ) async
}
```

`MCPHandler` reuses `OpenAIToBedrockMapper.map(_:)` and `BedrockService.stream(input:)`
directly. No duplication of mapping or streaming logic.

---

#### MCPStreamAdapter.swift

Analogous to `StreamMapper` but emits `notifications/progress` JSON-RPC notifications instead
of OpenAI SSE chunks.

```swift
struct MCPStreamAdapter {
    let session       : MCPSession
    let progressToken : JSONRPCId?   // nil if client did not request streaming progress
    let requestId     : JSONRPCId
    let modelId       : String

    // Iterates Bedrock events and routes to session:
    // - contentBlockDelta text → notifications/progress (progressToken present)
    //                            or accumulate in buffer (progressToken nil)
    // - metadata             → accumulate inputTokens / outputTokens
    // - messageStop          → final notifications/progress with finishReason + usage,
    //                          then send tools/call result (empty text if streamed, full buffer if not)
    // - 15 s silence         → session.sendKeepAlive()
    // - error mid-stream     → send final notifications/progress with finishReason="error",
    //                          then send tools/call result with empty content block;
    //                          never send a JSON-RPC error response after streaming has started
    func stream(bedrockEvents: some AsyncSequence<ConverseStreamOutput, Error>) async
}
```

Streaming behaviour:
- `progressToken != nil`: each token yields a `notifications/progress` notification; the final
  `tools/call` result carries an empty `text` content block (tokens already delivered via progress).
- `progressToken == nil`: all tokens are accumulated in a `String` buffer; the final `tools/call`
  result carries the full accumulated text in a single content block.

---

#### ProxyServer.swift — route additions

In `start()`, register MCP routes alongside the existing `/v1/*` routes:

```swift
router.get("/mcp/sse",      use: mcpSSEHandler)
router.post("/mcp/message", use: mcpMessageHandler)
```

**`mcpSSEHandler`:**
1. Create `MCPSession(sessionId: UUID())`
2. Register in `MCPSessionRegistry.shared`
3. Create `AsyncStream<String>` and attach its continuation to the session
4. Send `endpoint` event immediately (`session.sendEndpointEvent(port: settings.port)`)
5. Start keep-alive `Task` (every 15 s → `session.sendKeepAlive()`); cancel on disconnect
6. Return SSE `Response` streaming from the `AsyncStream`
7. On stream finish, call `MCPSessionRegistry.shared.remove(sessionId:)`

**`mcpMessageHandler`:**
1. Read `sessionId` from query parameter — return HTTP 400 if missing or not a valid UUID
2. Look up session in registry — return HTTP 404 if not found
3. Collect body up to 1 MB
4. Call `MCPRouter.handle(body:sessionId:)` fire-and-forget (response travels over SSE)
5. Return `Response(status: .accepted)` (empty 202 body)

**`mcpEnabled` guard (applies to both MCP routes):**
If `settings.mcpEnabled == false`, return HTTP 200 with body:
```json
{"jsonrpc":"2.0","id":null,"error":{"code":-32601,"message":"MCP mode disabled in Mantle settings"}}
```
JSON-RPC errors must always ride inside a 200 response, not an HTTP error status.

---

#### SettingsStore.swift — addition

```swift
@AppStorage("mcpEnabled") var mcpEnabled: Bool = false
```

---

#### SettingsView.swift — "Mode" tab

Add a third tab to the existing `TabView`:

```
Tab label: "Mode"  (system image: "arrow.triangle.2.circlepath")
  Form(.grouped) {
    Section("Proxy Modes") {
      Toggle("Legacy Proxy (Xcode 26)", isOn: .constant(true))   // always on, disabled
        .disabled(true)
      Toggle("MCP Server (Xcode 27+)", isOn: $settings.mcpEnabled)
    }
    Section("MCP Endpoints") {
      LabeledContent("SSE channel",  value: "/mcp/sse")
        .font(.system(.body, design: .monospaced))
      LabeledContent("RPC channel",  value: "/mcp/message")
        .font(.system(.body, design: .monospaced))
    }
    Section {
      Text("Both modes are active simultaneously on the same port. Toggling MCP does not restart the server.")
        .foregroundColor(.secondary)
        .font(.callout)
    }
  }
```

---

#### LogConsoleView.swift — MCP log formatting

In the view's per-entry text rendering, add a branch for MCP entries:

- **Detect**: `entry.text.hasPrefix("[MCP]")`
- **Extract**: find the first `{` in `entry.text`; everything from there is the raw JSON payload
- **Pretty-print**: re-parse with `JSONSerialization` and re-encode with `.prettyPrinted`; fall
  back to the raw string if parsing fails
- **Truncate**: cap the rendered string at 2,000 characters; append `"…(truncated)"` if longer
- **Colour**: cyan tint (`Color.cyan.opacity(0.9)`), distinct from info (primary), warn (orange),
  error (red)

---

### SSE Wire Format — MCP Channel

```
// Sent immediately on GET /mcp/sse connect
event: endpoint
data: /mcp/message?sessionId=<uuid>

// JSON-RPC response (reply to a request)
event: message
data: {"jsonrpc":"2.0","id":1,"result":{...}}

// JSON-RPC notification (no id — server-push)
event: message
data: {"jsonrpc":"2.0","method":"notifications/progress","params":{...}}

// Keep-alive (emitted every 15 s of silence)
: keep-alive
```

SSE response headers (same as legacy proxy):
```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```

---

### MCP Lifecycle Sequence

```
Xcode 27                                    Mantle
  │                                           │
  │── GET /mcp/sse ──────────────────────────>│
  │<─ event: endpoint                         │
  │   data: /mcp/message?sessionId=<uuid> ───│
  │                                           │
  │── POST /mcp/message ────────────────────>│  {"jsonrpc":"2.0","id":1,"method":"initialize",...}
  │<─ event: message                          │
  │   data: {"id":1,"result":{...}} ─────────│
  │                                           │
  │── POST /mcp/message ────────────────────>│  {"jsonrpc":"2.0","method":"initialized"}
  │   (202 Accepted — no SSE reply sent)      │   ↳ MCPRouter calls session.markReady()
  │                                           │
  │── POST /mcp/message ────────────────────>│  {"id":2,"method":"tools/list"}
  │<─ event: message                          │
  │   data: {"id":2,"result":{"tools":[...]}} │
  │                                           │
  │── POST /mcp/message ────────────────────>│  {"id":3,"method":"tools/call",
  │                                           │   "params":{"name":"completion",
  │                                           │    "progressToken":3,
  │                                           │    "arguments":{"messages":[...],"context":{...}}}}
  │<─ event: message (×N tokens)              │  notifications/progress (delta token)
  │<─ event: message (final)                  │  {"id":3,"result":{"content":[{...}]}}
```

---

### Edge Cases

1. **`id` polymorphism** — `JSONRPCId.init(from:)` tries `Int` first (most common from Xcode),
   then `String`, then decodes as `.null`. `encode(to:)` writes the underlying value directly.
   Any decode failure returns `parseError` (-32700).

2. **Session not found on POST** — if the SSE connection was closed between the `endpoint` event
   and a subsequent `POST /mcp/message`, the registry lookup returns nil; return HTTP 404. No SSE
   reply is possible, which is correct.

3. **Double `initialize`** — if `initialize` arrives when `lifecycle == .ready`, respond with
   `invalidRequest` (-32600). Do not reset the session state.

4. **Unknown tool name** — `tools/call` with `name != "completion"` returns `methodNotFound`
   (-32601).

5. **`tools` field in arguments** — Bedrock Phase 8 does not support tool use. If
   `arguments["tools"]` is present, return `invalidParams` (-32602) and log `[WARN] MCP tools
   field not supported`.

6. **Bedrock error mid-stream** — if streaming has already started (at least one
   `notifications/progress` sent), never send a JSON-RPC error response. Instead emit a final
   `notifications/progress` with `value.finishReason = "error"` and `value.delta = nil`, then
   send the `tools/call` result with an empty content block.

7. **`MCPXcodeContext` unknown fields** — `init(from:)` reads only `workspaceState`,
   `swiftUIPreviews`, and `testLogs` by explicit key lookup; all other keys in the JSON object
   are ignored. Never throw `DecodingError.keyNotFound` for unknown fields.

8. **Large context payloads** — each `MCPXcodeContext` field that maps to a `SystemContentBlock`
   is truncated to 8,000 characters before append. Log `[WARN] Context field truncated:
   <fieldName>` when truncation occurs.

9. **Concurrent sessions** — `MCPSessionRegistry` is an actor; concurrent registrations from
   multiple Xcode windows are serialized automatically. Each session has its own `UUID` and
   isolated `AsyncStream` continuation.

10. **Keep-alive on MCP SSE** — same 15 s interval as the legacy OpenAI proxy. Uses the comment
    form (`: keep-alive\n\n`) which is valid in both unnamed SSE (legacy) and named-event SSE
    (MCP). No code change to the comment format is needed.

---

### Implementation Checklist

#### Step 8.1 — MCPTypes.swift

- [ ] **8.1.1** Create `Mantle/MCP/MCPTypes.swift` and add a new `MCP` group in Xcode.
- [ ] **8.1.2** Implement `JSONRPCId` with custom `Codable`. Write unit tests:
  `1` decodes as `.number(1)`, `"abc"` as `.string("abc")`, `null` as `.null`,
  and each round-trips back to JSON correctly.
- [ ] **8.1.3** Implement all request/response/notification/params/result structs listed above.
- [ ] **8.1.4** Implement `MCPXcodeContext.init(from:)` using explicit key lookups so unknown
  fields are silently discarded.

#### Step 8.2 — MCPSession + MCPSessionRegistry

- [ ] **8.2.1** Create `Mantle/MCP/MCPSession.swift` — actor with `Lifecycle` state machine.
  `send<T: Encodable>(_:)` frames as `"event: message\ndata: <json>\n\n"`.
  `sendEndpointEvent(port:)` frames as `"event: endpoint\ndata: /mcp/message?sessionId=<id>\n\n"`.
- [ ] **8.2.2** Create `Mantle/MCP/MCPSessionRegistry.swift` — actor singleton.
- [ ] **8.2.3** Unit test `MCPSession`: attach a mock continuation, call `send(someEncodable)`,
  assert the yielded string starts with `"event: message\ndata: "` and parses as valid JSON.

#### Step 8.3 — MCPStreamAdapter

- [ ] **8.3.1** Create `Mantle/MCP/MCPStreamAdapter.swift`. Reuse `BedrockService.stream(input:)`
  (Phase 3) — no duplication of Bedrock client logic.
- [ ] **8.3.2** If `progressToken != nil`: emit `notifications/progress` per `contentBlockDelta`
  token; final `tools/call` result carries empty text.
  If `progressToken == nil`: accumulate all tokens; final `tools/call` result carries full text.
- [ ] **8.3.3** Unit test with a canned `AsyncThrowingStream` (same pattern as Phase 6.3):
  assert `notifications/progress` events are sent for each `contentBlockDelta`, and the final
  `tools/call` result is sent on `messageStop` with correct usage counts.

#### Step 8.4 — MCPRouter + MCPHandler

- [ ] **8.4.1** Create `Mantle/MCP/MCPRouter.swift`. Implement lifecycle state machine and
  dispatch table per the rules above.
- [ ] **8.4.2** Create `Mantle/MCP/MCPHandler.swift`. In `toolsCall`: extract context, truncate
  to 8,000 chars, prepend as `SystemContentBlock`s. Reuse `OpenAIToBedrockMapper.map(_:)`.
- [ ] **8.4.3** Unit test router lifecycle:
  - `tools/list` before `initialize` → `serverNotInitialized` error sent to session
  - `initialize` + `initialized` notification → `markReady()` called; subsequent `tools/list` succeeds
- [ ] **8.4.4** Unit test handler: `tools/call` with `testLogs` context → Bedrock input contains
  a system block prefixed with `"Test logs:\n"`.

#### Step 8.5 — ProxyServer route wiring

- [ ] **8.5.1** Update `Server/ProxyServer.swift`: register `GET /mcp/sse` and
  `POST /mcp/message` routes.
- [ ] **8.5.2** Implement `mcpSSEHandler`: create session, attach continuation, send endpoint
  event, start 15 s keep-alive task, return streaming SSE response, clean up registry on finish.
- [ ] **8.5.3** Implement `mcpMessageHandler`: validate `sessionId`, look up session, dispatch
  to `MCPRouter` fire-and-forget, return 202.
- [ ] **8.5.4** Add `mcpEnabled` guard to both MCP routes: return 200 + disabled JSON-RPC error
  body when `settings.mcpEnabled == false`.

#### Step 8.6 — SettingsStore + UI

- [ ] **8.6.1** Add `@AppStorage("mcpEnabled") var mcpEnabled: Bool = false` to `SettingsStore`.
- [ ] **8.6.2** Add "Mode" tab to `SettingsView` per the spec above.
- [ ] **8.6.3** Update `LogConsoleView` entry rendering: detect `[MCP]`-prefixed entries,
  pretty-print embedded JSON, apply cyan tint, cap at 2,000 chars.
- [ ] **8.6.4** Verify `SettingsView` preview still compiles after the tab addition.

#### Step 8.7 — Integration & Verification

- [ ] **8.7.1** Curl smoke test — SSE connect:
  ```bash
  curl -N http://127.0.0.1:8080/mcp/sse
  # Expected: first two lines are "event: endpoint" and "data: /mcp/message?sessionId=..."
  ```
- [ ] **8.7.2** Curl smoke test — `initialize` handshake:
  ```bash
  # In terminal 1 (background): capture the SSE stream and extract sessionId
  # In terminal 2: POST initialize; watch terminal 1 for the "event: message" response
  curl -X POST "http://127.0.0.1:8080/mcp/message?sessionId=<uuid>" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
         "params":{"protocolVersion":"2024-11-05","capabilities":{},
                   "clientInfo":{"name":"test","version":"1"}}}'
  # Expect 202 from POST; SSE stream yields event:message with id:1 result
  ```
- [ ] **8.7.3** Curl smoke test — `tools/call` with progress streaming:
  After `initialize` + `initialized`, send `tools/call` with `progressToken: 99` and a user
  message; assert multiple `notifications/progress` events appear on the SSE stream before the
  final result with `id: 3`.
- [ ] **8.7.4** Toggle MCP off in Settings; repeat 8.7.1; assert response body is the disabled
  error JSON, not an SSE stream.
- [ ] **8.7.5** End-to-end: configure Xcode 27 Intelligence settings to use Mantle as an MCP
  provider. Invoke the AI coding assistant in a Swift file. Confirm tokens stream in Xcode and
  Mantle's log console shows cyan-tinted `[MCP]` entries.

---

### Updated "Files Created by Phase" Table

| File | Phase |
|---|---|
| `Mantle/MCP/MCPTypes.swift` | 8 |
| `Mantle/MCP/MCPSession.swift` | 8 |
| `Mantle/MCP/MCPSessionRegistry.swift` | 8 |
| `Mantle/MCP/MCPRouter.swift` | 8 |
| `Mantle/MCP/MCPHandler.swift` | 8 |
| `Mantle/MCP/MCPStreamAdapter.swift` | 8 |
| `Mantle/Store/SettingsStore.swift` | 1 → updated in 8 |
| `Mantle/Server/ProxyServer.swift` | 4 → updated in 8 |
| `Mantle/Views/SettingsView.swift` | 1 → updated in 8 |
| `Mantle/Views/LogConsoleView.swift` | 1 → updated in 8 |

---

## Phase 9 — Dynamic Model List

### Overview

Replace the hardcoded six-entry `HardcodedModels.all` with a live list fetched from
`bedrock:ListFoundationModels` at server start and whenever the region or profile changes.
Fall back to the hardcoded list if the API call fails. Cache the result in memory — no
disk persistence needed.

### New / Changed Files

- `Mantle/Bedrock/BedrockService.swift` — add `listModels() async throws -> [OpenAIModel]`
- `Mantle/Models/HardcodedModels.swift` — demoted to fallback constant
- `Mantle/Server/ModelsHandler.swift` — query live list instead of hardcoded array
- `Mantle/Store/ModelStore.swift` — new; actor that caches the fetched list

### Component Specifications

#### ModelStore

```swift
actor ModelStore {
    static let shared = ModelStore()
    private(set) var models: [OpenAIModel] = HardcodedModels.all

    // Called by ServerManager after ensureClient succeeds.
    // On success replaces models; on error keeps previous value and logs [WARN].
    func refresh(using bedrock: BedrockService) async
}
```

`BedrockService.listModels()` calls `BedrockClient.listFoundationModels()`, filters to
`outputModalities` containing `.text` and `modelLifecycleStatus == .active`, maps each
result to `OpenAIModel(id: modelId, object: "model", ownedBy: providerName)`.

`ModelsHandler` reads `await ModelStore.shared.models` instead of `HardcodedModels.all`.

### Implementation Checklist

- [ ] **9.1** Add `listModels() async throws -> [OpenAIModel]` to `BedrockService`.
- [ ] **9.2** Create `Store/ModelStore.swift` with `refresh(using:)` and fallback logic.
- [ ] **9.3** Call `ModelStore.shared.refresh(using: bedrock)` in `ServerManager.toggle()`
  after the server starts successfully.
- [ ] **9.4** Update `ModelsHandler` to read from `ModelStore.shared.models`.
- [ ] **9.5** Unit test: mock `listModels()` returning two models → `ModelStore.models`
  contains those two. Mock throwing → `ModelStore.models` retains fallback list.
- [ ] **9.6** Log `[INFO] Loaded N models from Bedrock` on success; `[WARN] Model list
  fetch failed: <error> — using fallback` on error.

**Verify**: Start server, curl `/v1/models` → list reflects your account's active models.
Stop Wi-Fi, restart → falls back to hardcoded list without crashing.

---

## Phase 10 — Auto-Start on Login

### Overview

Add a toggle in Settings → General that registers Mantle as a Login Item via
`SMAppService.mainApp`, so the server is always available after a reboot without manual
intervention.

### New / Changed Files

- `Mantle/Views/SettingsView.swift` — add Toggle in General tab
- `Mantle/Store/SettingsStore.swift` — no new stored key needed (`SMAppService` persists
  its own state; read back with `SMAppService.mainApp.status`)

### Implementation Checklist

- [ ] **10.1** Add `import ServiceManagement` to `SettingsView.swift`.
- [ ] **10.2** In `GeneralTab`, add:
  ```swift
  Toggle("Launch at Login", isOn: launchAtLogin)
  ```
  where `launchAtLogin` is a `Binding<Bool>` computed from
  `SMAppService.mainApp.status == .enabled` (get) and
  `try? SMAppService.mainApp.register()` / `.unregister()` (set).
- [ ] **10.3** Handle the case where `status == .requiresApproval` — show an informational
  `Text("Approval required in System Settings → General → Login Items")` beneath the toggle.
- [ ] **10.4** Manual verify: toggle on → quit and relogin → Mantle appears in menu bar.
  Toggle off → relogin → Mantle does not auto-start.

---

## Phase 11 — Tool / Function Calling

### Overview

Map OpenAI `tools` / `tool_choice` to Bedrock's `toolConfig` parameter, enabling
agents and function-calling workflows. Remove the blanket `501 Not Implemented` guard
in `ChatHandler`.

### New / Changed Files

- `Mantle/Models/OpenAITypes.swift` — add `OpenAITool`, `OpenAIToolFunction`,
  `OpenAIToolChoice`, `OpenAIToolCall`, `OpenAIToolResultMessage`
- `Mantle/Models/OpenAIToBedrockMapper.swift` — add `mapTools(_:)` and
  `mapToolResult(_:)` static methods; update `map(_:)` to handle `role:"tool"` messages
- `Mantle/Bedrock/StreamMapper.swift` — handle `.contentBlockDelta` + `.toolUse(…)` events;
  emit `delta.tool_calls` SSE chunks in OpenAI format
- `Mantle/Server/ChatHandler.swift` — remove `tools != nil` guard; pass `toolConfig` to
  `ConverseStreamInput`

### Wire Format Notes

OpenAI tool-call delta chunks use:
```json
{"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function",
  "function":{"name":"get_weather","arguments":"{\"loc"}}]}}
```
Bedrock emits tool use via `.contentBlockStart` (with `toolUse.toolUseId` and `name`)
followed by `.contentBlockDelta` events carrying partial JSON input, then
`.contentBlockStop`.

Tool results arrive in the next request as `role:"tool"` messages with `tool_call_id`.
Map these to Bedrock `role:.user` messages containing a `ToolResultBlock`.

### Implementation Checklist

- [ ] **11.1** Extend `OpenAITypes.swift` with tool-related types.
- [ ] **11.2** Add `OpenAIToBedrockMapper.mapTools(_: [OpenAITool]) -> ToolConfigBlock`
  and update `map(_:)` to convert `role:"tool"` → Bedrock `ToolResultBlock`.
- [ ] **11.3** Update `StreamMapper` to accumulate tool-use block deltas and emit
  `delta.tool_calls` chunks; emit `finish_reason: "tool_calls"` on `messageStop` when
  stop reason is `tool_use`.
- [ ] **11.4** Update `ChatHandler`: remove 501 guard; build `ConverseStreamInput` with
  `toolConfig` when `chatRequest.tools` is non-nil.
- [ ] **11.5** Unit test: mapper converts one `OpenAITool` → correct `ToolConfigBlock`;
  `role:"tool"` message → `ToolResultBlock` in the Bedrock messages array.
- [ ] **11.6** Integration test with a model that supports tool use (e.g.
  `anthropic.claude-3-5-sonnet-20241022-v2:0`): send a request with one tool definition;
  assert the SSE stream contains `delta.tool_calls` chunks and `finish_reason:"tool_calls"`.

---

## Phase 12 — Per-Request Model Override

### Overview

Honour the `model` field in the incoming OpenAI request when it matches a known Bedrock
model ID, while keeping the Settings default as fallback for unknown or empty values.
Adds zero new UI; the logic lives entirely in `ChatHandler`.

### Changed Files

- `Mantle/Server/ChatHandler.swift` — resolve effective model before building `ConverseStreamInput`

### Logic

```swift
let effectiveModel: String = {
    let requested = chatRequest.model
    let known = await ModelStore.shared.models.map(\.id)
    if known.contains(requested) { return requested }
    return defaultModel   // from SettingsStore
}()
```

Log `[INFO] model override: \(requested)` when the incoming model is used, or
`[INFO] model fallback → \(defaultModel)` when it is not recognised.

### Implementation Checklist

- [ ] **12.1** Update `ChatHandler.handle` to resolve `effectiveModel` as above.
- [ ] **12.2** Pass `effectiveModel` to `ConverseStreamInput` and `StreamMapper`.
- [ ] **12.3** Unit test: request with a known model ID → `effectiveModel` equals that ID.
  Request with `"gpt-4"` → `effectiveModel` equals the Settings default.

---

## Phase 13 — Usage Dashboard

### Overview

Add a **Usage** tab to Settings that shows per-session token totals and a projected cost
estimate, using hardcoded Bedrock on-demand pricing for the models Mantle supports.

### New / Changed Files

- `Mantle/Store/UsageStore.swift` — new; actor accumulating `UsageRecord` entries
- `Mantle/Views/UsageView.swift` — new; table + summary row
- `Mantle/Views/SettingsView.swift` — add Usage tab
- `Mantle/Server/ChatHandler.swift` — pass usage to `UsageStore` via the `onUsage` callback

### Component Specifications

#### UsageStore

```swift
struct UsageRecord: Identifiable, Sendable {
    let id        = UUID()
    let date      : Date
    let modelId   : String
    let prompt    : Int
    let completion: Int
}

actor UsageStore {
    static let shared = UsageStore()
    private(set) var records: [UsageRecord] = []   // unbounded within session; cleared on quit

    func append(_ record: UsageRecord)
    func clear()

    // Returns (promptTotal, completionTotal, estimatedUSDCents) for current session
    func sessionSummary() -> (Int, Int, Double)
}
```

Pricing table (hardcoded, per 1 000 tokens, USD):

| Model | Input | Output |
|---|---|---|
| `claude-3-5-sonnet-20241022-v2:0` | $0.003 | $0.015 |
| `claude-3-5-haiku-20241022-v1:0` | $0.0008 | $0.004 |
| `claude-3-haiku-20240307-v1:0` | $0.00025 | $0.00125 |
| `claude-3-opus-20240229-v1:0` | $0.015 | $0.075 |
| `nova-pro-v1:0` | $0.0008 | $0.0032 |
| `nova-lite-v1:0` | $0.00006 | $0.00024 |

#### UsageView

```
Tab label: "Usage"  (system image: "chart.bar")
  Summary row: "Session total: N prompt + M completion tokens  ≈ $X.XX"
  Table: Date | Model | Prompt | Completion | Est. Cost
  "Clear" button (bottom trailing)
```

### Implementation Checklist

- [ ] **13.1** Create `Store/UsageStore.swift` with pricing table and `sessionSummary()`.
- [ ] **13.2** Create `Views/UsageView.swift` with summary row and `List` of records.
- [ ] **13.3** Add Usage tab to `SettingsView`.
- [ ] **13.4** In `ChatHandler`, extend the `onUsage` callback to also call
  `UsageStore.shared.append(UsageRecord(date:modelId:prompt:completion:))`.
- [ ] **13.5** Unit test: append three records, call `sessionSummary()`, assert totals and
  estimated cost match expected values.

---

## Phase 14 — Non-Streaming Fallback

### Overview

Handle requests where `stream` is `false` (or absent) by accumulating the full Bedrock
stream internally and returning a single JSON response in the `chat.completion` (non-chunk)
format. This extends compatibility to any OpenAI client that does not support SSE.

### Changed Files

- `Mantle/Server/ChatHandler.swift` — branch on `chatRequest.stream`
- `Mantle/Bedrock/ResponseCollector.swift` — new; accumulates stream into a single response

### Component Specification

#### ResponseCollector

```swift
struct ResponseCollector {
    let completionId : String
    let created      : Int
    let modelId      : String

    // Drains the Bedrock event stream, returns a complete OpenAIChatResponse.
    func collect(
        bedrockEvents: some AsyncSequence<ConverseStreamOutput, Error>
    ) async throws -> OpenAIChatResponse
}
```

`OpenAIChatResponse` is the non-streaming counterpart to `OpenAIChunk`:
```swift
struct OpenAIChatResponse: Codable, Sendable {
    let id      : String
    let object  : String   // "chat.completion"
    let created : Int
    let model   : String
    let choices : [OpenAIChatChoice]
    let usage   : OpenAIUsage
}
struct OpenAIChatChoice: Codable, Sendable {
    let index         : Int
    let message       : OpenAIDelta   // role + content fully populated
    let finishReason  : String
}
```

### Implementation Checklist

- [ ] **14.1** Add `OpenAIChatResponse` and `OpenAIChatChoice` to `OpenAITypes.swift`.
- [ ] **14.2** Create `Bedrock/ResponseCollector.swift`.
- [ ] **14.3** In `ChatHandler.handle`, check `chatRequest.stream == false`:
  - If non-streaming: use `ResponseCollector`, return `application/json` response.
  - If streaming (default): existing `StreamMapper` path unchanged.
- [ ] **14.4** Unit test: canned Bedrock events → `ResponseCollector` returns correct
  `OpenAIChatResponse` with concatenated content, finish reason, and usage.
- [ ] **14.5** Curl verify:
  ```bash
  curl -X POST http://127.0.0.1:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"any","messages":[{"role":"user","content":"hi"}],"stream":false}'
  # Expected: single JSON object, not SSE
  ```

---

## Phase 15 — Cross-Machine Forwarding

### Overview

Add an option to bind on `0.0.0.0` instead of `127.0.0.1`, with optional bearer-token
authentication, so Mantle can serve other devices on a local network (CI machines, a
second Mac, etc.).

### Changed Files

- `Mantle/Store/SettingsStore.swift` — add `bindAllInterfaces: Bool`, `bearerToken: String`
- `Mantle/Views/SettingsView.swift` — add Network section to General tab
- `Mantle/Server/ProxyServer.swift` — use bind address from settings; add auth middleware
- `Mantle/Server/AuthMiddleware.swift` — new; Hummingbird middleware for bearer validation

### Component Specification

#### SettingsStore additions

```swift
@AppStorage("bindAllInterfaces") var bindAllInterfaces: Bool   = false
@AppStorage("bearerToken")       var bearerToken:       String = ""
```

#### AuthMiddleware

```swift
struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String   // empty string = disabled

    func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response
}
```

If `token` is non-empty, check `Authorization: Bearer <token>` header. Return
`Response(status: .unauthorized)` on mismatch.

#### SettingsView — Network section (inside GeneralTab)

```
Section("Network") {
  Toggle("Accept connections from other devices", isOn: $settings.bindAllInterfaces)
  if settings.bindAllInterfaces {
    TextField("Bearer Token (optional)", text: $settings.bearerToken)
      .help("Leave blank to allow unauthenticated access from your local network")
  }
}
```

Display an informational label showing the LAN IP when `bindAllInterfaces` is true:
```swift
Text("Listening on \(lanIPAddress()):\(settings.port)")
    .foregroundColor(.secondary)
```

### Implementation Checklist

- [ ] **15.1** Add `bindAllInterfaces` and `bearerToken` to `SettingsStore`.
- [ ] **15.2** Create `Server/AuthMiddleware.swift`.
- [ ] **15.3** Update `ProxyServer.start()`: bind to `"0.0.0.0"` when `bindAllInterfaces`
  is true, `"127.0.0.1"` otherwise. Apply `AuthMiddleware` to the router when
  `bearerToken` is non-empty.
- [ ] **15.4** Add Network section to `SettingsView` with toggle, optional token field,
  and LAN IP label.
- [ ] **15.5** Add `[WARN] Server bound on 0.0.0.0 — reachable from local network` to
  the log when wide binding is active.
- [ ] **15.6** Unit test: `AuthMiddleware` with token `"abc"` → request with correct
  header passes; request with wrong header or no header returns 401.

---

## Phase 16 — Binary Distribution

### Overview

Package Mantle as a signed, notarised, auto-updating `.dmg` so users can install it without
Xcode. Covers code signing configuration, notarisation via `notarytool`, and a
`Sparkle`-based auto-update feed.

### New / Changed Files

- `Mantle.xcodeproj` — hardened runtime entitlements, correct provisioning
- `Mantle/Mantle.entitlements` — add `com.apple.security.cs.allow-jit` if needed by Sparkle
- `Scripts/build-dmg.sh` — new; creates a drag-install `.dmg` with background image
- `Scripts/notarise.sh` — new; submits to Apple notary service and staples
- `appcast.xml` — new (in a separate distribution repo or GitHub Release); Sparkle feed
- `Mantle/App/MantleApp.swift` — initialise `SPUStandardUpdaterController`

### Implementation Checklist

- [ ] **16.1** In Xcode, enable **Hardened Runtime** and ensure entitlements include
  `com.apple.security.network.client` and `com.apple.security.network.server`.
- [ ] **16.2** Add the `Sparkle` SPM package (`https://github.com/sparkle-project/Sparkle`
  — up to next major from `2.0.0`). Add product `Sparkle`.
- [ ] **16.3** In `MantleApp.swift`, add:
  ```swift
  import Sparkle
  private let updaterController = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  ```
  Add a **Check for Updates…** menu item in `MenuBarView` that calls
  `updaterController.updater.checkForUpdates()`.
- [ ] **16.4** Write `Scripts/build-dmg.sh`: archive with `xcodebuild archive`, export
  with `exportArchive`, produce a drag-install `.dmg` via `hdiutil`.
- [ ] **16.5** Write `Scripts/notarise.sh`: submit with `xcrun notarytool submit`,
  poll until status is `Accepted`, then `xcrun stapler staple`.
- [ ] **16.6** Publish `appcast.xml` (GitHub Releases is a convenient host). Verify
  Sparkle finds the update by setting `SUFeedURL` in `Info.plist`.
- [ ] **16.7** Manual verify: install the `.dmg` on a clean Mac (no Xcode), launch Mantle,
  confirm server starts and responds to curl. Simulate an update by bumping the version and
  republishing; confirm Sparkle prompts and installs.

---

## Updated "Files Created / Modified by Phase" Table

| File | Phase |
|---|---|
| `Mantle/MCP/MCPTypes.swift` | 8 |
| `Mantle/MCP/MCPSession.swift` | 8 |
| `Mantle/MCP/MCPSessionRegistry.swift` | 8 |
| `Mantle/MCP/MCPRouter.swift` | 8 |
| `Mantle/MCP/MCPHandler.swift` | 8 |
| `Mantle/MCP/MCPStreamAdapter.swift` | 8 |
| `Mantle/Store/SettingsStore.swift` | 1 → 8 → 15 |
| `Mantle/Server/ProxyServer.swift` | 4 → 8 → 15 |
| `Mantle/Views/SettingsView.swift` | 1 → 8 → 10 → 13 → 15 |
| `Mantle/Views/LogConsoleView.swift` | 1 → 8 |
| `Mantle/Store/ModelStore.swift` | 9 |
| `Mantle/Store/UsageStore.swift` | 13 |
| `Mantle/Store/UsageView.swift` | 13 |
| `Mantle/Bedrock/ResponseCollector.swift` | 14 |
| `Mantle/Server/AuthMiddleware.swift` | 15 |
| `Scripts/build-dmg.sh` | 16 |
| `Scripts/notarise.sh` | 16 |
