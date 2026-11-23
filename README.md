# daydream

`daydream` is a macOS menu bar application that allows you to run custom AI commands on selected text from any application. It's designed to be a flexible and powerful tool for people who work with selected text.

## Features

*   **Custom AI Commands:** Define your own AI commands with custom prompts and hotkeys.
*   **AI Memory:** Persist compact local memories from useful AI Command interactions, then reuse relevant memories as context in later requests.
*   **Global Text Selection:** Capture text from any application on your Mac.
*   **Cross-Monitor Window Movement:** Move the focused window of the frontmost application to the next monitor while preserving its relative position, including asynchronous handling for full-screen spaces. The configurable global shortcut defaults to `Option-Command-D`.
*   **Automatic Input Source Switching:** Keep a default English keyboard layout globally—including when Spotlight opens—and automatically switch to configured input sources when activating specific applications or closing Spotlight. Standard app switching requires no permissions; Spotlight detection uses zero-polling Accessibility observation.
*   **Version Visibility:** See the installed app version in the menu bar menu and browse Git commit history from Settings.
*   **AI Model Integration:** Powered by OpenRouter and DeepSeek, with configurable base URLs, Keychain-backed API keys, and per-model reasoning controls.
*   **In-Place Text Replacement:** Replace the selected text with the AI-generated output.
*   **Selection Restore:** AI Commands remember the captured accessibility selection range and make a best-effort attempt to restore it before applying results.
*   **Result Popup:** View AI-generated text in a convenient popup window.
*   **Clipboard Integration:** Automatically copy AI-generated text to the clipboard.
*   **Clipboard History:** Browse previous clipboard items backed by SQLite FTS5; paste into external apps or daydream's own windows; pasting or double-clicking an item promotes it to the top as the latest used entry. Orphaned payloads are automatically pruned and vacuumed.
*   **Settings and Diagnostics:** Configure the application and view diagnostic information through dedicated windows.

## How It Works

1.  **Define Commands:** Create custom AI commands in the app's settings. Each command has a title, a prompt, and an optional hotkey.
2.  **Select Text:** Highlight text in any application.
3.  **Trigger Command:** Press the command's hotkey or select it from the menu bar.
4.  **Get AI Output:** The app sends the selected text to the configured AI model with your custom prompt.
5.  **View and Use:** The AI-generated text appears in a popup window. You can then copy it to the clipboard or replace the original selection.

### Local Storage & Privacy

*   **Settings:** Stored locally in macOS `UserDefaults` (`~/Library/Preferences/Homer.daydream.plist`). Legacy JSON settings files from older versions under `~/Library/Application Support/daydream/` are migrated automatically on first launch and cleaned up afterward.
*   **API Keys:** Stored securely in the local macOS Keychain (service `Homer.daydream`) and never written in plaintext to preferences.
*   **Runtime Data:** Clipboard history (`clipboard-history.sqlite`), AI Memory (`memory.json`), and diagnostic logs (`Logs/`) are stored locally under `~/Library/Application Support/daydream/`.

AI Memory stores compact summaries locally at `~/Library/Application Support/daydream/memory.json`. Successful AI Commands can refresh memories; later commands retrieve matching context. The **Memory** settings page supports search, manual edits, entry limits, and deletion.

## Getting Started

### Prerequisites

*   macOS
*   Xcode
*   GitHub CLI (`gh`, optional, used by `install-daydream.command` to publish GitHub Releases)

### Building and Running

1.  Clone the repository:
    ```bash
    git clone https://github.com/Fenc3s/daydream.git
    ```
2.  Open the project in Xcode:
    ```bash
    open daydream.xcodeproj
    ```
3.  Build and run the application from Xcode.

To build a Release application, install it in `/Applications`, and publish a GitHub Release, run:

```bash
./install-daydream.command
```

Before the first Release installation, configure the shared local signing identity:

```bash
./setup-daydream-signing.command
```

On the first Mac, the setup command creates a long-lived local code-signing identity and an encrypted archive under `.daydream-signing/`. The archive is ignored by Git. Run the same setup command on another Mac to import the identical certificate and private key. The archive password is requested interactively and is never stored in the repository or scripts.

Each Mac must grant Accessibility access once after switching from an old ad-hoc build to the shared signing identity. Future local builds retain a stable designated requirement, so rebuilding the app does not normally require removing and granting Accessibility access again. Accessibility consent remains local to each Mac and is never modified by these scripts.

Daydream waits for an iCloud Passwords plugin activation in Dia, Google Chrome, or Google Chrome Canary and completes verification in the browser that initiated it. It does not automatically open the extension when a browser launches, and no separate manual Daydream command is required. Daydream does not monitor profile switches or poll supported browsers while idle. The automation uses the existing Daydream Accessibility permission and never stores or logs verification codes.

The menu bar command **Install Save Image Extension…** reveals the bundled unpacked extension and opens the extension management page in each installed supported browser. Enable developer mode and load the revealed folder in Dia or Google Chrome to add the **Save Image to Photos** image context-menu command. Daydream registers the required native messaging host for both browsers.

### Automated Build, Version Bump & Release (`install-daydream.command`)

Running `./install-daydream.command` automatically:

1.  Increments `MARKETING_VERSION` (patch `+1`) and `CURRENT_PROJECT_VERSION` (`+1`) in `daydream.xcodeproj/project.pbxproj` before compiling (rolling back `project.pbxproj` automatically if the build fails).
2.  Locates a complete Xcode installation, builds the `daydream` scheme in Release configuration, signs the app with the shared local identity, and verifies that its designated requirement is stable (never falling back to ad-hoc signing).
3.  Closes any running copy of `daydream`, installs the new build to `/Applications/daydream.app`, verifies the installed signature, and launches the app.
4.  Runs `verify-daydream-idle.command`, which samples the running process after startup settles and fails if average idle CPU exceeds `2.5%` (configurable via `DAYDREAM_IDLE_CPU_LIMIT`, `DAYDREAM_IDLE_SAMPLE_COUNT`, and `DAYDREAM_IDLE_SAMPLE_INTERVAL`).
5.  Commits and pushes the version bump in `daydream.xcodeproj/project.pbxproj`, packages `/Applications/daydream.app` into `daydream-<tag>-<arch>.zip`, and creates a GitHub Release via `gh release create` with auto-generated release notes.

Optional environment overrides:

*   `DAYDREAM_VERSION=2.2.0` — set an explicit marketing version instead of auto-incrementing the patch number.
*   `DAYDREAM_SKIP_BUMP=1` — build without modifying `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION`.
*   `DAYDREAM_SKIP_RELEASE=1` — install locally without committing the bump or publishing a GitHub Release.

Result and Clipboard History panels release their hosted SwiftUI content when dismissed. Result panels retain their hosting controller for the full visible lifetime, use a single full-screen-safe ordering operation, and defer teardown until AppKit finishes the current window event. Settings uses the native SwiftUI settings scene, and hidden application windows disable mouse tracking so closed windows do not continue generating AppKit tracking-region work.

### Required Post-Change Workflow

After completing any source code or Xcode project configuration change:

1.  Run the test suite:
    ```bash
    python3 tests/run-provider-tests.py
    ```
2.  Commit your source changes to Git.
3.  Run the build, install, and release script:
    ```bash
    ./install-daydream.command
    ```

### API Configuration

The app supports two provider modes in **Settings → General**:

*   **OpenRouter** *(default)*: Uses OpenRouter's chat completions API (`https://openrouter.ai/api/v1`) and supports a custom base URL plus an API key stored in macOS Keychain.
*   **DeepSeek**: Uses the DeepSeek API (`https://api.deepseek.com`) with provider-specific thinking and effort fields and an API key stored in macOS Keychain.

## Core Components

*   `daydreamApp.swift`: The main entry point of the application, defining the menu bar extra and windows.
*   `AppModel.swift`: The core of the application, managing state, settings, and command execution.
*   **Services:**
    *   `AIClient.swift`: Handles communication with OpenRouter and DeepSeek backends (streaming and non-streaming).
    *   `SettingsStore.swift`: Persists application settings in `UserDefaults` (`Homer.daydream.plist`) with automatic legacy JSON migration and Keychain credential storage.
    *   `KeychainStore.swift`: Stores and retrieves provider API keys in macOS Keychain.
    *   `ClipboardHistoryStore.swift`: SQLite FTS5 clipboard history store with automatic orphan payload cleanup and `VACUUM`.
    *   `MemoryStore.swift`: Persists compact local AI memories for commands.
    *   `SelectionService.swift`: Captures text selection from other applications.
    *   `ReplaceService.swift`: Replaces selected text with AI output.
    *   `HotKeyService.swift`: Manages global hotkey registrations.
    *   `WindowMoverService.swift`: Moves focused windows across displays, including full-screen spaces.
    *   `InputSourceSwitchingService.swift`: Observes active applications and Spotlight overlays and switches keyboard input sources via Carbon Text Input Sources.
*   **Views:**
    *   `MenuBarView.swift`: The view for the menu bar extra.
    *   `SettingsRootView.swift`: The main view for the settings window.
    *   `InputSourceSettingsView.swift`: Configures automatic input source switching and per-application rules.
    *   `ResultPopupView.swift`: The view for displaying AI-generated text.
    *   `DiagnosticsWindowView.swift`: Displays runtime status, settings plist path, logs, and Git version history.

### Model Discovery and Reasoning

**Settings → General** automatically discovers models from the selected provider at launch and when switching providers. Use **Refresh Models** after editing the connection, search the available catalog, and select **Add** to enable models for commands. Existing enabled models remain available if discovery fails. You can also add a model ID manually and select the default model from the dropdown.

AI Commands expose model-specific reasoning levels in their editor. **Auto** omits reasoning overrides and uses the provider default; it does not disable thinking. Manual definitions take priority over provider model metadata. Model-specific effort lists are stored in settings, not hardcoded in the application.

Run `python3 tests/run-provider-tests.py` to validate settings decoding, `UserDefaults` migration, Keychain storage, SQLite FTS5 clipboard history, Obsidian export, input source switching, window moving, and 16 real client HTTP payloads (2 providers × 4 efforts × streaming/non-streaming) against a local test server.

### Define Reasoning Efforts for a Model

Open **Settings → General → [Provider] Models**, then click **Reasoning…** beside an enabled model. Select **Manual**, check the efforts you want to offer (`None`, `Minimal`, `Low`, `Medium`, `High`, `Extra High`, `Max`), and click **Save**. The definition is saved separately for each provider and model and takes effect in the menu bar and AI Command editor. `Auto` is always available; an empty manual selection offers `Auto` only. A previously selected effort that is no longer allowed falls back to `Auto` when submitting a request.

Choose **Automatic** and save to remove the manual definition and return to provider catalog metadata. Refreshing the model catalog preserves manual definitions.

### Default Reasoning Linked to the Default Model

**Settings → General → Default Reasoning** sets the default effort for the currently selected **Default Model**. Each provider/model pair retains its own default, so switching models restores that model's effort. Choices come from the model's manual effort definition or provider catalog. Removing an allowed effort makes an unavailable default fall back to `Auto`.

AI Commands can enable **Use default reasoning** to inherit their effective model's default, including when the command overrides the default model. Turn the toggle off to configure that command separately. New commands inherit by default, and explicit overrides are preserved.

The menu bar places **Reasoning: [effort]** directly below **Model**. Its choices come from the current default model's effort definition, the active choice has a checkmark, and selecting an effort updates the same per-model default used by **Settings → General → Default Reasoning**. Switching the menu bar model restores that model's own default effort.

### Explicit None Effort

**None** sends the explicit `none` effort. It is distinct from **Auto**, which omits the override, and **Off**, which uses a provider-specific disable flag. `None` is offered only when the provider model catalog reports it or a manual definition enables it. Settings, command editors, and the menu bar share the same per-model capability list.

### Command Feedback

Commands with result popups enabled open a processing window before capturing the selection or sending the request. The window initially leaves keyboard focus in the source application, displays progress while waiting, and enables **Apply** only after output exists. Closing the processing window does not reopen it when text arrives. Capture or request failures close the pending window before using the normal error alert.

### Automatic Input Source Switching

**Settings → Input Sources** maintains a global default English keyboard layout and switches automatically to per-application input sources when an external regular application becomes active. Standard application switching uses macOS Carbon Text Input Source APIs alongside `NSWorkspace` activation notifications, requires no Accessibility permission, and incurs zero idle polling cost.

When Accessibility permission is granted, Daydream also observes Spotlight overlays (`com.apple.Spotlight`) using event-driven `AXObserver` notifications with zero idle polling—switching to your default English layout (or a custom **Spotlight** rule added under **Application Rules**) when Spotlight opens, and restoring the active application's input source when Spotlight closes. For best results, keep macOS's **Automatically switch to a document's input source** turned off in **System Settings → Keyboard**.

Use the **Input Sources** menu item in the menu bar to quickly toggle automatic switching or jump directly to **Configure App Rules…**. All input source preferences and per-application rules are stored locally in `UserDefaults`. If a saved input source is not installed or enabled on the current Mac, Settings flags the rule as unavailable without removing it.

### Version History

**2.1.1 (54) · 2026-11-23**

*   Migrated application settings from `Application Support/daydream/*.json` to native macOS `UserDefaults` (`~/Library/Preferences/Homer.daydream.plist`) with automatic one-time migration and legacy JSON cleanup.
*   Removed iCloud settings sync (`ICloudSyncService`) and the `OpenAI-Compatible` provider; OpenRouter is now the default provider alongside DeepSeek, with seamless migration for existing configs.
*   Removed unused `ReasoningCapabilityDiscovery` code and `VerifiedReasoningCapabilities.json`.
*   Added automatic orphan payload cleanup and `VACUUM` + WAL checkpointing to `ClipboardHistoryStore` to prevent SQLite bloat.
*   Updated `install-daydream.command` to automatically bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, push the version commit, and publish a GitHub Release with the packaged app archive.

**2.1.0 (52) · 2026-11-20**

*   Added per-app input source rules and a menu bar toggle.
*   Added the `{{app_name}}`, `{{clipboard}}`, and `{{date}}` prompt variables and optional Markdown output to an Obsidian vault.
*   Moved provider API keys to the local macOS Keychain. Each Mac uses its own Keychain entries.
*   Improved clipboard-history search and capture, model reasoning discovery, and diagnostic logging. Existing AI commands inherit their model's reasoning setting after a one-time migration.
