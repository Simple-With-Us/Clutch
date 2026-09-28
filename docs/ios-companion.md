# Harness iOS Companion App

Native iOS companion app for **Harness** (`@deepseek-ai/dsh` and MiniMax harness).  Built with SwiftUI for iOS 17.0+ using XcodeGen.

## Overview

The Harness iOS Companion app brings the power of Harness to iPhone and iPad.  It provides both a rich native SwiftUI interface and a full-parity embedded web experience, allowing developers to manage coding sessions, connect to multiple computers (Mac, local servers, Hetzner, or cloud VMs), trigger Composio actions, search shared Fleet memory, and configure models from MiniMax and DeepSeek.

## Key Features

### 1. Multi-Host / Multi-Computer Support
Connect to and manage multiple Harness instances:
- **Saved Computer Profiles:** Store hostnames, Tailscale IPs, ports, TLS settings, and launch tokens for any number of machines.
- **Active Host Switcher:** Switch between your local Mac (`127.0.0.1:3080`), remote Mac over Tailscale (`macbook.boa-roygbiv.ts.net:3080`), or cloud instances (`cloud.jays.services:3080`) with a single tap.
- **Health Probing & Latency:** Real-time health indicators and millisecond ping latency tracking across all configured hosts.
- **Deep-Link Pairing:** Scan a QR code or tap a link (`harness://pair?host=...&port=...&token=...`) to pair new computers instantly.

### 2. Full Web Interface Parity
- High-performance `WKWebView` container with bidirectional JavaScript bridge.
- Full injection of the Harness brand styling:
  - Neutral sidebar with H monogram brand SVG and `HARNESS` label under.
  - Model picker provider branding for **MiniMax** and **DeepSeek**.
  - Model capability badges: `Preview` (M3.1 Flash), `Multimodal` (V4.1 Flash), and `2x Cost` (M2.7 Highspeed).
  - Workspace auto-binding and keyboard navigation support.
- Mobile controls: pull-to-refresh, navigation stack, and direct Safari sharing.

### 3. Native SwiftUI Chat & Composer
- Clean message history with user and assistant bubbles.
- **Collapsible Reasoning Blocks:** Step-by-step thinking token streaming with animated indicators for reasoning models (`DeepSeek-V4.1-Pro` and `MiniMax-M3`).
- **Tool Call Cards:** Expandable cards displaying tool names, arguments JSON, execution outputs, and duration in milliseconds.
- **Code Highlighting & Copy:** Native code cards with language tags and one-tap clipboard copy.
- **Model Picker Pill:** Instant switching between MiniMax and DeepSeek models with capability chips and reasoning effort controls (`Off`, `Low`, `Medium`, `High`).

### 4. Tool & Ecosystem Integrations
- **Composio Integration:** Manage connected apps (GitHub, Slack, Linear, Notion, Gmail, Discord), verify authorization status, and execute actions.
- **Fleet RAG & Recall:** Direct client for the shared fleet knowledge base (`recall_search`, `recall_contribute`, `recall_stats`).  Query lessons across all agents and contribute new findings directly from mobile.
- **MCP Servers:** Inspect mounted Model Context Protocol servers and tool allowlists.
- **Built-in System Tools:** View execution logs for remote `bash` terminal and `file_editor`.

### 5. Supported Models Matrix

| Model | Vendor | Badges | Reasoning | Context Window | Best For |
|---|---|---|---|---|---|
| `MiniMax-M3` | MiniMax | — | Yes | 204,800 | Balanced general coding and deep reasoning |
| `MiniMax-M3.1-Flash-Preview` | MiniMax | `Preview` | No | 1,000,000 | Frontier multimodal coding with 1M context |
| `MiniMax-M2.7-highspeed` | MiniMax | `2x Cost` | No | 204,800 | Ultra low-latency execution tier |
| `DeepSeek-V4.1-Pro` | DeepSeek | — | Yes | 128,000 | Advanced reasoning-capable frontier model |
| `DeepSeek-V4.1-Flash` | DeepSeek | `Multimodal` | No | 128,000 | Fast text, image, and video processing |

## Project Structure

```
ios/
├── project.yml                     # XcodeGen project specification
├── HarnessCompanion.entitlements   # iOS entitlements
├── Assets.xcassets/                # Universal 1024x1024 app icon & accent colors
└── App/
    ├── HarnessCompanionApp.swift   # SwiftUI App entry point & URL routing
    ├── Info.plist                  # Bundle config, ATS, and Bonjour permissions
    ├── Models/                     # Swift data structures
    │   ├── HostConnection.swift    # Multi-host connection model
    │   ├── ModelProvider.swift     # MiniMax & DeepSeek models catalog
    │   ├── ChatMessage.swift       # Messages and tool call models
    │   ├── Session.swift           # Session workspace model
    │   ├── WorkspaceItem.swift     # Remote workspace models
    │   ├── ToolItem.swift          # Built-in, Composio, RAG, MCP tool items
    │   ├── ComposioModels.swift    # Composio app & action models
    │   └── FleetRAGModels.swift    # Recall hits, stats, and lesson models
    ├── Services/                   # Services & network clients
    │   ├── HostConnectionManager.swift # Multi-computer persistence & ping
    │   ├── HarnessAPIClient.swift  # Chat streaming & session orchestration
    │   ├── ComposioClient.swift    # Composio app connections & triggers
    │   └── FleetRAGClient.swift    # Fleet memory search & contribute
    └── Views/                      # SwiftUI Views
        ├── MainTabView.swift       # Tab bar: Chat, Sessions, Workspaces, Tools, Web
        ├── HostManagerSheet.swift  # Multi-computer manager & pairing modal
        ├── ChatView.swift          # Native chat interface
        ├── ComposerView.swift      # Model picker pill & prompt composer
        ├── SessionsView.swift      # Conversation history sidebar
        ├── WorkspacesView.swift    # Remote workspace directory selector
        ├── ToolsView.swift         # Tool inventory container
        ├── ComposioView.swift      # Composio connection manager
        ├── FleetRAGView.swift      # Fleet recall search & contribute UI
        ├── WebParityView.swift     # Embedded WKWebView with Harness JS/CSS
        ├── SettingsView.swift      # API keys, theme, and host defaults
        └── Components/             # Reusable UI components
            ├── ProviderBadge.swift
            ├── ReasoningBlockView.swift
            ├── ToolCallCard.swift
            └── CodeBlockView.swift
```

## Building & Running

Generate and build using the included script:

```bash
# Build for generic iOS device (arm64)
bash scripts/build-ios.sh --device

# Build for iOS Simulator
bash scripts/build-ios.sh --simulator

# Regenerate .xcodeproj manually
cd ios && xcodegen generate
```
