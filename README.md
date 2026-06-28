# Mantle

A macOS menu bar utility that lets you use AWS Bedrock models — Claude, Nova, and others — as the AI backend for Xcode's built-in coding assistant, without touching your AWS bill through a third-party proxy.

Mantle runs a local HTTP server on your Mac that speaks the OpenAI API on one side (what Xcode expects) and AWS Bedrock on the other (where inference actually happens). You point Xcode at `http://127.0.0.1:8080/v1` and Mantle handles everything else: credential resolution, request translation, real-time streaming, and token accounting.

---

## Table of contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Setup](#setup)
  - [1. AWS credentials](#1-aws-credentials)
  - [2. Enable a Bedrock model](#2-enable-a-bedrock-model)
  - [3. Configure Mantle](#3-configure-mantle)
  - [4. Point Xcode at Mantle](#4-point-xcode-at-mantle)
- [Supported models](#supported-models)
- [Use cases](#use-cases)
- [Menu bar reference](#menu-bar-reference)
- [Troubleshooting](#troubleshooting)
- [Future work](#future-work)

---

## How it works

```
Xcode AI Agent
  │  POST /v1/chat/completions  (OpenAI SSE format)
  ▼
Mantle  —  127.0.0.1:8080
  │  Translates messages, maps roles, strips system prompts into Bedrock's format
  ▼
AWS Bedrock  converseStream
  │  Streams tokens back as Server-Sent Events
  ▼
Xcode  (tokens appear in real time)
```

When Xcode sends a chat completion request, Mantle:

1. Decodes the OpenAI-format JSON body.
2. Separates `role:"system"` messages into Bedrock's dedicated system parameter.
3. Enforces Bedrock's strict user/assistant alternation (merging consecutive same-role messages).
4. Ignores the `model` field in the request — always routes to the model you configured in Settings.
5. Calls `BedrockRuntime.converseStream` using the AWS profile and region you chose.
6. Translates each Bedrock stream event back into an OpenAI SSE chunk and forwards it to Xcode.
7. Emits a keep-alive comment every 15 seconds to prevent Xcode from timing out on slow responses.
8. Logs each request and final token counts to the in-app log console.

Credentials never leave your machine. Mantle uses the standard AWS credentials file (the same one the AWS CLI uses) via `ProfileAWSCredentialIdentityResolver` from the official AWS SDK for Swift.

---

## Requirements

| Requirement | Version |
|---|---|
| macOS | 14 Sonoma or later |
| Xcode | 15 or later (to build Mantle) |
| AWS CLI / credentials | Any version — only the `~/.aws/credentials` file is needed at runtime |
| AWS account | With Bedrock access in your chosen region |

---

## Installation

Mantle is not distributed as a binary yet. Build it from source:

1. Clone this repository.
2. Open `Mantle.xcodeproj` in Xcode.
3. Select the **Mantle** scheme and your Mac as the destination.
4. Press `Cmd+R` to build and run.

The first build will resolve SPM packages (`Hummingbird`, `AWSBedrockRuntime`) which may take a minute.

To keep Mantle running across reboots, add it to **System Settings → General → Login Items** after the first launch.

---

## Setup

### 1. AWS credentials

Mantle uses the standard AWS credentials file at `~/.aws/credentials`. If you already use the AWS CLI, you are done. If not, create the file:

```ini
# ~/.aws/credentials
[default]
aws_access_key_id     = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

You can also use named profiles:

```ini
[bedrock-dev]
aws_access_key_id     = AKIA...
aws_secret_access_key = ...
```

Then set the **AWS Profile** field in Mantle's Settings to `bedrock-dev`.

The IAM identity (user or role) needs the following minimum permissions:

```json
{
  "Effect": "Allow",
  "Action": [
    "bedrock:InvokeModelWithResponseStream"
  ],
  "Resource": "arn:aws:bedrock:<region>::foundation-model/*"
}
```

### 2. Enable a Bedrock model

Serverless foundation models are now **automatically enabled** when first invoked — you no longer need to manually activate them through the Model access page.

The one exception is **Anthropic models** (Claude): first-time users in an account may need to submit brief use-case details before the first successful call. If you hit an `AccessDeniedException` on your first request:

1. Open the [AWS Console](https://console.aws.amazon.com/bedrock) and navigate to **Bedrock → Model catalog**.
2. Select the region you intend to use (top-right dropdown).
3. Find the Claude model you want, open it, and follow any one-time approval prompt.

Amazon Nova models and most others invoke without any approval step. If you see a `ValidationException` or `AccessDeniedException` in Mantle's log console on the first request, this is the most likely cause.

### 3. Configure Mantle

Open Mantle's Settings with `Cmd+,` or via the menu bar → **Settings…**. The **General** tab has four fields:

| Field | What to put here | Where to find it |
|---|---|---|
| **AWS Region** | The AWS region to send Bedrock requests to | Common choices: `us-east-1`, `us-west-2`, `eu-west-1`. Pick the region closest to you, or one where your Bedrock quota is highest |
| **AWS Profile** | The profile name from `~/.aws/credentials` | Open `~/.aws/credentials` in a text editor — the name inside `[brackets]`. Use `default` if you only have one profile |
| **Default Model ID** | The Bedrock model ID to route all requests to | See [Supported models](#supported-models) below, or copy from the Bedrock console |
| **Local Port** | The port Mantle listens on | `8080` is fine unless something else is already using it. Run `lsof -i :8080` to check |

Settings are saved automatically to `UserDefaults` and persist across restarts.

### 4. Point Xcode at Mantle

1. Start the server: click the Mantle icon in the menu bar → **Start Server**. The status line should change to *Running on port 8080*.
2. Open **Xcode → Settings → AI** (requires Xcode 16+).
3. Set **Model Endpoint** to `http://127.0.0.1:8080/v1`.
4. Set **Model Name** to anything — Mantle ignores this field and always uses the model from its own Settings.
5. Open a Swift file and invoke the AI coding assistant. Tokens should stream in immediately.

You can verify the server is up at any time:

```bash
curl http://127.0.0.1:8080/v1/models
```

---

## Supported models

The following models are exposed via the `/v1/models` endpoint. Any of them can be set as the Default Model ID in Settings.

| Model ID | Provider | Notes |
|---|---|---|
| `anthropic.claude-3-5-sonnet-20241022-v2:0` | Anthropic | Best quality; default |
| `anthropic.claude-3-5-haiku-20241022-v1:0` | Anthropic | Fastest Anthropic model |
| `anthropic.claude-3-haiku-20240307-v1:0` | Anthropic | Lightweight, low cost |
| `anthropic.claude-3-opus-20240229-v1:0` | Anthropic | Highest capability, slower |
| `amazon.nova-pro-v1:0` | Amazon | Strong general-purpose |
| `amazon.nova-lite-v1:0` | Amazon | Very fast, low cost |

All models must be enabled in your AWS account before use (see [step 2](#2-enable-a-bedrock-model)).

---

## Use cases

**Xcode AI coding assistant on a budget.** Xcode's AI features require a paid subscription to Apple Intelligence or a third-party provider. Mantle lets you use AWS Bedrock instead — you pay only for the tokens you consume, with no monthly subscription.

**Enterprise and regulated environments.** If your organisation has AWS contracts, data residency requirements, or cannot send code to external SaaS AI providers, Mantle keeps everything within your AWS account and on your own machine.

**Model choice.** Rather than being locked to one model, you can switch between Claude, Nova, and any future Bedrock model by changing a single field in Settings — no code changes required.

**AWS cost visibility.** Every request logs the prompt and completion token counts to Mantle's log console. Token costs map directly to your AWS Bedrock usage bill, making it easy to profile expensive interactions.

**Local development with a real model.** Unlike mocked AI completions, Mantle uses the actual model. Useful when you need genuine code suggestions rather than pre-canned responses.

---

## Menu bar reference

Mantle lives entirely in the menu bar. Click the icon to open the menu:

| Item | Behaviour |
|---|---|
| Status line | Shows *Running on port N*, *Stopped*, or an error message. Read-only. |
| Start Server / Stop Server | Starts or stops the local HTTP server. |
| Settings… | Opens the Settings window (`Cmd+,` also works). |
| Quit Mantle | Terminates the app and the server. |

The **Log** tab in Settings shows a live, scrollable console of all server events — requests received, token counts, errors, and server lifecycle messages. Click **Clear** to empty it.

---

## Troubleshooting

**"Error: port 8080 in use"** — Another process is bound to that port. Either stop the other process (`lsof -i :8080` to identify it) or change the port in Settings and restart the server.

**No response / hanging request** — Check the Log tab. A `ValidationException` usually means the model isn't enabled in your region. An `AccessDeniedException` means the IAM identity lacks `bedrock:InvokeModelWithResponseStream`.

**Tokens appear but then stop** — This is normal for very long responses; the keep-alive every 15 s prevents Xcode from closing the connection. If Xcode does time out, it is a client-side setting unrelated to Mantle.

**Xcode doesn't send requests** — Confirm the endpoint is exactly `http://127.0.0.1:8080/v1` (no trailing slash, no HTTPS). Verify with `curl http://127.0.0.1:8080/v1/models`.

**AWS credentials not found** — Mantle reads `~/.aws/credentials`. Confirm the file exists and the profile name in Settings matches exactly (case-sensitive).

---

## Future work

### Phase 8 — MCP Server (Xcode 27+)

The next planned feature adds a Model Context Protocol (MCP) server transport alongside the existing OpenAI proxy. Both modes would run on the same port simultaneously.

Xcode 27 connects to MCP providers via `GET /mcp/sse` (SSE channel) and `POST /mcp/message` (JSON-RPC 2.0 channel). Mantle would expose a `completion` tool, handle the `initialize` / `tools/list` / `tools/call` lifecycle, and stream tokens as `notifications/progress` events. The MCP channel also passes Xcode workspace context (open files, SwiftUI preview state, test logs) that can be injected as additional system context to Bedrock — giving the model more information than the plain OpenAI path.

No new dependencies are needed; the implementation reuses Hummingbird's existing SSE and routing capabilities.

### Other improvements worth considering

**Binary distribution.** Package Mantle as a signed and notarised `.dmg` so users don't need Xcode to install it.

**Auto-start on login.** Add a toggle in Settings to register Mantle as a Login Item via `SMAppService`, so the server is always available without manual intervention.

**Dynamic model list.** Call `bedrock:ListFoundationModels` at startup to populate the model picker with every model actually available in the user's account and region, rather than a hardcoded list.

**Streaming non-support fallback.** Bedrock's `converse` (non-streaming) endpoint could serve clients that don't request SSE, broadening compatibility beyond Xcode.

**Tool / function calling.** Currently returns `501 Not Implemented` when `tools` are present. Mapping OpenAI tool definitions to Bedrock's `toolConfig` parameter would unlock agents and function-calling workflows.

**Per-request model override.** Optionally honour the `model` field in the incoming request to allow the client to select the model dynamically, while keeping the Settings default as fallback.

**Usage dashboard.** A lightweight in-app view that aggregates token counts per session and projects estimated AWS cost, using the public Bedrock pricing tables.

**Cross-machine forwarding.** An option to bind on `0.0.0.0` with optional bearer-token authentication, so Mantle can serve other devices on a local network (e.g. a CI machine or a second Mac).
