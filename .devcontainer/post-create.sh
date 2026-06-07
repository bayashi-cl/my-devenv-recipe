#!/usr/bin/env bash
set -euo pipefail

mise trust --yes
mise install
node "$(mise where "npm:@anthropic-ai/claude-code")/lib/node_modules/@anthropic-ai/claude-code/install.cjs"

cat >> ~/.zshrc <<'EOF'
eval "$(mise activate zsh)" 
EOF
