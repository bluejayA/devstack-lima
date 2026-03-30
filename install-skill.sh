#!/bin/bash
# Install devstack-setup skill for Claude Code
set -euo pipefail

SKILL_DIR="$HOME/.claude/skills/devstack-setup"

if [[ -d "$SKILL_DIR" ]]; then
    echo "Updating existing skill at $SKILL_DIR"
else
    echo "Installing skill to $SKILL_DIR"
    mkdir -p "$SKILL_DIR"
fi

cp "$(dirname "$0")/skills/SKILL.md" "$SKILL_DIR/SKILL.md"

echo "Done. Use /devstack-setup in any Claude Code session."
