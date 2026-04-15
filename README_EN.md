# iOS MCP

[中文](README.md) | English

iOS MCP is an [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server that runs on jailbroken iPhones, enabling AI agents (Claude, Codex, Cursor, etc.) to directly control iOS devices.

## Features

| Category | Tools | Description |
|----------|-------|-------------|
| **Touch** | `tap_screen` `swipe_screen` `long_press` `double_tap` `drag_and_drop` | Precise screen coordinate operations |
| **Buttons** | `press_home` `press_power` `press_volume_up` `press_volume_down` `toggle_mute` | HID physical button simulation |
| **Text Input** | `input_text` `type_text` `press_key` | Pasteboard fast input / HID character-by-character / special keys |
| **Screenshot** | `screenshot` `get_screen_info` | Base64 JPEG screenshot, screen dimensions & orientation |
| **App Management** | `launch_app` `kill_app` `list_apps` `list_running_apps` `get_frontmost_app` `install_app` `uninstall_app` | Launch/kill/install/uninstall apps |
| **Accessibility** | `get_ui_elements` `get_element_at_point` | UI element tree, element lookup by coordinates |
| **Clipboard** | `get_clipboard` `set_clipboard` | Read/write clipboard |
| **Device Control** | `get_brightness` `set_brightness` `get_volume` `set_volume` | Brightness and volume |
| **Device Info** | `get_device_info` | Model, iOS version, battery, storage, memory |
| **URL** | `open_url` | Open URLs or URL schemes |
| **Shell** | `run_command` | Execute shell commands |

**33** MCP tools covering the major iOS device automation scenarios.

## Runtime Requirements

- Jailbroken iOS device

## Installation

### Supported Environments

| Jailbreak Type | Supported iOS Versions | Package Architecture |
|------|------|------|
| `rootful` | iOS 13 - iOS 18 | `iphoneos-arm` |
| `rootless` | iOS 15 - iOS 18 | `iphoneos-arm64` |
| `roothide` | iOS 15 - iOS 18 | `iphoneos-arm64e` |

### Installation Methods

#### Method 1: Download a package from the Release page

Choose the `.deb` package that matches the architecture listed in the table above.

For manual installation, make sure these dependencies are present:

- `mobilesubstrate/ElleKit`
- `preferenceloader`

#### Method 2: Install directly from Cydia / Sileo

You can also search and install directly from:

- `Cydia`
- `Sileo`

Package name:

- `iOS MCP`

### Recommended checks after installation

1. Restart `SpringBoard`
2. Open the following URL in a browser:

```text
http://DEVICE_IP:8090/health
```

3. If you get the following response, the service is running correctly:

```json
{"status":"ok","server":"ios-mcp","version":"1.0.0"}
```

## Usage

After installation, open **Settings** → **iOS MCP** on your device. Start the server, then tap "Copy MCP Prompt Snippet" and paste it into your AI agent's prompt.

<p align="center">
  <img src="screenshots/settings.jpeg" alt="iOS MCP Settings" width="300">
</p>

## Security Notes

- The MCP server has no built-in authentication — it is recommended to use it only on local networks
- The `run_command` tool can execute arbitrary shell commands — use with caution
- `mcp-root` provides root privilege elevation, intended for internal use only

## Author

**witchan**

## License

MIT License
