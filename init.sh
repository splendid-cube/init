#!/usr/bin/env bash
#
# init.sh — public bootstrap for the SplendidCube development environment.
#
# This is the only file you curl. It is hosted in the PUBLIC `splendid-cube/init`
# repo so it needs no auth to fetch; it then authenticates and pulls the PRIVATE
# `setup` repo, which holds the dev-env Rust CLI and the project manifest.
#
#   1. install Homebrew (if missing)
#   2. install the bootstrap tools: git, yq
#   3. authenticate:
#        * if $GH_TOKEN / $GITHUB_TOKEN is set, use it (never persisted to disk)
#        * otherwise install gh and run `gh auth login` (credential-helper fallback)
#   4. clone/update the private `setup` repo into <root>/setup
#   5. install everything in setup/dependencies.yaml (incl. the Rust toolchain)
#   6. `make install` — compile and copy `dev-env` to /usr/local/bin
#   7. run `dev-env` — clone/update/relocate every project per projects.yaml
#
# Fresh machine:
#   bash <(curl -fsSL https://raw.githubusercontent.com/splendid-cube/init/master/init.sh) [ROOT_DIR]
#
# Non-interactive (CI): export GH_TOKEN=… first; pass ROOT_DIR as needed.
# Root precedence: arg > $SPLENDIDCUBE_PROJECTS_DIR > ~/Projects
#
set -euo pipefail

SETUP_OWNER="splendid-cube"
SETUP_REPO="setup"
DEFAULT_ROOT="$HOME/Projects"
BOOTSTRAP_PKGS=(git yq)

# --- logging ----------------------------------------------------------------
_c() { [ -t 1 ] && printf '\033[%sm' "$1" || true; }
log()  { printf '%s==>%s %s\n' "$(_c '1;34')" "$(_c 0)" "$*"; }
ok()   { printf '%s ✓ %s %s\n' "$(_c '1;32')" "$(_c 0)" "$*"; }
warn() { printf '%s ! %s %s\n' "$(_c '1;33')" "$(_c 0)" "$*" >&2; }
die()  { printf '%s ✗ %s %s\n' "$(_c '1;31')" "$(_c 0)" "$*" >&2; exit 1; }

# --- workspace root ----------------------------------------------------------
ROOT="${1:-${SPLENDIDCUBE_PROJECTS_DIR:-$DEFAULT_ROOT}}"
mkdir -p "$ROOT"
ROOT="$(cd "$ROOT" && pwd)"
export SPLENDIDCUBE_PROJECTS_DIR="$ROOT"
log "workspace root: $ROOT"

# --- 1. Homebrew -------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  log "installing Homebrew (also installs the Xcode Command Line Tools)…"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
command -v brew >/dev/null 2>&1 || die "Homebrew install failed"
ok "homebrew ready"

brew_ensure() {
  if brew list --formula --versions "$1" >/dev/null 2>&1; then ok "$1 present"
  else log "brew install $1"; brew install "$1"; fi
}
cask_ensure() {
  if brew list --cask --versions "$1" >/dev/null 2>&1; then ok "cask $1 present"
  else log "brew install --cask $1"; brew install --cask "$1"; fi
}
# Locate the VS Code CLI (`code`) — on PATH if the cask linked it, else in the app bundle.
# `hash -r` so a `code` linked by a cask earlier in this same run is picked up.
code_bin() {
  hash -r 2>/dev/null || true
  if command -v code >/dev/null 2>&1; then command -v code; return 0; fi
  local c
  for c in "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
           "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
# Install a VS Code extension by id, unless it's already present.
vscode_ext_ensure() {
  local code; code="$(code_bin)" || true
  [ -n "$code" ] || { warn "code CLI not found — skipping extension $1 (is the visual-studio-code cask installed?)"; return; }
  if "$code" --list-extensions 2>/dev/null | grep -qixF -- "$1"; then
    ok "extension $1 present"
  else
    log "code --install-extension $1"
    "$code" --install-extension "$1" --force >/dev/null 2>&1 || warn "could not install extension $1"
  fi
}

# --- 2. bootstrap tools ------------------------------------------------------
for pkg in "${BOOTSTRAP_PKGS[@]}"; do brew_ensure "$pkg"; done

# --- 3. authentication -------------------------------------------------------
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -n "$TOKEN" ]; then
  export GH_TOKEN="$TOKEN"   # so the dev-env CLI picks it up for all later git ops
  # One-shot auth header — never written to any .git/config.
  AUTH_HDR="AUTHORIZATION: Basic $(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
  ok "auth: token from environment"
else
  brew_ensure gh
  if ! gh auth status >/dev/null 2>&1; then
    log "authenticate with GitHub — choose GitHub.com + HTTPS…"
    if [ -r /dev/tty ]; then gh auth login </dev/tty; else gh auth login; fi
  fi
  gh auth setup-git
  AUTH_HDR=""
  ok "auth: gh credential helper"
fi

# git, optionally carrying the one-shot token header
git_authed() {
  if [ -n "$AUTH_HDR" ]; then git -c http.extraHeader="$AUTH_HDR" "$@"
  else git "$@"; fi
}

# --- 4. clone / update the private setup repo --------------------------------
SETUP_DIR="$ROOT/$SETUP_REPO"
SETUP_URL="https://github.com/$SETUP_OWNER/$SETUP_REPO.git"
if [ -d "$SETUP_DIR/.git" ]; then
  log "updating ${SETUP_REPO}…"
  # Pull the current branch from origin explicitly. Repos cloned by dev-env (gix)
  # have an `origin` remote but no per-branch upstream tracking, so a bare
  # `git pull` aborts with "no tracking information". Naming remote + branch
  # sidesteps that while still fast-forwarding only.
  branch="$(git -C "$SETUP_DIR" symbolic-ref --short -q HEAD || true)"
  if [ -n "$branch" ]; then
    git_authed -C "$SETUP_DIR" pull --ff-only --quiet origin "$branch" \
      || warn "could not fast-forward $SETUP_REPO"
  else
    warn "could not fast-forward $SETUP_REPO (detached HEAD)"
  fi
else
  log "cloning $SETUP_OWNER/${SETUP_REPO}…"
  git_authed clone --quiet "$SETUP_URL" "$SETUP_DIR" \
    || die "could not clone $SETUP_OWNER/$SETUP_REPO — check access (token SSO-authorized for the org?)"
fi
cd "$SETUP_DIR"

# --- 5. dependencies.yaml ----------------------------------------------------
DEPS="$SETUP_DIR/dependencies.yaml"
if [ -f "$DEPS" ]; then
  log "installing dependencies from dependencies.yaml…"
  while IFS= read -r f; do [ -n "$f" ] && brew_ensure "$f"; done \
    < <(yq '.homebrew.formulae[]' "$DEPS" 2>/dev/null)
  while IFS= read -r c; do [ -n "$c" ] && cask_ensure "$c"; done \
    < <(yq '.homebrew.casks[]' "$DEPS" 2>/dev/null)
  while IFS= read -r e; do [ -n "$e" ] && vscode_ext_ensure "$e"; done \
    < <(yq '.["vscode-plugins"][]' "$DEPS" 2>/dev/null)
  n="$(yq '(.shell // []) | length' "$DEPS" 2>/dev/null || echo 0)"
  i=0
  while [ "$i" -lt "$n" ]; do
    name="$(yq ".shell[$i].name" "$DEPS")"
    cmd="$(yq ".shell[$i].command" "$DEPS")"
    check="$(yq ".shell[$i].check // \"\"" "$DEPS")"
    if [ -n "$check" ] && bash -c "$check" >/dev/null 2>&1; then ok "$name present"
    else log "shell setup: $name"; bash -c "$cmd"; fi
    i=$((i + 1))
  done
else
  warn "no dependencies.yaml in $SETUP_REPO — skipping dependency install"
fi

# Make cargo available if rustup just installed it.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
command -v cargo >/dev/null 2>&1 || die "cargo not on PATH after dependency install"

# --- 6. build + install the CLI ---------------------------------------------
log "building and installing dev-env (make install — may prompt for sudo)…"
make install

# --- 7. run it ---------------------------------------------------------------
ok "running dev-env"
exec dev-env --root "$ROOT"
