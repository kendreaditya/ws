# `ws` — workspace tool

First-class CLI that manages `~/workspace/` as a multi-source git workspace plus optional server-backed data dirs (rsync caches or symlinks into a mounted server path).

- Code lives in git, fetched from GitHub or bare repos on a Tailscale-reachable server.
- Big-file data (photos, videos, datasets, weights) lives on the server, linked or rsync-cached on demand.
- Raw passthrough: `clone_args` / `fetch_args` / `gh_args` / `rsync_args` are arrays passed verbatim to the underlying tool — no translation layer.

## Install

Three commands to a working install:

```bash
git clone https://github.com/kendreaditya/ws ~/.config/ws
~/.config/ws/ws init                                          # idempotent
$EDITOR ~/.config/ws/config.json                              # edit sources
ws sync
```

`ws init`:

- Creates `~/.local/bin/ws → ~/.config/ws/ws` symlink (make sure `~/.local/bin` is on your `$PATH`).
- Copies `config.example.json → config.json` if missing.
- Creates `~/workspace/` if missing.
- Prints the line to add to `.zshrc` for tab-completion.

For tab-completion, add to `.zshrc`:

```zsh
fpath=(~/.config/ws/completions $fpath); autoload -U compinit && compinit
```

## Daily commands

```bash
ws sync                            # clone new, fetch existing across all sources
ws sync --source github            # one source only
ws sync --dry-run --verbose        # print resolved git commands per repo

ws status                          # auto-scoped if inside a repo, else workspace-wide
ws list                            # full dashboard: dirty / ahead / behind / last_fetch / remote
ws size                            # disk usage table sorted descending

ws cd compass                      # print path; use with: cd $(ws cd compass)
ws git -- log --oneline -5         # run git in every (or current) repo
ws git --all -- fetch --tags       # explicit workspace-wide

ws push                            # bulk push of dirty+ahead, with y/N confirm
ws pull --safe                     # ff-only on clean+behind repos

ws new my-thing                    # github + private + main + empty template (all from config)
ws new my-tool --template zsh-cli  # scaffold from ~/.config/ws/templates/zsh-cli/
ws new my-data --remote homelab    # use the bare-git remote on your server
ws new local-thing --remote none   # local-only repo, no remote setup

ws clone <url>                     # picks source/args by URL host
ws explain <name>                  # show resolved config (source + project override)
```

## Less daily but important

```bash
ws init-remote myproject           # ssh homelab + git init --bare /srv/repos/myproject.git
ws reclone myproject               # backup → re-clone with current clone_args → confirm delete
ws prune --source github           # list repos deleted on github (dry-run); add --commit to remove

ws stale --days 90                 # find inactive repos by HEAD mtime + git log

ws upgrade                         # git -C ~/.config/ws pull --ff-only
ws --version                       # ws 0.1.0 (abc1234 2026-05-11)
```

## Onboarding a pre-existing workspace

If `~/workspace/` already has stuff in it (clones from another machine, data dirs, third-party reference repos, loose files), use these two commands:

```bash
ws audit                           # read-only classification dashboard
ws adopt                           # interactive walk: classify each unmanaged entry
```

`ws audit` answers "what's in my workspace and how does ws see it?" — categorizes every top-level entry into one of:

- **managed** — git repo whose origin URL matches a configured source
- **third-party** — git repo with an origin that doesn't match any source (e.g. `SakanaAI/AI-Scientist`)
- **local-only** — git repo with no remote
- **data** — directory, no `.git`
- **loose** — regular file at workspace root
- **skipped** — name has `projects.<name>.skip = true` in config

```bash
ws audit                           # all categories, grouped table
ws audit --category third-party    # just one bucket
ws audit --category unmanaged      # everything that's not managed/skipped
ws audit --json                    # NDJSON for piping to scripts
```

`ws adopt` walks every unmanaged entry one at a time, prompts you with shape-appropriate options, and writes your decisions to `config.json`. Each session creates a single timestamped backup at `config.json.bak-<ts>`.

```bash
ws adopt                           # interactive walk across all unmanaged
ws adopt thirdparty-mock           # classify just one entry
ws adopt --only-category data      # power through data dirs only
ws adopt --dry-run                 # show prompts + intended writes, don't write
ws adopt --revert                  # restore config.json from most recent backup
```

Per-shape prompt options:

| Entry shape | Choices |
|---|---|
| third-party git repo | leave alone / add owner as a github-list source / mark skip |
| local-only git repo | leave / push to github / push to homelab / mark skip |
| data dir | leave / rsync surface / mount-link surface / git-init+push github / git-init+push homelab / mark skip |
| loose file | leave / move to `_archive/` / mark in `.ignore` |

Universal keys in every prompt: `s` = skip-for-now (reappears next run), `A` = apply the same answer to **all remaining items in this category** (great for 88 data dirs), `q` = quit walk, save progress, exit cleanly.

## Data surfaces

For projects where the code is in git but the bulk data isn't:

```bash
ws data status                     # show all configured data surfaces
ws data status weekly-photo-wall   # just one project
ws data link weekly-photo-wall     # create symlink: <repo>/photos -> /Volumes/nitai/.../photos
ws data plan arbitrage             # print resolved rsync command
ws data pull arbitrage --dry-run --itemize  # safe preview
ws data pull arbitrage             # populate ~/workspace-data/arbitrage/data/
ws data push arbitrage             # opt-in per surface; always dry-runs first
```

Two data modes:

- **`mode: "link"`** — symlink to a path under a mounted server (`/Volumes/nitai/...`). The only "not stored locally" option. Requires the mount to exist first (use Finder, SMB/NFS/SSHFS/macFUSE).
- **`mode: "rsync"`** — copy to a local cache under `~/workspace-data/`. Additive pulls by default; `--delete` and pushes require explicit flags and dry-run confirmations.

## Config

`~/.config/ws/config.json` (gitignored — `config.example.json` is the committed template):

```json
{
  "sources": [
    {
      "name": "github",
      "type": "github-list",
      "owner": "kendreaditya",
      "skip_archived": true,
      "skip_forks": false,
      "clone_args": ["--filter=blob:limit=1m"],
      "fetch_args": ["--prune", "--tags"],
      "create": { "enabled": true, "gh_args": ["--private", "--default-branch=main"] }
    },
    {
      "name": "homelab",
      "type": "ssh-glob",
      "host": "homelab.tailnet.ts.net",
      "path": "/srv/repos",
      "glob": "*.git",
      "clone_args": ["--filter=blob:limit=10m"],
      "fetch_args": ["--prune", "--tags"],
      "create": { "enabled": true }
    }
  ],

  "data_sources": [
    {
      "name": "nitai-workspace",
      "type": "rsync-glob",
      "host": "nitai-node",
      "remote_path": "/home/kendreaditya/workspace",
      "rsync_args": ["-a", "--partial", "--no-owner", "--no-group"],
      "exclude": [".git/", "node_modules/", ".venv/", "__pycache__/", ".DS_Store"]
    },
    {
      "name": "nitai-mounted",
      "type": "mount-link",
      "mount_root": "/Volumes/nitai/workspace"
    }
  ],

  "projects": {
    "ws":         { "skip": true },
    "linux-fork": { "clone_args": ["--filter=blob:none", "--no-checkout"] },
    "weekly-photo-wall": {
      "data": [{
        "path": "photos", "mode": "link",
        "source": "nitai-mounted",
        "local": "/Volumes/nitai/workspace/weekly-photo-wall/photos"
      }]
    },
    "arbitrage": {
      "data": [{
        "path": "data", "mode": "rsync",
        "source": "nitai-workspace",
        "remote": "arbitrage/data",
        "local": "~/workspace-data/arbitrage/data",
        "direction": "pull-only"
      }]
    }
  },

  "defaults": { "new_remote": "github", "new_template": "empty" },
  "target": "~/workspace"
}
```

### Field reference

| Field | Type | Notes |
|---|---|---|
| `sources[].name` | string | Used in `--source` and `ws list` |
| `sources[].type` | enum | `github-list` (gh API) or `ssh-glob` (ssh + ls) |
| `sources[].owner` / `host` / `path` / `glob` | strings | Discovery params per type |
| `sources[].skip_archived` / `skip_forks` | bool | Github-list discovery filters |
| `sources[].clone_args` / `fetch_args` | array | Raw git flag arrays — no translation |
| `sources[].create.enabled` | bool | If false, source is read-only (`ws new` rejected) |
| `sources[].create.gh_args` | array | Raw `gh repo create` flags (github only) |
| `data_sources[].type` | enum | `rsync-glob` for cached copies, `mount-link` for symlinks |
| `data_sources[].host` / `remote_path` / `glob` | strings | rsync-glob discovery |
| `data_sources[].rsync_args` / `exclude` | array | Raw rsync flags, additive by default |
| `data_sources[].mount_root` | path | mount-link: where the server is mounted (e.g. `/Volumes/nitai/workspace`) |
| `projects[<name>].skip` | bool | Discovery sees it but sync/data skip it. Shipped `true` for `ws` itself. |
| `projects[<name>].clone_args` | array | Per-repo override of source `clone_args` |
| `projects[<name>].post_clone` | array | Shell commands run inside repo after clone (e.g. `git sparse-checkout set ...`) |
| `projects[<name>].data[]` | array | Data surfaces: `path`, `mode`, `source`, `remote`, `local`, `direction` |
| `projects[<name>].data[].mode` | enum | `link` (symlink to mounted path) or `rsync` (copy to local cache) |
| `projects[<name>].data[].direction` | enum | `pull-only` default; `push-explicit` to allow `ws data push` |
| `defaults.new_remote` / `new_template` | string | `ws new` fallbacks when flags omitted |
| `target` | path | Where repos land. `~` expanded. |

## Design notes

### Raw flag passthrough

`clone_args` is a JSON array passed verbatim to `git clone`. Same for `fetch_args` → `git fetch`, `create.gh_args` → `gh repo create`, `rsync_args` → `rsync`. Anything git/gh/rsync accepts, ws accepts — no curation, no foot-gun guards beyond a warning that `--depth=1` makes `ws stale` / `ws prune` unreliable on affected repos.

### Filter semantics

`--only <glob>` and `--source <name>` are **AND** — each tightens the set, never widens. To OR, run the command twice. `--all` (for `ws git`/`ws status`) explicitly overrides pwd-based auto-scoping but does not widen `--only`/`--source` to "everything."

### `ws new` form

Locked to: `mkdir` → `git init -b <branch>` → optional template copy with `{{name}}`/`{{description}}` substitution (text files only — `file --mime` gate skips binaries; filenames containing `{{name}}` are also renamed) → `git commit -m "init"` → remote setup. For github, the remote setup is `gh repo create <owner>/<name> --source=. --push`; for homelab, `ssh "git init --bare" + git remote add + git push -u`.

### Destructive ops

`ws prune` requires `--source <name>` (cross-source attribution is unsafe). Default dry-run; `--commit` to actually delete; `--archive` to move to `~/workspace/.attic/<date>/`. `ws data push` always dry-runs first and prompts. `ws reclone` always backs up before re-cloning and prompts before deleting the backup.

### What `ws` is not

- **Not a Finder integration.** Files are real files on disk. For lazy-on-`open()` placeholder files, see GitFP (separate project) which uses macOS File Provider.
- **Not git-annex.** No metadata-in-git + content-elsewhere model. Just raw git + raw rsync + symlinks.
- **Not a server-side daemon.** Server needs git+sshd+rsync. No services, no agents, nothing to install.

## Deps

- `gh` (≥ 2.x) — already on PATH for most setups
- `git` (≥ 2.27 for partial clone)
- `jq` — config parsing
- `ssh` — homelab and rsync source discovery
- `rsync` — data surfaces
- `fzf` — only for `ws cd` interactive mode; degrades to first match if absent

## License

MIT.
