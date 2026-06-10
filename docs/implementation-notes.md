# Implementation Notes

## Goal

Create a local utility that makes custom Webex emotes usable by typing aliases such as:

```text
:demo-emote:
```

The utility should paste the configured emote into the active Webex message composer, with optional automatic send behavior.

## Chosen Approach

This project uses Hammerspoon on macOS:

1. A global key event tap watches typed characters.
2. A small in-memory buffer is checked against configured aliases.
3. If Tab completion is enabled, `Tab` completes the current `:prefix` against a preferred alias list, then optionally runs the paste flow.
4. When an alias matches, the script deletes the typed alias.
5. The configured image or file is placed on the system clipboard.
6. The script sends `Cmd+V` to the active app.
7. Webex handles the paste as a normal image/file upload.

The default app filter targets Webex desktop app names and bundle IDs. Browser-based Webex can be enabled by adding the browser to `allowedApplications` or setting `allApps = true` in the Hammerspoon config.

## Why Not Process Injection

The utility intentionally avoids process memory inspection, patching, DLL/dylib injection, or private Webex internals. That path is fragile, higher risk, harder to distribute, and unnecessary for the desired behavior because Webex already supports normal image/file pasting.

## Project Files

- `README.md`: install and usage guide.
- `hammerspoon/webex_emotes.lua`: main Hammerspoon module.
- `hammerspoon/init.lua`: sample Hammerspoon loader.
- `emotes.example.json`: example alias-to-emote mapping.
- `scripts/export_slack_emotes.rb`: generic Slack custom emoji exporter using `emoji.list`.
- `scripts/update_from_slack.sh`: repeatable wrapper for refreshing Slack-sourced emotes.
- `scripts/scrape_slack_emotes.mjs`: no-dependency Chrome DevTools Protocol browser-session scraper for locked-down Slack workspaces.
- `scripts/install_hammerspoon.sh`: installer for `~/.hammerspoon`.
- `scripts/doctor.sh`: local install and alias readiness diagnostic.

## Validation Done

- Verified `scripts/install_hammerspoon.sh` with `bash -n`.
- Verified `scripts/doctor.sh` with `bash -n`.
- Verified `emotes.example.json` parses as JSON.
- Verified installer marker formatting so leading dashes are treated as data.
- Added a generic Slack export path based on Slack's official `emoji.list` API. The Slack token determines the workspace. The exporter requires `emoji:read`, downloads images/GIFs locally, resolves Slack aliases, and writes this tool's Hammerspoon config JSON.
- Added a generic browser-session scrape path for workspaces where Slack app installation/API tokens are blocked. The scraper uses Node built-ins and Chrome DevTools Protocol with a local persistent profile, relies on the user's normal Slack login, and writes only emoji files/config/manifest, not Slack session tokens. The browser profile can contain login state and defaults outside the project directory.
- Updated the browser scraper for large Slack workspaces by capturing emoji JSON responses, scrolling virtualized lists in smaller steps, printing discovery/download progress, and exposing `--max-scroll-rounds`, `--idle-rounds`, `--scroll-delay`, and `--progress-every`.
- Limited Hammerspoon menu rendering with `maxMenuAliases` because a 29k-alias Slack export can make Hammerspoon hang if every alias is added as a menu item.
- Changed GIF/file-mode pasting to use an AppleScript Finder-style file clipboard path before falling back to `hs.pasteboard.writeObjects({ url = ... })`. This gives Webex a real local file to upload and avoids Hammerspoon converting animated GIFs to a single `hs.image` frame.
- Added Tab completion in Hammerspoon. `frequentAliases` are prioritized in order, and remaining loaded aliases are available as a fallback. By default, completing an alias immediately runs the existing paste behavior.
- Updated the installer so reruns refresh the managed `webex-emote-paster` block in `~/.hammerspoon/init.lua` after making a timestamped backup. This keeps new config options in sync without duplicating the managed block.
- Could not execute the Hammerspoon Lua module in this workspace because Hammerspoon, `lua`, and `luac` are not installed here.

## References

- Webex Messages API: https://developer.webex.com/messaging/docs/api/v1/messages
- Slack `emoji.list` API: https://docs.slack.dev/reference/methods/emoji.list/
- Hammerspoon eventtap: https://www.hammerspoon.org/docs/hs.eventtap.html
- Hammerspoon pasteboard: https://www.hammerspoon.org/docs/hs.pasteboard.html
- Hammerspoon image API: https://www.hammerspoon.org/docs/hs.image.html

## Follow-Up Ideas

- Add a picker hotkey for choosing emotes without typing aliases.
- Add browser URL filtering for `web.webex.com` so browser support does not require `allApps = true`.
- Add richer clipboard preservation for non-text clipboard contents.
- Add an install check that detects whether Hammerspoon is installed and prints the exact next step.
- Add cycling UI for multiple Tab-completion matches if prefix ambiguity becomes annoying.
