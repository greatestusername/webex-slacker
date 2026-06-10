#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

download_dir="${WEBEX_EMOTE_DOWNLOAD_DIR:-${repo_dir}/slack-emotes}"
config_path="${WEBEX_EMOTE_CONFIG:-${repo_dir}/emotes.generated.json}"

args=(
  --download-dir "${download_dir}"
  --config "${config_path}"
)

if [[ -n "${SLACK_TOKEN_FILE:-}" ]]; then
  args+=(--token-file "${SLACK_TOKEN_FILE}")
fi

"${repo_dir}/scripts/export_slack_emotes.rb" "${args[@]}" "$@"
