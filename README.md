# init

Public bootstrap for the **SplendidCube** development environment. This repo
exists so the install one-liner needs no authentication to fetch — it then
authenticates and pulls the private [`setup`](https://github.com/splendid-cube/setup)
repo, which holds the `dev-env` CLI and the project manifest.

## Usage

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/splendid-cube/init/main/init.sh)
```

Optional target directory (else `$SPLENDIDCUBE_PROJECTS_DIR` or `~/Projects`):

```sh
bash <(curl -fsSL .../init.sh) ~/Code/splendidcube
```

Non-interactive / CI — provide a token first (no browser login):

```sh
export GH_TOKEN=ghp_xxx        # must be SSO-authorized for each org
bash <(curl -fsSL .../init.sh)
```

> Use the `bash <(curl …)` form (not `curl … | bash`) so an interactive
> `gh auth login` can read your keystrokes.

## What it does

`init.sh` installs only the **minimum** to build and run `dev-env`; the CLI then
owns the full dependency set (`setup/dependencies.yaml`), installing it on the
first run. So init:

1. installs Homebrew (if missing; also brings the Xcode Command Line Tools),
   `git`, and `cmake` + `pkg-config` (a native-build toolchain for the CLI);
2. authenticates — `$GH_TOKEN`/`$GITHUB_TOKEN` if set (injected as a one-shot
   header, never written to disk), otherwise `gh auth login`;
3. clones the private `setup` repo to `<root>/setup`;
4. installs the **Rust toolchain** (the only extra tool needed to compile the CLI);
5. `make install` — compiles and installs the `dev-env` binary;
6. runs `dev-env`, which **installs the rest of `dependencies.yaml`** (its deps
   phase — brew formulae/casks, VS Code extensions, shell steps, idempotently),
   then builds out the whole workspace from `projects.yaml`.

Everything after step 5 (and every later re-sync) is the `dev-env` CLI — see the
[`setup`](https://github.com/splendid-cube/setup) repo.
