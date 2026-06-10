#!/usr/bin/env bash
set -euo pipefail

alias_to_check="${1:-:demo-static:}"
hs_config_dir="${HOME}/.hammerspoon"
emote_config="${hs_config_dir}/webex-emotes/emotes.json"
hs_bin=""

if command -v hs >/dev/null 2>&1; then
  hs_bin="$(command -v hs)"
elif [[ -x "/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs" ]]; then
  hs_bin="/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs"
fi

echo "Webex Emote Paster Doctor"
echo

if [[ -d "/Applications/Hammerspoon.app" ]]; then
  echo "ok: Hammerspoon.app is installed"
else
  echo "missing: /Applications/Hammerspoon.app"
  echo "  install: brew install --cask hammerspoon"
fi

if [[ -n "${hs_bin}" ]]; then
  echo "ok: hs CLI found at ${hs_bin}"
else
  echo "missing: hs CLI"
fi

if [[ -f "${hs_config_dir}/init.lua" ]]; then
  echo "ok: ${hs_config_dir}/init.lua exists"
else
  echo "missing: ${hs_config_dir}/init.lua"
  echo "  run: ./scripts/install_hammerspoon.sh"
fi

if [[ -f "${hs_config_dir}/webex_emotes.lua" ]]; then
  echo "ok: ${hs_config_dir}/webex_emotes.lua exists"
else
  echo "missing: ${hs_config_dir}/webex_emotes.lua"
  echo "  run: ./scripts/install_hammerspoon.sh"
fi

if [[ -f "${emote_config}" ]]; then
  ruby -rjson -e '
    path = ARGV[0]
    alias_to_check = ARGV[1]
    data = JSON.parse(File.read(path))
    puts "ok: #{path} exists with #{data.size} aliases"
    if data.key?(alias_to_check)
      puts "ok: #{alias_to_check} is configured"
      puts "    #{data[alias_to_check]["path"]}"
    else
      puts "missing: #{alias_to_check} is not configured"
    end
  ' "${emote_config}" "${alias_to_check}"
else
  echo "missing: ${emote_config}"
  echo "  run the Slack scrape command from README.md"
fi

if osascript -e 'application "System Events" to get name of processes' 2>/dev/null | grep -q "Hammerspoon"; then
  echo "ok: Hammerspoon process appears to be running"
else
  echo "not running: Hammerspoon"
  echo "  run: open -a Hammerspoon"
fi

if [[ -n "${hs_bin}" ]]; then
  echo
  echo "Checking whether hs can reach the Hammerspoon app..."
  if perl -e 'alarm 4; exec @ARGV' "${hs_bin}" -c 'return "hs ok"' >/tmp/webex-emote-hs-check.out 2>/tmp/webex-emote-hs-check.err; then
    echo "ok: hs can reach Hammerspoon"
    cat /tmp/webex-emote-hs-check.out
  else
    echo "failed: hs could not reach Hammerspoon within 4 seconds"
    sed -n '1,8p' /tmp/webex-emote-hs-check.err 2>/dev/null || true
    echo "  open Hammerspoon and allow Accessibility permission"
    echo "  then choose Hammerspoon > Reload Config"
  fi
fi

echo
echo "Required manual check:"
echo "  System Settings > Privacy & Security > Accessibility > Hammerspoon must be enabled."
