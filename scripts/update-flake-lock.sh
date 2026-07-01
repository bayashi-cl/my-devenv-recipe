#!/usr/bin/env bash
#
# Update the Nix flake lock for the devcontainer dev tools.
#
# Intended for CI: a scheduled job runs this to bump the pinned inputs
# (mainly claude-code via nixpkgs-unstable), then opens a PR if the lock
# changed. Also usable locally.
#
# Usage:
#   scripts/update-flake-lock.sh                    # update all flake inputs
#   scripts/update-flake-lock.sh nixpkgs-unstable   # update only the given input(s)
#
# Environment:
#   FLAKE_DIR   flake location (default: docker/dev/nix)
#   NIX_IMAGE   image for the Docker fallback (default: nixos/nix:latest)
#
# Works whether or not `nix` is installed:
#   - if `nix` is on PATH it is used directly
#   - otherwise it falls back to the official `nixos/nix` Docker image
#
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
FLAKE_DIR="${FLAKE_DIR:-docker/dev/nix}"
NIX_IMAGE="${NIX_IMAGE:-nixos/nix:latest}"

cd "$REPO_ROOT"

if [[ ! -f "$FLAKE_DIR/flake.nix" ]]; then
  echo "error: $FLAKE_DIR/flake.nix not found (set FLAKE_DIR to override)" >&2
  exit 1
fi

lock="$FLAKE_DIR/flake.lock"
before="$(sha256sum "$lock" 2>/dev/null | cut -d' ' -f1 || true)"

inputs=("$@")
echo "Updating flake lock in $FLAKE_DIR${inputs[*]:+ (inputs: ${inputs[*]})}..."

nix_flake_update() {
  if command -v nix >/dev/null 2>&1; then
    ( cd "$FLAKE_DIR" \
      && nix --extra-experimental-features 'nix-command flakes' flake update "$@" )
  else
    echo "nix not found locally; using Docker image $NIX_IMAGE" >&2
    docker run --rm -v "$REPO_ROOT/$FLAKE_DIR:/flake" -w /flake "$NIX_IMAGE" \
      nix --extra-experimental-features 'nix-command flakes' flake update "$@"
    # The container writes flake.lock as root; restore host ownership so
    # the CI runner (and git) can read/commit it.
    docker run --rm -v "$REPO_ROOT/$FLAKE_DIR:/flake" "$NIX_IMAGE" \
      chown -R "$(id -u):$(id -g)" /flake
  fi
}

if [[ ${#inputs[@]} -gt 0 ]]; then
  nix_flake_update "${inputs[@]}"
else
  nix_flake_update
fi

after="$(sha256sum "$lock" | cut -d' ' -f1)"

if [[ "$before" == "$after" ]]; then
  echo "flake.lock is already up to date."
  changed=false
else
  echo "flake.lock updated."
  changed=true
fi

# Expose the result to GitHub Actions (no-op elsewhere) so a workflow can
# conditionally open a PR: `if: steps.<id>.outputs.changed == 'true'`.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "changed=$changed" >> "$GITHUB_OUTPUT"
fi
