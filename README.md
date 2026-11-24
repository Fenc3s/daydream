# daydream

A lightweight macOS menu bar app for running custom AI commands on selected text in any app—plus clipboard history, cross-monitor window movement, and automatic input source switching.

## Download & Install

### Option 1: Download Prebuilt App (Recommended)

1. Download the latest `daydream-v*-arm64.zip` from [GitHub Releases](https://github.com/Fenc3s/daydream/releases/latest).
2. Unzip and drag `daydream.app` into `/Applications`.
3. Launch `daydream` from `/Applications`.
   - If macOS shows an unverified developer warning, right-click `daydream.app` → **Open**, or run:
     ```bash
     xattr -cr /Applications/daydream.app
     ```

### Option 2: Build from Source

Requires macOS and Xcode:

```bash
git clone https://github.com/Fenc3s/daydream.git
cd daydream
./setup-daydream-signing.command   # first time only: creates a stable local signing identity
./install-daydream.command         # builds, signs, and installs to /Applications
```

## Quick Start

1. **Grant Accessibility Permission**
   - Click the Daydream icon in the menu bar → **Grant Accessibility Permission** (or enable it in **System Settings → Privacy & Security → Accessibility**).
   - Required for capturing/replacing selected text, moving windows across monitors, and Spotlight input source detection.

2. **Connect an AI Provider**
   - Open **Settings → General** from the menu bar and choose a provider:
     - **Sign in with ChatGPT** — sign in with your ChatGPT account (no API key required).
     - **OpenRouter** — paste your OpenRouter API key (stored in macOS Keychain).
     - **DeepSeek** — paste your DeepSeek API key (stored in macOS Keychain).
   - Pick your default model and reasoning effort from **Settings** or directly from the menu bar.

3. **Use Daydream**
   - **AI Commands:** Select text in any app, press a command shortcut (or choose it from **AI Commands** in the menu bar), then copy or apply the result in place. Customize prompts, hotkeys, and models in **Settings → Commands**.
   - **Clipboard History:** Open from the menu bar (or your configured shortcut) to search and paste previous clipboard items.
   - **Move Window Across Displays:** Press `Option-Command-D` (configurable) to move the focused window to the next monitor.
   - **Auto Input Source Switching:** Set a default English layout and per-app input sources in **Settings → Input Sources**, or toggle quickly from the menu bar.
   - **Save Web Images to Photos:** Click **Install Save Image Extension…** in the menu bar to load the extension in Dia or Chrome.

## Features

- **Custom AI Commands** — custom prompts, global shortcuts, streaming result popup, in-place text replacement, and optional Obsidian note export.
- **Multiple AI Providers** — Sign in with ChatGPT, OpenRouter, and DeepSeek with per-model reasoning controls.
- **AI Memory** — automatically saves compact local context from past commands to improve future responses.
- **Clipboard History** — fast SQLite FTS5 search with automatic cleanup.
- **Window & Input Utilities** — cross-monitor window movement (including full-screen spaces), per-app & Spotlight input source switching, and browser iCloud Passwords verification helper.

## Privacy & Local Storage

Everything stays on your Mac:

- **Settings:** macOS `UserDefaults` (`~/Library/Preferences/com.daydream.app.plist`)
- **Credentials & API Keys:** macOS Keychain (`com.daydream.app`)
- **Clipboard History, Memory & Logs:** `~/Library/Application Support/daydream/`
