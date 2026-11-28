<div align="center">

<img src="assets/AppIcon.png" width="80" alt="NotesCopilot icon" />

# NotesCopilot

**Select a sentence, tap M twice, and put its translation right back where you were writing.**<br>
**Need a first draft? With no text selected, tap M twice to ask, follow up, and insert the answer at your cursor.**

A native writing tool for Apple Notes and other Mac apps. Connect your own cloud or local model.

[Download v2.12.0 for Apple silicon](https://github.com/m0nkee/notescopilot/releases/download/v2.12.0/NotesCopilot-2.12.0-arm64.dmg) · [Release notes and SHA-256](https://github.com/m0nkee/notescopilot/releases/tag/v2.12.0) · [简体中文](README.md)

</div>

## What can you do with a double M?

| What you're doing | Try this |
| --- | --- |
| **Revising a sentence** | Select a sentence in Apple Notes or a supported text field. Press `M` twice quickly, then `T` to translate. Press `R` to replace just that sentence or `A` to append the translation after it. |
| **Drafting at the cursor** | Place the cursor in an editor with no text selected. Press `M` twice, type “Draft an email confirming our meeting,” and press Return. Press `F` and ask “Make it Friday afternoon and keep the tone casual.” Press `I` on the new result to insert it at the original cursor. |
| **Reading a web page or chat reply** | Select a passage, press `M` twice, and choose Summarize, Explain, or Translate. Press `O` to switch between the original and the answer, or `C` to copy the version you're viewing. |

**Writing tools start in Apple Notes by default.** To use them in an Orca chat draft, a browser, or another app, go to **Settings → Commands & Expansion → Selection Writing Tools** and set **Scope** to **All Apps**. You can allow or exclude particular apps and pause the global tools.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/selection-launcher-dark.png">
  <img src="docs/images/selection-launcher-light.png" width="198" height="32" alt="The floating Copilot Writing Tools launcher showing the MM shortcut">
</picture>

### Working with a result

- After selecting text, press `M` twice or click the floating launcher. Choose Proofread, Polish, Shorten, Summarize, Translate, or Explain, or press `I` and type your own instruction. Translate defaults to English for Chinese text and to Simplified Chinese for other languages. For a different target, try “Translate into Japanese.”
- The actions at the bottom of the result panel share one row by default, with **Copy on the far right**. You can edit the answer before appending, replacing, or inserting it. Clicking a write action or pressing its shortcut applies it immediately. Press `G` to regenerate the current answer.
- In a custom prompt started without a selection, choose **Follow Up** to continue with the preceding questions and answers. If you edited the last answer, the follow-up uses your edited version. Press `B` to return to the instruction and start fresh.
- In Apple Notes, **Notes Formatting** also offers native headings, lists, and other formatting. Apps that support macOS text services can open the tools from **Services → Process Selected Text with NotesCopilot**. [Selection behavior and host compatibility (Chinese)](docs/WRITING-TOOLS.md)

![The result toolbar with Back to Tools, Regenerate, Append, Replace and Copy Result in one row](docs/images/selection-review.png)

## Install and try it

1. Use an **Apple silicon Mac running macOS 13 or later**. Download the DMG above, drag `NotesCopilot.app` to Applications, then open it from there. If macOS displays a security warning, see the last section.
2. Choose a model provider in Settings, enter credentials if required, and click **Save Profiles**. Supported providers include DeepSeek, Kimi, Qwen, OpenAI, OpenRouter, SiliconFlow, and custom OpenAI-compatible endpoints. You can also connect to local Ollama, LM Studio, llama.cpp, and vLLM services.
3. Enable NotesCopilot in **System Settings → Privacy & Security → Accessibility** so it can read selections and respond to the shortcut. Select a sentence in the body of an Apple Notes note and try `M`, `M`, `T`.

The menu bar provides access to the AI panel, library, and settings. In **Settings → General & Diagnostics**, test the model connection, check permissions, and choose English, Simplified Chinese, or Follow System. **Check for Updates…** in the menu bar can download a new DMG. The app verifies its SHA-256 checksum and reveals it in Finder. Automatic checks run daily by default.

## Apple Notes and menu bar features

| Feature | What it does |
| --- | --- |
| **AI panel** · `⇧⌘Space` | Chat about the current note, a selection, or an attachment. Stream answers, switch between rendered Markdown and source, read code blocks, tables, and checklists, and write rich text back to Notes. Each model has settings for temperature, output limit, and reasoning effort. The panel restores the most recent chat and keeps partial output if you stop generation. Changing the note source or model profile starts a new chat. |
| **Slash commands and text expansion** | Type `/` in Notes, filter by `/ai`, `/markdown`, `/templates`, or `/tools`, then use the arrow keys and Return to run a command. Save frequently used text as keyword expansions. |
| **Templates** | Insert reusable content from the **Templates** folder in Apple Notes or from local templates. Include dates, selected text, input prompts, and AI variables. Notes templates refresh when edited and take precedence over local templates with the same name. |
| **Note Library** | Search notes locally, filter by folder or tag, see highlighted matches, preview Markdown, and export notes. |
| **Links with page titles** | Paste a URL in Notes and type a space to turn it into a link labeled with the page title. |

![NotesCopilot model settings for cloud and local providers](docs/images/preview-magpie.png)

## Permissions and data

- **Accessibility** lets NotesCopilot read a selection, identify a writable cursor, handle shortcuts, and write back. **Automation** lets it confirm the active note and create or edit notes through Apple Events. The local library and Notes templates use **Full Disk Access** to read the Notes database.
- A model request starts when you choose a tool or submit an instruction. Selection tools send the instruction and selected text. A standalone prompt sends your question, and follow-ups include recent turns from that conversation. The main AI panel can include note content, recent conversation, or attachments depending on the context you choose. API keys are stored in local app preferences with your model profiles.
- When URL title conversion is enabled, the app visits the page to resolve its title. Shared local cookies or open browser tabs may be used as fallbacks. [User guide (Chinese)](docs/USAGE.md)

## Build from source

Use the Xcode command-line tools to build the native app. The default output is `build/NotesCopilot.app`. Set `NC_BUILD_OUTPUT` to choose another path or `NC_CODESIGN_IDENTITY` to choose a signing identity.

```bash
git clone https://github.com/m0nkee/notescopilot.git
cd notescopilot
./build.sh
scripts/run-tests.sh
scripts/check-ui.sh
scripts/check-startup.sh
```

In a graphical session with Accessibility permission, you can also check cross-app text fields, macOS Services, and the release package.

```bash
NC_TEST_INPUT_FIELDS=1 NC_TEST_SYSTEM_SERVICE=1 scripts/check-startup.sh
NC_BUILD_OUTPUT=build/release/NotesCopilot.app ./build.sh
scripts/package-dmg.sh
```

[Architecture (Chinese)](docs/ARCHITECTURE.md) · [Validation (Chinese)](docs/VALIDATION.md) · [Changelog](CHANGELOG.md) · [MIT license](LICENSE)

## Known limitations and troubleshooting

**macOS says it cannot check the app for malicious software on first launch.** The release is signed with an Apple Development certificate and has yet to receive Apple notarization. If you obtained the DMG from this project's GitHub release and its SHA-256 matches the checksum for that version, dismiss the initial alert with **Done**. Open **System Settings → Privacy & Security**, find NotesCopilot in the Security section, choose **Open Anyway**, and confirm the system prompt. This option appears after you attempt to open the app. [Apple's guide to opening apps on your Mac](https://support.apple.com/en-us/102445)

**Double M does nothing in another app.** Check that the scope is **All Apps**, that your app is allowed, and that the installed copy of NotesCopilot has Accessibility permission. A single `M` types normally. With the built-in macOS Pinyin input method, finish composing or choosing a candidate before tapping `M` twice. Secure text fields are skipped.

**I can copy the answer, but Append, Replace, or Insert is unavailable.** Read-only web pages and chat replies support reading and copying. To write, NotesCopilot must be able to verify the original editor, its contents, and the selection or cursor. Switching windows, moving the cursor, or editing the source can invalidate that target. Copy the answer, or reopen the tools at the intended position. Some custom editors expose limited information through macOS Accessibility.

**I can't see the menu bar icon.** Press `⇧⌘Space` to bring up the AI panel, or reopen NotesCopilot from Applications to restore its window.
