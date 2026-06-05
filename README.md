# init

Public bootstrap for the **SplendidCube** development environment. This repo
exists so the install one-liner needs no authentication to fetch — it then
authenticates and pulls the private [`setup`](https://github.com/splendid-cube/setup)
repo, which holds the `dev-env` CLI and the project manifest.

## Usage

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/splendid-cube/init/master/init.sh)
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

1. installs Homebrew (if missing) and the bootstrap tools `git`, `yq`;
2. authenticates — `$GH_TOKEN`/`$GITHUB_TOKEN` if set (injected as a one-shot
   header, never written to disk), otherwise `gh auth login`;
3. clones the private `setup` repo to `<root>/setup`;
4. installs everything in `setup/dependencies.yaml` (incl. the Rust toolchain);
5. `make install` — compiles and installs the `dev-env` binary;
6. runs `dev-env`, which builds out the whole workspace from `projects.yaml`.

Everything after step 6 (and every later re-sync) is the `dev-env` CLI — see the
[`setup`](https://github.com/splendid-cube/setup) repo.
