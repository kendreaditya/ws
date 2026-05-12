# Per-repo `.ws.json` — design

## Motivation

ws v0.1 centralized all per-project configuration in `~/.config/ws/config.json` under a `projects` map keyed by name. That works for ~5 projects; it breaks down as the workspace grows:

- **Knowledge that belongs to a project doesn't live with the project.** A repo's data surface (e.g. "the `photos/` dir is a symlink into a mounted server path") is a property of the repo, not the machine. When you clone the repo on a second machine, you have to remember to also edit the central config.
- **Travels-with-the-code beats out-of-band.** Hybrid repos (code + data) need both halves to be reproducible. If `photos/ → /Volumes/data/...` is implicit, anyone (including future you) starting fresh has to reverse-engineer it from `.gitignore` and naming.
- **Central config grows unbounded.** With 100+ projects, `projects` is a 1000-line nested map. The most-edited field per project (data surface) is the part that should live with the project.
- **`ws adopt`'s output is captive.** Today, an adopt session adds entries to the central config. Those decisions die with that machine. Migrating to a new machine means re-doing adopt or copying config.json.

The fix: **per-repo `.ws.json`, committed in the repo's root, holding project-specific configuration that should travel with the code.** Central config retains only what's truly per-machine (sources, mount paths) or truly pre-existence (clone args needed before the repo is cloned).

## Schema

`<repo>/.ws.json` — optional file at the root of any managed repo.

```json
{
  "clone_args":  ["--filter=blob:none", "--sparse"],
  "post_clone":  ["git sparse-checkout set scripts configs"],
  "data": [
    {
      "path":      "photos",
      "mode":      "link",
      "source":    "data-mount",
      "remote":    "weekly-photo-wall/photos",
      "local":     "/Volumes/data/weekly-photo-wall/photos"
    },
    {
      "path":      "models",
      "mode":      "rsync",
      "source":    "nitai-rsync",
      "remote":    "music-brain-viz/models",
      "local":     "~/workspace-data/music-brain-viz/models",
      "direction": "pull-only"
    }
  ]
}
```

All fields optional. Empty `{}` is valid (means "no project-level overrides").

| Field | Type | Purpose |
|---|---|---|
| `clone_args` | string[] | Raw `git clone` flag overrides. Used by `ws reclone` (already-existing case). Has no effect on initial clone since the file doesn't exist yet — for that, use `clone_overrides` in central config. |
| `post_clone` | string[] | Shell commands to run after every clone or fetch where this repo's `.ws.json` is freshly seen. Idempotent expected. |
| `data[]` | object[] | Data surfaces — same shape as today's `projects.<name>.data[]`. Materialized on `ws sync` and managed by `ws data`. |

**Not in `.ws.json`:**
- `skip` — there's a chicken-and-egg if the project is supposed to be invisible. Keep skip-list in central config.
- `source` definitions — source registration is per-machine.

## Central config changes

`~/.config/ws/config.json` shrinks. New schema:

```json
{
  "sources":      [ ... ],   // unchanged
  "data_sources": [ ... ],   // unchanged
  "defaults":     { ... },   // unchanged
  "target":       "~/workspace",

  "skip_list": [ "ws", "linux-fork" ],

  "adopted_repos": {
    "react": {
      "kind": "third-party",
      "origin": "https://github.com/facebook/react.git",
      "adopted_at": "2026-05-11T22:00:00Z"
    }
  },

  "clone_overrides": {
    "huge-monorepo": {
      "clone_args": ["--filter=blob:none", "--sparse"],
      "post_clone": ["git sparse-checkout set src"]
    }
  }
}
```

`skip_list` replaces the per-name `projects.<name>.skip = true`. Flat list of names.

`adopted_repos` records intentional non-source clones so `ws adopt` does not keep asking about them. Valid `kind` values are `third-party`, `fork-backed`, and `owned`.

`clone_overrides` is the **escape hatch for things needed before the repo exists** (initial clone args + first-clone post_clone). Empty `{}` by default. Most projects don't need this.

**Backward compatibility:** old `projects.<name>` map is still read as a fallback when `clone_overrides[name]` or `.ws.json` are absent. No hard break.

## Conflict resolution (when both exist)

For a project with both `.ws.json` AND a central config entry:

| Field | Winner |
|---|---|
| `clone_args` (for initial clone) | central `clone_overrides[name].clone_args` — repo doesn't exist yet |
| `clone_args` (for reclone) | `<repo>/.ws.json.clone_args` — the repo is the source of truth once it exists |
| `post_clone` | central runs first (one-time pre-existence setup), then repo runs (every clone). Both run, in that order. |
| `data[]` | `<repo>/.ws.json.data` REPLACES central `projects.<name>.data`. No merge. The repo's declaration is authoritative once the repo exists. |
| `skip` | central `skip_list` is the only place. `.ws.json` has no skip field. |

## Discovery flow

`ws sync` for each repo:

1. Discover (gh / ssh-glob): emit `{name, url, source}`.
2. Skip if `name` in `skip_list`.
3. If `<target>/<name>` exists:
   - Match origin URL → fetch if matches, skip-collision if not.
4. If not exists:
   - Read `clone_overrides[name].clone_args` if set; else `source.clone_args`.
   - `git clone <args> <url> <target>/<name>`.
5. After successful clone or fetch, read `<target>/<name>/.ws.json` (if it exists):
   - Run `post_clone` commands (idempotent).
   - For each `data[]` entry, materialize (link or rsync) per its mode.
   - Materialize top-level data aliases from `mount-link` data sources, skipping names already occupied by repos or other workspace entries.
6. Run `clone_overrides[name].post_clone` (if set) — for first-time setup that the repo itself can't bootstrap.

`ws data status / link / pull / push`:

- Walks `<target>/*/.ws.json` to find projects with `data[]`.
- Also reads central `projects.<name>.data[]` as fallback (for unmigrated state).
- Per-surface logic unchanged.

## New commands and flags

| Command | Behavior |
|---|---|
| `ws config <name>` | Opens `<target>/<name>/.ws.json` in `$EDITOR`. Creates with a starter template if missing. Errors if `<name>` isn't in `~/workspace/`. |
| `ws config <name> --print` | Prints effective merged config (repo + central) for `<name>` to stdout. Like `ws explain` but JSON. |
| `ws config --migrate` | One-shot: reads every `projects.<name>` from central config, writes `<repo>/.ws.json` if the repo exists locally, removes the entry from central. Reports which entries couldn't migrate (repo doesn't exist locally). |
| `ws new <name> --with-data` | Scaffold a starter `.ws.json` in the new repo's root alongside any template files. |

## Behavior of `ws adopt` after this change

When the user picks "configure as rsync/mount-link data surface" for a project, **`ws` always writes `.ws.json` IN the project's dir**, regardless of whether the dir is a git repo. Every entry under `~/workspace/` is self-describing via its own `.ws.json`. Git-repo entries also commit it later (manual `git add` by user); non-repo data dirs just keep the file alongside their content.

The central `.projects[]` map exists only for reading legacy v0.1 configs during the transition. New writes never go there. `ws config --migrate` is the one-shot tool that lifts old entries out.

## Migration path

```
# One-time, on the user's main machine:
ws config --migrate            # exports central projects.* to per-repo .ws.json files
# Output: a per-project line of "migrated: name" or "skip: name (no local repo)"
# Skipped entries remain in central config — they'll migrate when the repo appears.
```

After migration:
- `~/.config/ws/config.json` shrinks dramatically.
- Each migrated repo gains a `.ws.json`. The user reviews + commits per repo at their leisure.
- Re-running `ws config --migrate` is a no-op for already-migrated projects.

## Implementation deltas

Functions touched:

| Existing function | Change |
|---|---|
| `cfg_project_get` | Becomes `_load_project_config <name>` — reads `<repo>/.ws.json` first, merges central `projects.<name>` as fallback, returns merged JSON object. |
| `project_is_skipped` | Reads central `skip_list` (flat array). Falls back to legacy `projects.<name>.skip = true`. |
| `resolve_clone_args` | Three-tier: central `clone_overrides[name].clone_args` (for initial clone), repo `.ws.json.clone_args` (for reclone), source default. |
| `project_post_clone` | Reads from `<repo>/.ws.json.post_clone` first, then central `clone_overrides[name].post_clone`. |
| `sync_repo` | After successful clone: if `.ws.json` exists, run post_clone hooks; materialize `data[]` surfaces via shared helper. After successful fetch: same materialization (idempotent). |
| `cmd_data` | Iterator changes: walk `<target>/*/.ws.json` for data surfaces. Fall back to central `projects[].data` for entries without a `.ws.json`. |
| `cmd_adopt` (data-surface paths) | Write to `<repo>/.ws.json` when the project is a git repo. Fall back to central for non-repo data dirs. |
| `_cfg_set_project_skip` | Writes to central `skip_list` (append unique). |

New functions:

| Function | Purpose |
|---|---|
| `_load_project_config <name>` | Two-tier read + merge. |
| `_repo_config_path <name>` | Compute `<target>/<name>/.ws.json` path. |
| `_repo_config_write <name> <json>` | Atomic write of `.ws.json` (temp + rename). |
| `_materialize_data_surface <repo_dir> <surface>` | Per-surface link or rsync logic, extracted from `data_one` and reused by `sync_repo`. |
| `cmd_config` | Edit / print / migrate. |

New helpers in `cmd_adopt`:
- When writing a data surface, dispatch to `_repo_config_write` (per-repo) or `_cfg_add_data_*` (central) based on whether the project is a git repo.

## Backward compatibility

Strict: every existing `~/.config/ws/config.json` keeps working. No flag day. Users can:
- Keep the old layout indefinitely.
- Migrate per-project at their own pace (manual edits, or `ws config <name>` to start).
- Bulk-migrate with `ws config --migrate` when ready.

ws reads both formats transparently. The audit and adopt commands continue producing valid output.

## Out of scope (v1.2)

- **Schema versioning of `.ws.json`** — no version field. If we need to break the schema later, add `"_schema": 2` then. Today's schema is small enough that flat-shape evolution is fine.
- **Encrypted secrets in `.ws.json`** — never. Use `.env` files (gitignored) for secrets, as ever.
- **Cross-repo dependencies** — `.ws.json` describes one repo. If repo A needs repo B's data, that's a separate (likely manual) coordination problem.
- **Auto-commit of `.ws.json` after `ws adopt`** — explicit `git add` + commit by the user, who knows whether the change should land in main or a feature branch.
- **`.ws.json` schema validation beyond jq parsing** — runtime sanity checks live in `ws`'s read paths (unknown fields are ignored; required fields error clearly). No JSON-schema dependency.

## Why this fits the existing ws ethos

- **Raw passthrough preserved.** `clone_args`, `post_clone`, `data[].rsync_args` (via the data_source) are all still arrays passed verbatim. No translation layer.
- **Read-only inspection still cheap.** `ws audit` and `ws list` don't have to read every `.ws.json` — they only run when the user wants the full picture (`ws data status` or `ws config <name>`).
- **Adopt becomes more durable.** Decisions made during a walk now belong to the project they describe, not the central config. Survives machine migration.
- **No new dependencies.** Still `jq` + `git` + `gh` + `ssh` + `rsync` + `fzf`. `$EDITOR` for `ws config <name>` is a standard expectation.
