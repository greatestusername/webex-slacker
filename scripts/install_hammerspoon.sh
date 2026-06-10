#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_dir="${HOME}/.hammerspoon"
emote_dir="${target_dir}/webex-emotes"
start_marker='-- webex-emote-paster:start'
end_marker='-- webex-emote-paster:end'

write_managed_block() {
  printf '%s\n' "${start_marker}"
  cat "${repo_dir}/hammerspoon/init.lua"
  printf '\n%s\n' "${end_marker}"
}

mkdir -p "${emote_dir}"

cp "${repo_dir}/hammerspoon/webex_emotes.lua" "${target_dir}/webex_emotes.lua"

if [[ -f "${target_dir}/init.lua" ]]; then
  backup="${target_dir}/init.lua.backup.$(date +%Y%m%d%H%M%S)"
  cp "${target_dir}/init.lua" "${backup}"
  if grep -q -- "${start_marker}" "${target_dir}/init.lua" && grep -q -- "${end_marker}" "${target_dir}/init.lua"; then
    tmp_file="$(mktemp)"
    awk \
      -v start="${start_marker}" \
      -v end="${end_marker}" \
      -v block="${repo_dir}/hammerspoon/init.lua" '
        function print_block() {
          print start
          while ((getline line < block) > 0) {
            print line
          }
          close(block)
          print ""
          print end
        }

        $0 == start {
          if (!replaced) {
            print_block()
            replaced = 1
          }
          in_block = 1
          next
        }

        $0 == end {
          in_block = 0
          next
        }

        !in_block {
          print
        }
      ' "${target_dir}/init.lua" > "${tmp_file}"
    mv "${tmp_file}" "${target_dir}/init.lua"
  else
    {
      printf '\n'
      write_managed_block
    } >> "${target_dir}/init.lua"
  fi
  echo "Existing init.lua backed up to ${backup}"
else
  write_managed_block > "${target_dir}/init.lua"
fi

if [[ ! -f "${emote_dir}/emotes.json" ]]; then
  cp "${repo_dir}/emotes.example.json" "${emote_dir}/emotes.json"
fi

echo "Installed Webex Emote Paster into ${target_dir}"
echo "Edit ${emote_dir}/emotes.json, then reload Hammerspoon."

if [[ -d "/Applications/Hammerspoon.app" ]]; then
  open -a Hammerspoon || true
  echo "Launched Hammerspoon. If macOS prompts for Accessibility permission, allow it."
else
  echo "Hammerspoon.app was not found in /Applications."
  echo "Install it with: brew install --cask hammerspoon"
fi

echo "If aliases do not replace text, check System Settings > Privacy & Security > Accessibility > Hammerspoon."
