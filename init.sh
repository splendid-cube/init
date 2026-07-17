#!/usr/bin/env bash
#
# init.sh — public bootstrap for the SplendidCube development environment.
#
# This is the only file you curl. It is hosted in the PUBLIC `splendid-cube/init`
# repo so it needs no auth to fetch; it then authenticates and pulls the PRIVATE
# `setup` repo, which holds the dev-env Rust CLI and the project manifest.
#
#   1. install Homebrew (if missing; also installs the Xcode Command Line Tools)
#   2. install git (to clone setup) + cmake/pkg-config (native build toolchain)
#   3. authenticate:
#        * if $GH_TOKEN / $GITHUB_TOKEN is set, use it (never persisted to disk)
#        * otherwise install gh and run `gh auth login` (credential-helper fallback)
#   4. clone/update the private `setup` repo into <root>/setup
#   5. install the Rust toolchain — the only extra tool init needs to build the CLI
#   6. `make install` — compile and copy `dev-env` to /usr/local/bin
#   7. run `dev-env` — installs the REST of dependencies.yaml (its deps phase),
#      then clones/updates/relocates every project and sets up AI config
#
# init installs only the minimum to build and run `dev-env`; `dev-env` then owns
# the full dependency set (dependencies.yaml) — brew formulae/casks, VS Code
# extensions and shell steps — installing them idempotently on that first run.
#
# Fresh machine:
#   bash <(curl -fsSL https://raw.githubusercontent.com/splendid-cube/init/main/init.sh) [ROOT_DIR]
#
# Non-interactive (CI): export GH_TOKEN=… first; pass ROOT_DIR as needed.
# Root precedence: arg > $SPLENDIDCUBE_PROJECTS_DIR > ~/Projects
#
set -euo pipefail

SETUP_OWNER="splendid-cube"
SETUP_REPO="setup"
DEFAULT_ROOT="$HOME/Projects"
# Only what's needed to fetch + build dev-env; the rest of dependencies.yaml is
# installed by dev-env itself on first run. git clones setup; cmake + pkg-config
# are a safety margin so the Rust build has a native-dep toolchain on a truly
# fresh machine (dev-env itself uses rustls, but this costs little and de-risks
# the one build that must succeed before dev-env can take over).
BOOTSTRAP_PKGS=(git cmake pkg-config)

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

# --- 5. Rust toolchain -------------------------------------------------------
# The last tool init installs. Everything else in dependencies.yaml (yq, jq, the
# casks, VS Code extensions, …) is installed by `dev-env` on its first run,
# idempotently. dev-env uses rustls (no OpenSSL); the C toolchain from the Xcode
# CLT plus cmake/pkg-config from the bootstrap step above cover any native build.
if ! command -v cargo >/dev/null 2>&1; then
  log "installing the Rust toolchain (rustup)…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
# Make cargo available if rustup just installed it.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
command -v cargo >/dev/null 2>&1 || die "cargo not on PATH after install"
ok "rust toolchain ready"

# --- 6. build + install the CLI ---------------------------------------------
log "building and installing dev-env (make install — may prompt for sudo)…"
make install

# --- 7. run it ---------------------------------------------------------------
ok "running dev-env"
exec dev-env --root "$ROOT"
