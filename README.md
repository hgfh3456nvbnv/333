# TermAI

A coding and operations agent for iPhone with the look and flow of a desktop coding assistant. Bring your own gateway: any OpenAI-compatible endpoint, with your base URL, API key and model IDs. The agent can run commands on your servers over SSH, read and write files in an on-device workspace, and fetch URLs.

## Install

Every push builds an unsigned IPA on GitHub Actions.

1. Open the latest **Build** run under the repository's *Actions* tab.
2. Download the `TermAI-unsigned-ipa` artifact and unzip it.
3. Sign and install `TermAI-unsigned.ipa` with your sideloading tool (AltStore, Sideloadly, TrollStore, or your own certificate).

The same run uploads a `screenshots` artifact with every screen of the app.

## Use

On first launch tap **Add connection** and fill in the gateway: base URL, API key, auth scheme (`Authorization: Bearer` or `x-api-key`), optional custom headers and the model IDs. **Test connection** checks the endpoint and **Fetch from endpoint** pulls its model list. Only the base URL is required.

The main screen is a chat:

- **Message box.** Type a task and send. While the agent works the send button becomes a stop button. `+` attaches a workspace file, imports one from the Files app or pastes the clipboard.
- **Model.** Tap the model name to search every model of every connection, or type a new model ID to add it.
- **Environment.** The chip under the message box picks the SSH host the agent works on, or *On device*.
- **Permissions.** The chip on the right picks how much the agent may do without asking (see below).
- **Sidebar.** The top-left button opens saved sessions with search, the gateway switcher and settings.
- **Files.** Browse, preview, share, import and delete workspace files, and add one to the message.
- **Terminal.** Run commands on the selected SSH host yourself. They stay out of the chat.

Slash commands still work, and typing `/` lists them:

| Input | What it does |
| --- | --- |
| plain text | send a prompt to the agent |
| `!uptime` | run a command on the selected SSH host and tell the agent the result |
| `/model [id]` | list or switch models |
| `/profile [name]` | list or switch connections |
| `/host [name\|off]` | list or switch SSH hosts |
| `/approve [ask\|edits\|plan\|auto]` | permission mode |
| `/theme [id]` | `dark`, `light`, `crt-green`, `crt-amber` |
| `/system [text\|reset]` | custom system prompt |
| `/new`, `/sessions [n]`, `/retry` | session control |
| `/copy`, `/export`, `/clear` | copy the last answer, share as Markdown, clear the screen |
| `/setup`, `/config`, `/files`, `/terminal` | open the connection editor, settings, files or terminal |

## Safety model

- **Permissions.** Four modes, switchable at any time:

  | Mode | Commands and web requests | File edits |
  | --- | --- | --- |
  | Manual (`ask`, the default) | ask | ask |
  | Accept edits (`edits`) | ask | run |
  | Plan (`plan`) | ask | refused |
  | Bypass permissions (`auto`) | run | run |

  A prompt offers *Allow*, *Always allow* (for the rest of the session) and *Deny*. Reading workspace files never asks.
- **Secrets.** API keys, custom headers, passwords and private keys are stored in the iOS Keychain (this device only). They are never written to the JSON settings files.
- **Host keys.** The first connection to a host records its key (the fingerprint is printed); later connections are refused if the key changes.
- **Workspace.** File tools are confined to the app's Documents folder, visible in Files › On My iPhone › TermAI.
- **Network.** The app talks only to the endpoints and hosts you configure. Plain-`http` endpoints are allowed for LAN servers such as Ollama; the app warns when an API key would be sent over one.

SSH private keys must be Ed25519 or RSA in OpenSSH format.

## Development

```
TermKit/            Swift package
  Sources/TermCore  models, streaming client, agent loop, tools, Markdown blocks (no UI, builds on Linux)
  Sources/TermSSH   SSH connection on top of Citadel
App/                SwiftUI app
project.yml         XcodeGen project definition
```

```sh
swift test --package-path TermKit      # unit tests (macOS or Linux)
xcodegen generate && open TermAI.xcodeproj
```

Launching with `-demo` shows sample content without touching real storage; `-screen <name>` (`empty`, `approval`, `sidebar`, `models`, `settings`, `connection`, `files`, `terminal`) and `-theme <id>` choose what is shown. CI uses this for the screenshots.

Two tests talk to real services and are skipped unless configured:

```sh
python3 TermKit/Tests/mock_server.py 8765 &
TERMAI_TEST_BASEURL=http://127.0.0.1:8765/v1 \
TERMAI_SSH_HOST=127.0.0.1 TERMAI_SSH_USER=me TERMAI_SSH_PASSWORD=… \
swift test --package-path TermKit
```
