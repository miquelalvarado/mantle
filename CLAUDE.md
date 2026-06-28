# Mantle — CLAUDE.md

macOS 14+ menu bar app (no Dock icon) that proxies OpenAI-format chat completion requests to AWS Bedrock `converseStream`. Lives exclusively in the menu bar.

## Build & Test

Open `Mantle.xcodeproj` in Xcode. There is no CLI build command — use Xcode or `xcodebuild`.

```bash
# Build (simulator not applicable for macOS; use generic/any Mac destination)
xcodebuild -project Mantle.xcodeproj -scheme Mantle -destination 'platform=macOS' build

# Run tests
xcodebuild -project Mantle.xcodeproj -scheme Mantle -destination 'platform=macOS' test
```

Tests live in `MantleTests/MapperTests.swift` (XCTest). Run with `Cmd+U` in Xcode.

## Architecture

```
Xcode AI Agent → POST /v1/chat/completions → ProxyServer (Hummingbird)
                                               → ChatHandler
                                                 → BedrockService → AWS Bedrock converseStream
                                                   → StreamMapper → OpenAI SSE ByteBuffers → client
```

- **No main window, no Dock icon** — `LSUIElement=YES` in `Info.plist`.
- **Binding address**: `127.0.0.1` only (never `0.0.0.0`).
- **App Sandbox disabled** — entitlements: `network.client=true`, `network.server=true`.
- **Swift 6 strict concurrency** (`SWIFT_STRICT_CONCURRENCY=complete`).
- **Incoming `model` field is ignored** — always routes to `SettingsStore.defaultModel`.

## Key Files

| File | Role |
|---|---|
| `App/MantleApp.swift` | Entry point; `MenuBarExtra` + `Settings` scenes |
| `Server/ProxyServer.swift` | Hummingbird actor; registers routes; port-conflict detection |
| `Server/ChatHandler.swift` | POST `/v1/chat/completions` — maps, streams, logs |
| `Server/ModelsHandler.swift` | GET `/v1/models` — returns hardcoded model list |
| `Bedrock/BedrockService.swift` | Actor; holds `BedrockRuntimeClient`; recreates on region/profile change |
| `Bedrock/StreamMapper.swift` | Converts Bedrock event stream → OpenAI SSE `ByteBuffer` stream |
| `Models/OpenAITypes.swift` | All OpenAI wire types (`Codable + Sendable`) |
| `Models/OpenAIToBedrockMapper.swift` | Splits system messages, enforces user/assistant alternation |
| `Models/HardcodedModels.swift` | Six Bedrock model IDs exposed via `/v1/models` |
| `Store/SettingsStore.swift` | `@MainActor ObservableObject`; `@AppStorage` for region/profile/port/model |
| `Store/LogStore.swift` | Actor ring buffer (cap 200); `LogEntry` / `LogLevel` |
| `Views/MenuBarView.swift` | Status label, Start/Stop, Settings, Quit |
| `Views/SettingsView.swift` | `TabView`: General (region/profile/port/model) + Log |
| `Views/LogConsoleView.swift` | Monospaced scroll view; polls `LogStore` every 0.5 s |

## SPM Dependencies

| Package | Product | Purpose |
|---|---|---|
| `hummingbird-project/hummingbird` ≥2.25 | `Hummingbird` | HTTP server |
| `awslabs/aws-sdk-swift` ≥1.0 | `AWSBedrockRuntime` | AWS Bedrock client |

`AWSSDKIdentity` (contains `ProfileAWSCredentialIdentityResolver`) is a transitive dependency — no explicit product entry needed.

## Critical Invariants

- `BedrockService.ensureClient(region:profile:)` **only** recreates the client when region or profile changes. Don't bypass this — creating a new client on every request is expensive.
- `StreamMapper` **never** calls `continuation.finish(throwing:)` after SSE has started (200 already sent). Mid-flight Bedrock errors are serialised as `data: {"error":{...}}\n\n` + `data: [DONE]\n\n` then `continuation.finish()`.
- Bedrock requires **strict user/assistant alternation starting with user**. `OpenAIToBedrockMapper.map(_:)` enforces this — consecutive same-role messages are merged with `"\n"`.
- System messages (`role:"system"`) must be extracted into Bedrock's separate `system` parameter, not left in the messages array.
- `SettingsStore` is `@MainActor` — always read its properties inside `MainActor.run { }` from async contexts (see `ChatHandler.handle`).

## Settings Defaults

| Key | Default |
|---|---|
| AWS region | `us-east-1` |
| AWS profile | `default` |
| Local port | `8080` |
| Default model | `anthropic.claude-3-5-sonnet-20241022-v2:0` |

## Smoke Test (curl)

```bash
# Model list
curl http://127.0.0.1:8080/v1/models

# SSE stream
curl -N -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"Say hello"}],"stream":true}'

# 501 for tools
curl -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4","messages":[{"role":"user","content":"hi"}],"tools":[]}'
```

## Xcode Integration (Phase 7.4)

1. Start Mantle.
2. Xcode Settings → AI → set model endpoint to `http://127.0.0.1:8080/v1`.
3. Model name can be anything (it is ignored by Mantle).
4. Invoke the AI coding assistant in a Swift file.
5. Verify the response streams and the log console shows `POST /v1/chat/completions → <model>` and `tokens prompt=N completion=M`.

## Phase 8 — MCP Server (Planned)

See `SPEC.md` § "Phase 8" for the full MCP (Model Context Protocol) spec. Not yet implemented. New files will live under `Mantle/MCP/`.
