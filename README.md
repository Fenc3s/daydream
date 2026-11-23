# daydream

`daydream` is a macOS menu bar application that allows you to run custom AI commands on selected text from any application. It's designed to be a flexible and powerful tool for people who works with selected text.

## Features

*   **Custom AI Commands:** Define your own AI commands with custom prompts and hotkeys.
*   **AI Memory:** Persist compact local memories from useful AI Command interactions, then reuse relevant memories as context in later requests.
*   **Global Text Selection:** Capture text from any application on your Mac.
*   **Cross-Monitor Window Movement:** Move the focused window of the frontmost application to the next monitor while preserving its relative position. The configurable global shortcut defaults to `Option-Command-D`.
*   **Automatic Input Source Switching:** Keep a default English keyboard layout globally—including when Spotlight opens—and automatically switch to configured input sources when activating specific applications or closing Spotlight. Standard app switching requires no permissions; Spotlight detection uses zero-polling Accessibility observation.
*   **Version Visibility:** See the installed app version in the menu bar menu and browse Git commit history from Settings.
*   **AI Model Integration:** Powered by a configurable OpenAI-compatible backend or OpenRouter.
*   **In-Place Text Replacement:** Replace the selected text with the AI-generated output.
*   **Selection Restore:** AI Commands remember the captured accessibility selection range and make a best-effort attempt to restore it before applying results.
*   **Result Popup:** View AI-generated text in a convenient popup window.
*   **Clipboard Integration:** Automatically copy AI-generated text to the clipboard.
*   **Clipboard History:** Browse previous clipboard items; paste into external apps or daydream's own windows; pasting the selected item or double-clicking an item promotes it to the top as the latest used clipboard entry.
*   **Settings and Diagnostics:** Configure the application and view diagnostic information through dedicated windows.

## How It Works

1.  **Define Commands:** Create custom AI commands in the app's settings. Each command has a title, a prompt, and an optional hotkey.
2.  **Select Text:** Highlight text in any application.
3.  **Trigger Command:** Press the command's hotkey or select it from the menu bar.
4.  **Get AI Output:** The app sends the selected text to the configured AI model with your custom prompt.
5.  **View and Use:** The AI-generated text appears in a popup window. You can then copy it to the clipboard or replace the original selection.

**Sync with iCloud** is enabled by default. Its preference stays local to each Mac, while settings and commands are stored under iCloud Drive `Documents/daydream` when synchronization is enabled.

AI Memory stores compact summaries locally at `~/Library/Application Support/daydream/memory.json`. Successful AI Commands can refresh memories; later commands retrieve matching context. The **Memory** settings page supports search, manual edits, entry limits, and deletion.

AI Chats has been removed, including its window, menu, global shortcut, settings, tool execution, and history synchronization. Existing conversation history files and legacy settings are preserved on disk for compatibility and are no longer loaded or written by Daydream.

## Getting Started

### Prerequisites

*   macOS
*   Xcode

### Building and Running

1.  Clone the repository:
    ```bash
    git clone https://github.com/your-username/daydream.git
    ```
2.  Open the project in Xcode:
    ```bash
    open daydream/daydream.xcodeproj
    ```
3.  Build and run the application from Xcode.

To build a Release application and install it in `/Applications`, run:

```bash
./install-daydream.command
```

Before the first Release installation, configure the shared local signing identity:

```bash
./setup-daydream-signing.command
```

On the first Mac, the setup command creates a long-lived local code-signing identity and an encrypted archive under `.daydream-signing/`. The archive is ignored by Git but follows the source folder when it is synchronized through iCloud Drive. Wait for that folder to finish syncing, then run the same setup command on the second Mac to import the identical certificate and private key. The archive password is requested interactively and is never stored in the repository or scripts.

Each Mac must grant Accessibility access once after switching from an old ad-hoc build to the shared signing identity. Future local builds retain a stable designated requirement, so rebuilding the app does not normally require removing and granting Accessibility access again. Accessibility consent remains local to each Mac and is never modified by these scripts.

Daydream waits for an iCloud Passwords plugin activation in Dia, Google Chrome, or Google Chrome Canary and completes verification in the browser that initiated it. It does not automatically open the extension when a browser launches, and no separate manual Daydream command is required. Daydream does not monitor profile switches or poll supported browsers while idle. The automation uses the existing Daydream Accessibility permission and never stores or logs verification codes. Its preference is local to each Mac and is not synchronized through iCloud.

The menu bar command **Install Save Image Extension…** reveals the bundled unpacked extension and opens the extension management page in each installed supported browser. Enable developer mode and load the revealed folder in Dia or Google Chrome to add the **Save Image to Photos** image context-menu command. Daydream registers the required native messaging host for both browsers.

The installation script automatically locates a complete Xcode installation, builds the `daydream` scheme without Xcode's per-machine signing state, signs the completed application with the shared identity, verifies that its designated requirement is stable, closes a running copy of the app, installs the successful build as `/Applications/daydream.app`, and opens the newly installed application. Installation stops with setup instructions instead of falling back to ad-hoc signing when the identity is unavailable.

After launch, the installation script also runs `verify-daydream-idle.command`. The check waits for startup to settle, samples the Daydream process, and fails when average idle CPU exceeds 2.5%. Override `DAYDREAM_IDLE_CPU_LIMIT`, `DAYDREAM_IDLE_SAMPLE_COUNT`, or `DAYDREAM_IDLE_SAMPLE_INTERVAL` when a different local verification window is required.

Result and Clipboard History panels release their hosted SwiftUI content when dismissed. Result panels retain their hosting controller for the full visible lifetime, use a single full-screen-safe ordering operation, and defer teardown until AppKit finishes the current window event. Settings uses the native SwiftUI settings scene, and hidden application windows disable mouse tracking so closed windows do not continue generating AppKit tracking-region work.

### Required Post-Change Workflow

After completing any source code or Xcode project configuration change, run the following command as the final verification step:

```bash
./install-daydream.command
```

Any project change is considered complete only after this script successfully builds the Release application and installs it in `/Applications`.

Before creating each Git commit, update both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for every build configuration in the Xcode project. Every commit must include a version change so the installed application can be distinguished from the previous build. Increment the patch component and build number for routine changes; use an appropriate minor or major version increase for larger releases.

After the build and installation succeed, every project change must be committed to Git. Review the final diff, stage the intended files, and create a commit with a detailed subject and body that explain the completed behavior, important implementation details, migrations, and operational changes. Work is not considered complete while changes remain uncommitted.

### API Configuration

The app supports three provider modes in Settings:

*   **OpenAI-Compatible:** Connects to `https://api.openai.com/v1` or any OpenAI-compatible API endpoint (such as Ollama, LiteLLM, or a custom proxy) using an API key stored in macOS Keychain.
*   **OpenRouter:** Uses OpenRouter's chat completions API and supports a custom OpenRouter base URL plus API key.
*   **DeepSeek:** Uses the DeepSeek API with provider-specific thinking and effort fields.

## Core Components

*   `daydreamApp.swift`: The main entry point of the application, defining the menu bar extra and windows.
*   `AppModel.swift`: The core of the application, managing state, settings, and command execution.
*   **Services:**
    *   `AIClient.swift`: Handles communication with the AI backend.
    *   `MemoryStore.swift`: Persists compact local AI memories for commands.
    *   `SelectionService.swift`: Captures text selection from other applications.
    *   `ReplaceService.swift`: Replaces selected text with AI output.
    *   `HotKeyService.swift`: Manages global hotkey registrations.
    *   `InputSourceSwitchingService.swift`: Observes active applications and Spotlight overlays and switches keyboard input sources via Carbon Text Input Sources.
    *   `SettingsStore.swift`: Manages application settings.
*   **Views:**
    *   `MenuBarView.swift`: The view for the menu bar extra.
    *   `SettingsRootView.swift`: The main view for the settings window.
    *   `InputSourceSettingsView.swift`: Configures automatic input source switching and per-application rules.
    *   `ResultPopupView.swift`: The view for displaying AI-generated text.

### Model discovery and reasoning

Settings → General automatically discovers models from the selected provider at launch and when switching providers. Use **Refresh Models** after editing the connection, search the available catalog, and select **Add** to enable models for commands. Existing enabled models remain available if discovery fails. You can also add a model ID manually and select the default model from the dropdown.

AI Commands expose model-specific reasoning levels in their editor. **Auto** omits reasoning overrides and uses the provider default; it does not disable thinking. Manual definitions take priority over provider model metadata. OpenAI-Compatible endpoints check missing or expired capability entries during model refresh; entries without a successful verification offer Auto only. Model-specific effort lists are stored in settings, not hardcoded in the application.

Run `python3 tests/run-provider-tests.py` to validate settings decoding, reasoning capability selection, and 24 real client HTTP payloads against a local test server.

### Define reasoning efforts for a model

Open **Settings → General → [Provider] Models**, then click **Reasoning…** beside an enabled model. Select **Manual**, check the efforts you want to offer (None, Minimal, Low, Medium, High, Extra High, Max), and click **Save**. The definition is saved separately for each provider and model and takes effect in the menu bar and AI Command editor. Auto is always available; an empty manual selection offers Auto only. A previously selected effort that is no longer allowed falls back to Auto when submitting a request.

Choose **Automatic (catalog + verified cache)** and save to remove the manual definition and return to provider metadata. Refreshing the model catalog preserves manual definitions. New and manually added models use the same editor, so adding reasoning support does not require a code change. Manual definitions control the available choices; they do not change which parameters a provider accepts.

### Default reasoning linked to the default model

**Settings → General → Default Reasoning** sets the default effort for the currently selected **Default Model**. Each provider/model pair retains its own default, so switching models restores that model's effort. Choices come from the model's manual effort definition or provider catalog. Removing an allowed effort makes an unavailable default fall back to Auto.

AI Commands can enable **Use default reasoning** to inherit their effective model's default, including when the command overrides the default model. Turn the toggle off to configure that command separately. Existing commands inherit after the one-time migration described below; new commands inherit by default, and later explicit overrides are preserved. Each enabled model row displays its own available efforts and their source.

The menu bar places **Reasoning: [effort]** directly below **Model**. Its choices come from the current default model's effort definition, the active choice has a checkmark, and selecting an effort updates the same per-model default used by **Settings → General → Default Reasoning**. Switching the menu bar model restores that model's own default effort.

### Reasoning discovery during model refresh

**Refresh Models** updates the model list and its reasoning capabilities together. Provider-reported metadata takes priority over automatically verified results; manual definitions take priority over both. When an OpenAI-compatible catalog omits effort metadata, the application checks models with missing or expired entries in the background. Successful results are cached for seven days in the independent local file `~/Library/Application Support/daydream/verified-reasoning.json`; inconclusive or unavailable results expire after 15 minutes and survive restarts and catalog refreshes. The settings page shows progress during new checks.

Discovery sends synthetic, bounded streaming requests with no user text. It requires a successful baseline, rejection of an invalid effort, and a completed text answer for each enabled effort. Regional restrictions, unavailable routes, ignored parameters, and media responses remain explicitly unverified. Accepted API effort values may be aliases for the same native thinking tier; they are not presented as measured compute budgets. No model-specific effort list is embedded in Swift code.

The automatic capability cache is independent of iCloud settings. Older application versions that rewrite synchronized settings cannot erase the local verification results, and menu choices remain available from a fresh local or bundled snapshot even if catalog refresh fails. Manual definitions and default effort preferences continue to use the normal settings store.

### Remember reasoning when switching models

The menu bar and General settings remember a separate default reasoning choice for each provider/model pair. Choosing Low for model A and High for model B restores Low when switching back to A, including after restarting the application. New models without a saved selection start with Auto.

Explicit choices are saved to `~/Library/Application Support/daydream/model-reasoning-preferences.json` as well as normal settings. This Mac's saved choice takes priority over an omitted or older value in iCloud settings; synced choices for models without a local selection are imported. Selecting Auto explicitly updates the saved preference. A temporarily missing capability only changes the effective mode to Auto and does not erase the remembered choice.

### Command feedback

Commands with result popups enabled open a processing window before capturing the selection or sending the request. The window initially leaves keyboard focus in the source application, displays progress while waiting, and enables Apply only after output exists. Closing the processing window does not reopen it when text arrives. Capture or request failures close the pending window before using the normal error alert.

On the first launch of this version, existing AI Commands enable **Use default reasoning**, so the menu bar's selected model effort applies to them. This is a one-time migration on each Mac; subsequent explicit per-command overrides are preserved. Each submitted command retains its initial model, provider, and effort for the request. Millisecond command logs separate processing-window presentation, selection readiness, first visible output, and completion.

The per-command inheritance choice is also stored locally in `command-reasoning-preferences.json`, protecting both the migration and later explicit overrides from stale iCloud updates.

### Explicit None effort

**None** sends the explicit `none` effort. It is distinct from **Auto**, which omits the override, and **Off**, which uses a provider-specific disable flag. None is offered only when the model catalog reports it, streaming discovery accepts it after positive and negative controls, or a manual definition enables it. Settings, command editors, and the menu bar share the same per-model capability list. Manual definitions remain authoritative.

Fetch includes None in its automatic probes. Capability caches carry a discovery version; older snapshots that never tested None are refreshed even if their timestamp is recent. Missing effort metadata does not imply support for every effort. Confirmed results retain the existing seven-day cache, while inconclusive checks retain the shorter retry interval.



### Automatic input source switching

**Settings → Input Sources** maintains a global default English keyboard layout and switches automatically to per-application input sources when an external regular application becomes active. Standard application switching uses macOS Carbon Text Input Source APIs alongside `NSWorkspace` activation notifications, requires no Accessibility permission, and incurs zero idle polling cost.

When Accessibility permission is granted, Daydream also observes Spotlight overlays (`com.apple.Spotlight`) using event-driven `AXObserver` notifications with zero idle polling—switching to your default English layout (or a custom **Spotlight** rule added under **Application Rules**) when Spotlight opens, and restoring the active application's input source when Spotlight closes. For best results, keep macOS's **Automatically switch to a document's input source** turned off in **System Settings → Keyboard**.

Use the **Input Sources** menu item in the menu bar to quickly toggle automatic switching or jump directly to **Configure App Rules…**. Whether automatic switching is enabled is stored locally per Mac in `local-preferences.json`, while the preferred default English source and per-application rules sync across Macs through iCloud Drive when **Sync with iCloud** is enabled. If a synced input source is not enabled on the current Mac, Settings flags the rule as unavailable without removing it.

### Version history

**2.1.0 (52) · 2026-11-20**

* Added per-app input source rules and a menu bar toggle.
* Added the `{{app_name}}`, `{{clipboard}}`, and `{{date}}` prompt variables and optional Markdown output to an Obsidian vault.
* Moved provider API keys to the local macOS Keychain. Each Mac uses its own Keychain entries.
* Improved clipboard-history search and capture, model reasoning discovery, and diagnostic logging. Existing AI commands inherit their model's reasoning setting after a one-time migration.

To roll back, quit Daydream and restore the backed-up signed app. Use the pre-upgrade settings and clipboard database snapshot if you also need to reverse the data migration. Older builds read API keys from their settings files.
