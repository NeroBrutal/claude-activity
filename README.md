# Claude Work

A macOS menu bar app + desktop widget that shows the work Claude Code has done for you,
read live from `~/.claude/projects`.

- **Menu bar popover** (⌥⌘C): sessions grouped by day, with prompts / files edited / tool calls.
- **Analyze tab**: prompts per day, hours you work, project breakdown, insights.
- **Desktop widget**: Medium (2×1) or Large (2×2), snaps to the native macOS widget grid (180pt cells)
  and avoids cells already used by other widgets. Right-click for Refresh / Size / Hide.

## Build & run

Needs only the Xcode Command Line Tools (no Xcode), macOS 14+.

```bash
bash build.sh        # builds and installs ~/Applications/Claude Work.app
open ~/Applications/"Claude Work.app"
```

Everything lives in `main.swift`. Settings: `defaults read local.claudework`.
