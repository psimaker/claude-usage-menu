# Claude Usage Systray

A lightweight macOS menu bar app that shows your [Claude.ai](https://claude.ai) plan usage in real time — current session and weekly limits — without opening a browser.

![Claude Usage Systray](claude-usage-systray/Resources/Assets.xcassets/Image.imageset/Image.png)

## What it shows

Mirrors the data on `claude.ai/settings/usage`:

| Metric | Description |
|--------|-------------|
| **5h** | Current session usage (resets every ~5 hours) |
| **7d** | Weekly all-models usage |
| **Sonnet** | Weekly Sonnet-only usage (shown in popover) |

Colors update based on your configured warning/critical thresholds.

## Requirements

- macOS 13+
- [Claude Code](https://claude.ai/code) installed and logged in (the app reads its OAuth token from your Keychain — no separate credentials needed)

## Install

**Homebrew (recommended):**

```bash
brew tap adntgv/tap
brew install --cask claude-usage-systray
```

**Manual:**

Download the latest `ClaudeUsageSystray.zip` from the [Releases page](https://github.com/adntgv/claude-usage-systray/releases), unzip, and move `ClaudeUsageSystray.app` to `/Applications`. The app is notarized — macOS will open it normally on first launch.

## Build from source

```bash
git clone https://github.com/adntgv/claude-usage-systray
cd claude-usage-systray/claude-usage-systray
xcodebuild -scheme ClaudeUsageSystray -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/ClaudeUsageSystray-*/Build/Products/Release/ClaudeUsageSystray.app
```

Or open `ClaudeUsageSystray.xcodeproj` in Xcode and run with ⌘R.

## Display modes

Toggle **Compact mode** in Settings to switch between:

- **Labeled (default):** a two-column layout — `5h Limit` with its percentage on the
  left and `Weekly Limit` with its percentage on the right, each colored by threshold
- **Compact:** `35% · 71%` — both percentages inline, for tight menu bars

Both adapt to light/dark menu bars, and the percentages turn orange/red as they
cross your warning/critical thresholds. Before the first successful fetch (or while
signed out) the values show `—` and the tooltip explains why.

## How it works

The app reads your Claude Code OAuth token from the macOS Keychain (`Claude Code-credentials`) and calls the same internal endpoint that powers `claude.ai/settings/usage`:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth_token>
anthropic-beta: oauth-2025-04-20
```

The token is read from the Keychain and cached in memory until shortly before it
expires, then re-read automatically — and also re-read if a request comes back
unauthorized — so a token Claude Code has refreshed is picked up without restarting
the app. Requests use a 30s timeout and back off on rate limits and transient errors.

> **Note:** This endpoint is undocumented and may change. It requires Claude Code to be installed and logged in.

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Compact mode | Off | On = inline `5h% · 7d%`; Off = labeled two-column layout |
| Warning threshold | 80% | Orange color above this |
| Critical threshold | 90% | Red color above this |
| Usage alerts | On | macOS notification when thresholds are crossed (once per period) |

## Running tests

```bash
xcodebuild test -project ClaudeUsageSystray.xcodeproj \
  -scheme ClaudeUsageSystrayTests \
  -destination 'platform=macOS'
```

## License

MIT
