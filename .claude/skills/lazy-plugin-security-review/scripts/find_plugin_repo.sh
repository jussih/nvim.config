#!/usr/bin/env bash
# find_plugin_repo.sh
#
# Given a plugin short name (as it appears in lazy-lock.json) and a Neovim
# config directory, find the plugin's GitHub "owner/repo" by grepping the
# config for plugin specs.
#
# Usage:
#   bash find_plugin_repo.sh <plugin-short-name> <nvim-config-dir>
#
# Example:
#   bash find_plugin_repo.sh telescope.nvim ~/.config/nvim
#   -> nvim-telescope/telescope.nvim
#
# Prints every distinct match on its own line. If multiple matches are found,
# the caller should ask the user which is correct rather than guessing —
# picking the wrong fork is exactly the kind of supply-chain risk this skill
# is trying to protect against.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <plugin-short-name> <nvim-config-dir>" >&2
  exit 2
fi

PLUGIN_NAME="$1"
CONFIG_DIR="$2"

if [ ! -d "$CONFIG_DIR" ]; then
  echo "Error: nvim config dir '$CONFIG_DIR' does not exist" >&2
  exit 2
fi

# Escape regex metacharacters in the plugin name (it commonly contains '.')
escaped=$(printf '%s' "$PLUGIN_NAME" | sed 's/[][\.*^$()+?{|]/\\&/g')

# Pattern matches "owner/plugin-name" inside a quoted string. Owner names on
# GitHub: letters, digits, hyphens; may not start/end with hyphen but we're
# permissive here since we're parsing, not validating.
pattern="[\"']([A-Za-z0-9][A-Za-z0-9_.-]*/${escaped})[\"']"

# Prefer ripgrep if available, fall back to grep -R.
# `|| true` keeps exit code clean when nothing matches — callers should
# check whether stdout is empty, not whether we exited non-zero.
if command -v rg >/dev/null 2>&1; then
  { rg --no-heading --no-line-number --only-matching --pcre2 \
       "$pattern" "$CONFIG_DIR" 2>/dev/null || true; } \
    | sed -E "s/[\"']//g" \
    | sort -u
else
  { grep -RhoE "$pattern" "$CONFIG_DIR" 2>/dev/null || true; } \
    | sed -E "s/[\"']//g" \
    | sort -u
fi
