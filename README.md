# webex-slacker
**Turn your Slack emotes into Webex auto-pasted gifs**

Small **macOS** utility for typing custom emote aliases in Webex and replacing them with image/file pastes.

Example:

```text
:demo-emote:
```

When the alias is typed, Hammerspoon deletes the alias, puts the configured image on the clipboard, and sends `Cmd+V`. Webex should treat the pasted image/file the same way it treats a manually pasted screenshot or image.

This intentionally does not inject into Webex, patch memory, or depend on private Webex internals. It uses macOS Accessibility and Clipboard APIs through Hammerspoon.

## Files

- `hammerspoon/webex_emotes.lua`: reusable Hammerspoon module.
- `hammerspoon/init.lua`: minimal loader for Hammerspoon.
- `emotes.example.json`: example alias-to-image config.
- `scripts/export_slack_emotes.rb`: exports Slack custom emoji into this tool's config format.
- `scripts/update_from_slack.sh`: repeatable wrapper for refreshing Slack-sourced emotes.
- `scripts/scrape_slack_emotes.mjs`: no-dependency Chrome DevTools Protocol Slack scraper for workspaces where API tokens are not practical.
- `scripts/install_hammerspoon.sh`: installer that copies the files into `~/.hammerspoon`.
- `scripts/doctor.sh`: checks whether Hammerspoon, config files, and a sample alias are ready.
- `docs/implementation-notes.md`: rationale, validation, references, and follow-up ideas.

## Quick Start: Slack Emotes Into Webex

This is the usual path for a company Slack where you can open the custom emoji page but cannot get a Slack API token.

1. Install Hammerspoon:

```sh
brew install --cask hammerspoon
```

2. Verify Node is available. The scraper uses Node 22+ built-ins and does not need npm packages:

```sh
cd webex-emote-paster
node --version
```

3. Install the Hammerspoon module:

```sh
./scripts/install_hammerspoon.sh
```

The installer copies config files and launches Hammerspoon. If it finds an existing `-- webex-emote-paster:start` / `-- webex-emote-paster:end` block in `~/.hammerspoon/init.lua`, it backs up the file and refreshes that managed block with the current project config. If Hammerspoon does not appear in your macOS menu bar, run:

```sh
open -a Hammerspoon
```

Then enable:

```text
System Settings > Privacy & Security > Accessibility > Hammerspoon
```

4. Scrape Slack custom emotes from your logged-in browser session and write them directly to Hammerspoon's config:

```sh
node scripts/scrape_slack_emotes.mjs \
  --workspace your-workspace \
  --download-dir ~/.hammerspoon/webex-emotes/slack-emotes \
  --config ~/.hammerspoon/webex-emotes/emotes.json
```

5. When the Chrome-compatible browser opens, log in to Slack if needed. Make sure the custom emoji page is visible, then return to the terminal and press Enter.

6. Reload Hammerspoon from the menu bar, or press:

```text
Ctrl+Alt+Cmd+R
```

7. Check the local install:

```sh
./scripts/doctor.sh :your-emote-alias:
```

The doctor should report that Hammerspoon is installed, running, reachable through `hs`, and that your chosen alias is configured.

8. In Webex, type a Slack-style alias such as:

```text
:your-emote-alias:
```

The alias should be replaced with the downloaded emote image/file paste.

You can also Tab-complete aliases. Add a `frequentAliases` list to prefer common aliases before the alphabetical fallback. For example, typing this and pressing Tab:

```text
:shi<Tab>
```

will complete the first matching alias, such as `:ship-it:`, then paste that emote if it exists in your config.

To refresh after Slack emotes change, rerun step 4 and reload Hammerspoon.

## What Gets Generated

The Slack scrape command above writes:

- `~/.hammerspoon/webex-emotes/slack-emotes/`: downloaded custom emoji files.
- `~/.hammerspoon/webex-emotes/slack-emotes/manifest.json`: export summary and warnings.
- `~/.hammerspoon/webex-emotes/emotes.json`: the active Hammerspoon alias config.

The reusable Slack browser login profile is stored outside this project by default at:

```text
~/Library/Application Support/webex-emote-paster/slack-browser-profile/
```

Delete that folder to force a fresh Slack login. The scraper does not print, copy, or write Slack session tokens into generated config files, but the browser profile itself can contain Slack login cookies after you sign in. If you override `--profile` to a path inside this project, do not commit or share that folder.

## Manual Install

1. Install Hammerspoon:

```sh
brew install --cask hammerspoon
```

2. Run the installer from this repo:

```sh
./scripts/install_hammerspoon.sh
```

Rerun the installer after project updates to sync `hammerspoon/webex_emotes.lua` and the managed block in `~/.hammerspoon/init.lua`. The installer writes a timestamped backup first.

3. Open Hammerspoon and grant Accessibility permission when macOS asks.

4. Put your PNG/JPG/GIF files somewhere stable, then edit:

```text
~/.hammerspoon/webex-emotes/emotes.json
```

5. Reload Hammerspoon config from the Hammerspoon menu, or press:

```text
Ctrl+Alt+Cmd+R
```

Use manual install if you are maintaining `emotes.json` yourself or generating it some other way.

## Troubleshooting

Run:

```sh
./scripts/doctor.sh :your-emote-alias:
```

If it says `not running: Hammerspoon`, run:

```sh
open -a Hammerspoon
```

If Hammerspoon opens but aliases still do not replace, enable Accessibility permission:

```text
System Settings > Privacy & Security > Accessibility > Hammerspoon
```

Then choose `Reload Config` from the Hammerspoon menu bar icon.

Large Slack exports can contain tens of thousands of aliases. The Hammerspoon menu intentionally shows only a count and a small sample; listing every alias in the menu can make Hammerspoon hang or fail to appear.

If your alias is configured but only fails in Webex, check whether you are using Webex desktop or browser Webex. The default config only watches apps matching Webex. For browser Webex, edit `~/.hammerspoon/init.lua` and set:

```lua
allApps = true,
```

Then reload Hammerspoon.

## Configure Emotes

`emotes.json` accepts either a string path or an object:

```json
{
  ":demo-static:": {
    "path": "~/Pictures/webex-emotes/demo-static.png",
    "mode": "image",
    "send": false
  },
  ":demo-animated:": {
    "path": "~/Pictures/webex-emotes/demo-animated.gif",
    "mode": "file",
    "send": false
  },
  ":demo-shortcut:": "~/Pictures/webex-emotes/demo-shortcut.png"
}
```

Modes:

- `image`: copies an image object to the clipboard. Best for PNG/JPG.
- `file`: copies a file URL to the clipboard. Better for preserving GIFs as attachments.

Options:

- `send: false`: default. The emote is pasted, and you manually press Enter.
- `send: true`: presses Enter after `sendDelay` seconds. This is less reliable because Webex may still be uploading the file.
- `maxMenuAliases: 25`: Hammerspoon only shows a small sample of aliases in the menu bar.
- `filePasteMethod: "applescript"`: default for GIF/file emotes. Copies the local file onto the clipboard like Finder does, which gives Webex the best chance of preserving animated GIFs.
- `tabCompletion: true`: enables Tab completion for partially typed aliases.
- `tabCompletionPastes: true`: after Tab completes an alias, immediately runs the normal emote paste behavior.
- `frequentAliases`: ordered list of aliases to prefer for Tab completion before falling back to the full emote list.

Tab completion examples:

```lua
frequentAliases = {
  ":ship-it:",
  ":demo-static:",
  ":demo-animated:"
}
```

With that list, `:shi<Tab>` chooses `:ship-it:`, `:dem<Tab>` chooses the first matching demo alias, and other prefixes fall back to the full loaded alias list. Edit `~/.hammerspoon/init.lua`, then reload Hammerspoon with `Ctrl+Alt+Cmd+R`.

GIF behavior:

- Slack GIF emotes are generated as `mode: "file"` so Webex receives the local GIF file, not a flattened image object.
- Webex still renders pasted images/files as attachment previews, so they can look much larger than real Slack custom emoji.
- If Webex itself shows a static preview while composing, send the message and check the posted attachment. Some clients preview GIFs as a still frame even when the file is animated.

## Scrape Slack Emotes Without An API Token

Use this when the Slack custom emoji page works in your browser, but you cannot get an approved Slack app/API token.

Check Node. This script requires Node 22+ for built-in `fetch` and `WebSocket` support:

```sh
node --version
```

Run against any workspace subdomain:

```sh
node scripts/scrape_slack_emotes.mjs --workspace your-workspace
```

Or pass the full page URL:

```sh
node scripts/scrape_slack_emotes.mjs --url "https://your-workspace.slack.com/customize/emoji"
```

Write directly to Hammerspoon:

```sh
node scripts/scrape_slack_emotes.mjs \
  --workspace your-workspace \
  --download-dir ~/.hammerspoon/webex-emotes/slack-emotes \
  --config ~/.hammerspoon/webex-emotes/emotes.json
```

For very large workspaces, use a longer scroll budget:

```sh
node scripts/scrape_slack_emotes.mjs \
  --url "https://your-workspace.slack.com/customize/emoji" \
  --download-dir ~/.hammerspoon/webex-emotes/slack-emotes \
  --config ~/.hammerspoon/webex-emotes/emotes.json \
  --max-scroll-rounds 5000 \
  --idle-rounds 80 \
  --scroll-delay 150
```

Useful options:

- `--workspace NAME`: opens `https://NAME.slack.com/customize/emoji`.
- `--url URL`: opens a specific Slack custom emoji page.
- `--browser PATH`: use a specific Chrome, Chromium, Edge, or Brave executable.
- `--download-dir PATH`: where image/GIF files are saved.
- `--config PATH`: where the Hammerspoon alias JSON is written.
- `--profile PATH`: persistent browser profile path.
- `--auto`: do not pause for Enter after opening Slack.
- `--keep-open`: leave the browser open after scraping.
- `--max-scroll-rounds N`: maximum list scroll attempts. Default: `3000`.
- `--idle-rounds N`: stop after this many no-growth rounds near the end. Default: `400`.
- `--scroll-delay MS`: delay after each scroll step. Default: `350`.
- `--progress-every N`: print progress every N scroll rounds. Default: `10`.
- `--send`: generate entries with `send: true`.

The scraper:

- uses your normal Slack login in a local browser profile,
- controls a Chrome-compatible browser over the built-in Chrome DevTools Protocol,
- collects emoji names and image URLs from the rendered page and Slack JSON responses,
- scrolls virtualized emoji lists in small steps and prints discovery progress,
- downloads the images/GIFs locally,
- preserves names as aliases like `:ship-it:`,
- resolves Slack aliases when they are visible in the page data,
- overwrites existing downloaded files by default, so rerunning it updates changed emoji.

Security note: the browser profile can contain Slack login state after you sign in. The default profile path is outside this project; do not commit or share it if you override `--profile`.

## Export Slack Emotes With An API Token

This works for any Slack workspace. The Slack token decides which workspace is exported.

Slack's custom emoji page is the human UI, but the reliable export path is Slack's official `emoji.list` Web API. The token needs the `emoji:read` scope. The exporter does not write the token to disk.

In many company workspaces, installing a Slack app or getting an approved API token requires admin approval. In that case, use the browser-session scraper above instead.

Use a token file to avoid putting the token in shell history:

```sh
mkdir -p ~/.config/webex-emote-paster
$EDITOR ~/.config/webex-emote-paster/slack-token
chmod 600 ~/.config/webex-emote-paster/slack-token
SLACK_TOKEN_FILE=~/.config/webex-emote-paster/slack-token ./scripts/update_from_slack.sh
```

That writes:

- `slack-emotes/`: downloaded custom emoji files.
- `slack-emotes/manifest.json`: export summary and warnings.
- `emotes.generated.json`: Hammerspoon-compatible alias config.

Generate directly into Hammerspoon's config location:

```sh
WEBEX_EMOTE_DOWNLOAD_DIR=~/.hammerspoon/webex-emotes/slack-emotes \
WEBEX_EMOTE_CONFIG=~/.hammerspoon/webex-emotes/emotes.json \
SLACK_TOKEN_FILE=~/.config/webex-emote-paster/slack-token \
./scripts/update_from_slack.sh
```

An inline environment variable also works, but it may be recorded in shell history:

```sh
SLACK_TOKEN=your-slack-token ./scripts/update_from_slack.sh
```

The exporter:

- downloads each Slack custom emoji image/GIF locally,
- preserves Slack names as aliases like `:ship-it:`,
- resolves Slack `alias:name` entries so aliases paste the same local file,
- uses `mode: "file"` for GIFs and `mode: "image"` for other image types by default,
- overwrites existing downloaded files by default, so rerunning it updates changed emoji.

You can also export from a saved `emoji.list` response:

```sh
./scripts/export_slack_emotes.rb \
  --input slack-emoji-list.json \
  --download-dir slack-emotes \
  --config emotes.generated.json
```

## Webex Desktop vs Browser

By default, aliases only trigger in apps with names or bundle IDs matching Webex. If you use Webex in a browser, edit `hammerspoon/init.lua` after installing and either:

- set `allApps = true`, or
- add your browser app name to `allowedApplications`.

## Known Limits

- Webex does not appear to expose Discord/Slack-style custom workspace emoji as a public user feature. This utility sends custom emotes as pasted images or file attachments.
- macOS Secure Input disables key event taps in password fields and some protected contexts.
- Restoring the prior clipboard is text-only by default. If your previous clipboard was an image/file, this script will not reconstruct every clipboard flavor.
