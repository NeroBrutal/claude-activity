# Claude Activity

A tiny macOS menu bar app and desktop widget that shows what [Claude Code](https://claude.com/claude-code) has been doing for you: sessions, prompts, files edited, and when you work with it.

It reads the session history Claude Code already keeps on your Mac. Nothing is sent anywhere.

<!-- Add screenshots here: docs/popover.png, docs/analyze.png, docs/widget.png -->

## Features

**Menu bar popover** (click ✨ or press **⌥⌘C**)
- Sessions grouped by day, each with its AI-generated title, project, last prompt, and counts of prompts, files edited and tool calls
- Today / 7 Days / 30 Days filter and summary tiles
- Click a session to open its project folder in Finder

**Analyze tab**
- Prompts per day (14 days)
- What time of day you work with Claude
- Project breakdown by prompts and files
- Insights: busiest day, peak hour, average prompts per session, biggest session, total tool calls, unique files edited

**Desktop widget**
- Translucent card that sits on your desktop, behind your windows, on every Space
- **Medium** (2×1) and **Large** (2×2) sizes, matching the native macOS widget sizes
- Snaps to the same 180pt grid as the built-in macOS desktop widgets when you drop it, and skips cells other widgets already occupy
- Refreshes every minute. Right-click for Refresh, Size, Open, or Hide

**Also:** optional launch at login, and it runs as a menu bar app only (no Dock icon).

## Requirements

- macOS 14 (Sonoma) or later
- Xcode **Command Line Tools** (full Xcode is *not* needed): `xcode-select --install`
- [Claude Code](https://claude.com/claude-code) installed and used at least once, so `~/.claude/projects` exists

## Install

```bash
git clone https://github.com/<your-username>/claude-activity.git
cd claude-activity
bash build.sh
open ~/Applications/"Claude Activity.app"
```

`build.sh` compiles `main.swift` with `swiftc`, wraps it in an app bundle, ad-hoc signs it, and installs it to `~/Applications`. Because you build it yourself, macOS won't show an "unidentified developer" warning.

To update, `git pull` and run `bash build.sh` again.

## Usage

| Action | How |
| --- | --- |
| Open the popover | Click ✨ in the menu bar, or press **⌥⌘C** |
| Switch list / analytics | Icons at the top right of the popover |
| Show or hide the desktop widget | **Desktop widget** switch at the bottom of the popover, or right-click the widget → Hide |
| Resize the widget | Right-click the widget → **Size** → Medium / Large |
| Move the widget | Drag it; it glides to the nearest free grid cell when you let go |
| Start at login | **Login** switch at the bottom of the popover |
| Quit | **Quit** at the bottom of the popover |

## How it works

Claude Code writes one `.jsonl` file per session under `~/.claude/projects/<project>/`. Claude Activity scans the files modified in the last 30 days (newest 80) and pulls out:

- the session title and last prompt
- your prompt timestamps
- tool calls, and the file paths touched by `Edit`, `Write`, `MultiEdit` and `NotebookEdit`

Each file is parsed once and cached until it changes, so the one-minute refresh is cheap.

To line the widget up with native widgets, it asks macOS for the on-screen window frames of Notification Centre (this needs no special permission) and picks the nearest free cell on the 180pt widget grid.

## Privacy

- Everything runs locally and read-only against `~/.claude/projects`.
- No network access, no analytics, no accounts.
- Session titles and prompts are shown on screen, so be aware they appear in the widget on your desktop.

## Limitations

- **Claude Code only.** Conversations on claude.ai or in other apps aren't included.
- **Not a WidgetKit widget.** Real Notification Center widgets require a full Xcode project and signing. This is a regular window styled and snapped to behave like one, so it won't appear in the system "Edit Widgets" gallery.
- Reads the default `~/.claude` location. A custom `CLAUDE_CONFIG_DIR` isn't supported yet.
- Stage Manager or unusual multi-display layouts may place the widget differently from native widgets.

## Troubleshooting

**Nothing happens when I press ⌥⌘C**: another app may already use that shortcut. Click the ✨ icon instead, or change the key in `registerHotKey()` in `main.swift`.

**The ✨ icon isn't visible**: your menu bar may be full or hidden behind the notch. Use the shortcut, or remove some menu bar items.

**The list is empty**: check that `ls ~/.claude/projects` shows folders with `.jsonl` files, and that you've used Claude Code within the last 30 days.

**`swiftc` fails or "xcrun: error"**: install the Command Line Tools with `xcode-select --install`.

**Reset settings:**

```bash
defaults delete local.claudeactivity
```

## Uninstall

```bash
pkill -x ClaudeActivity
rm -rf ~/Applications/"Claude Activity.app"
defaults delete local.claudeactivity
```

If you enabled **Login**, switch it off first, or remove *Claude Activity* under System Settings → General → Login Items.

## Project layout

```
main.swift   the whole app: session loader, analytics, SwiftUI views, menu bar and widget window
build.sh     builds and installs the .app bundle
```

## Contributing

Issues and pull requests are welcome. The app is a single Swift file with no dependencies, so `bash build.sh` is the whole build.

## Disclaimer

An independent, unofficial project. It is not affiliated with or endorsed by Anthropic. "Claude" is a trademark of Anthropic.
