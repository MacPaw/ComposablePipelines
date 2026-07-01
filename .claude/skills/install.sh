#!/bin/sh
#
# Install the ComposablePipelines agent skills into the skill directories of major AI coding agents.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MacPaw/ComposablePipelines/main/.claude/skills/install.sh | sh
#
# Installs every skill bundled in this repo (each directory under .claude/skills/ with a SKILL.md),
# so new skills are picked up automatically. By default it installs for Claude Code and for any other
# supported agent whose config directory already exists. Override the destinations explicitly:
#   SKILL_DIRS="$HOME/.claude/skills $HOME/.codex/skills"   # space-separated
# Other env: CP_SKILLS_REPO (repo URL), CP_SKILLS_BRANCH (branch).
#
set -eu

REPO="${CP_SKILLS_REPO:-https://github.com/MacPaw/ComposablePipelines}"
BRANCH="${CP_SKILLS_BRANCH:-main}"

command -v git >/dev/null 2>&1 || { echo "error: git is required to install the skills" >&2; exit 1; }

# Destinations: explicit override, or Claude Code + any other agent whose home dir is present.
if [ -n "${SKILL_DIRS:-}" ]; then
    targets="$SKILL_DIRS"
else
    targets="$HOME/.claude/skills"                                       # Claude Code (always)
    [ -d "$HOME/.codex" ]           && targets="$targets $HOME/.codex/skills"            # Codex CLI
    [ -d "$HOME/.config/opencode" ] && targets="$targets $HOME/.config/opencode/skills"  # opencode
    [ -d "$HOME/.gemini" ]          && targets="$targets $HOME/.gemini/skills"           # Gemini CLI
    [ -d "$HOME/.copilot" ]         && targets="$targets $HOME/.copilot/skills"          # Copilot CLI
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Fetching skills from $REPO ($BRANCH)…"
git clone --depth 1 --branch "$BRANCH" "$REPO" "$tmp/repo" >/dev/null 2>&1
src="$tmp/repo/.claude/skills"

total=0
for dest in $targets; do
    mkdir -p "$dest"
    n=0
    for dir in "$src/"*/; do
        [ -f "${dir}SKILL.md" ] || continue          # only real skill directories
        name="$(basename "$dir")"
        rm -rf "$dest/$name"
        cp -R "$dir" "$dest/$name"
        n=$((n + 1))
    done
    echo "  $dest  ($n skill(s))"
    total=$((total + n))
done

[ "$total" -gt 0 ] || { echo "error: no skills found under .claude/skills/ in $REPO" >&2; exit 1; }
echo "Done. Restart your agent to pick up the skills."
