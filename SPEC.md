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
