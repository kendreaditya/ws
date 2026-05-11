#!/usr/bin/env zsh
# ws — workspace tool over GitHub, Tailscale git, and server-backed data dirs
# Upstream: https://github.com/kendreaditya/ws
#
# Design: raw passthrough beats invented vocabulary. clone_args / fetch_args /
# gh_args are arrays passed verbatim to git/gh — no translation layer to maintain.

emulate -L zsh
setopt extended_glob null_glob no_unset pipefail

# ─── constants ─────────────────────────────────────────────────────────────
readonly WS_VERSION="0.1.0"
readonly WS_HOME="${HOME}/.config/ws"
readonly WS_CONFIG_DEFAULT="${WS_HOME}/config.json"
readonly WS_CONFIG_EXAMPLE="${WS_HOME}/config.example.json"
readonly WS_TEMPLATES_DIR="${WS_HOME}/templates"
readonly WS_COMPLETIONS_DIR="${WS_HOME}/completions"
readonly WS_BIN_LINK="${HOME}/.local/bin/ws"

CONFIG="${WS_CONFIG:-$WS_CONFIG_DEFAULT}"

# Capture script path at top-level (before any function entry; $0 here = script)
readonly WS_SELF="${ZSH_ARGZERO:-$0}"

# ─── color helpers ─────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_0=''
fi

err()  { print -u 2 -- "${C_R}ws:${C_0} $*"; }
warn() { print -u 2 -- "${C_Y}ws:${C_0} $*"; }
info() { print -u 2 -- "${C_B}ws:${C_0} $*"; }
ok()   { print -u 2 -- "${C_G}ws:${C_0} $*"; }
die()  { err "$*"; exit 1; }

expand_path() {
  local p="$1"
  # zsh extended_glob makes bare ~ a pattern metachar; escape it
  if [[ "$p" == "~/"* ]]; then
    p="${HOME}/${p#\~/}"
  elif [[ "$p" == "~" ]]; then
    p="$HOME"
  fi
  print -r -- "$p"
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# ─── help ──────────────────────────────────────────────────────────────────
print_help() {
  cat <<'EOF'
ws — workspace sync over GitHub, Tailscale git, and server-backed data dirs

USAGE
  ws <command> [options]

INSTALL / SELF-MAINTENANCE
  init                   First-time setup: PATH symlink, config, templates, completion
  upgrade                Pull latest ws from upstream (git pull in ~/.config/ws)
  --version              Show ws version (git SHA + date from ~/.config/ws)

COMMANDS
  sync                   Clone new repos and fetch existing ones across all sources
  data <subcommand>      Manage project data dirs (rsync caches + mount symlinks)
  new <name>             Create a new project (local + optional remote)
  clone <url>            Drop-in `git clone` that auto-picks source/args by URL host
  git <args>             Run git command in every repo (or filtered subset)
  status                 Shortcut: ws git status -sb
  list                   Show all repos: source, args, remote, last fetch, dirty
  cd <pattern>           Print path of best-match repo (use: `cd $(ws cd compass)`)
  push                   Bulk `git push` across dirty+ahead repos (with confirm)
  pull --safe            Bulk `git pull --ff-only` on clean+behind repos only
  prune --source <s>     Per-source: list (or remove with --commit) repos deleted on remote
                         Pass --all to iterate every source instead
  stale [--days N]       List repos inactive >N days (default 60)
  size                   Disk usage table per repo, sorted descending
  init-remote <name>     ssh into homelab and `git init --bare` for a new repo
  reclone <name>         Re-clone a repo (backup, re-clone, confirm before delete)
  explain <name>         Show resolved config (source + project) for a repo

GLOBAL
  --config <path>        Override config (default: ~/.config/ws/config.json)
  -h, --help             Show this help

sync OPTIONS
  --source <name>        Sync only this source
  --only <glob>          Filter by repo name (AND with --source): --only 'compass*'
  --dry-run              Print plan, do nothing
  --verbose              Print resolved git command per repo

new OPTIONS
  --remote <r>           github | homelab | none (default: from config)
  --public               Public repo (overrides config default of private)
  --template <name>      Scaffold from ~/.config/ws/templates/<name>/
  --description <s>      For GitHub repo + seeded into README
  --branch <name>        Initial branch (default: main)

git OPTIONS
  --source <name>        Limit to one source
  --only <glob>          Glob filter (AND with --source)
  --all                  Force workspace-wide (overrides pwd-scoping)
  --parallel <N>         Run N repos concurrently (default: 1)
  --fail-fast            Stop on first nonzero exit

push / pull / prune / stale OPTIONS
  --source / --only / --all  Same scoping rules as `git`

data SUBCOMMANDS
  status [project]       Show data surfaces: linked, mounted, cached, missing, stale
  link [project]         Create/repair symlinks from repo paths to mounted server paths
  pull [project]         Rsync server data into ~/workspace-data cache
  push [project]         Rsync local cache back to server; always dry-run first
  plan [project]         Print resolved data actions without running them

data OPTIONS
  --dry-run              Print rsync/link plan, do nothing
  --delete               Allow rsync deletion propagation (never default)
  --itemize              Pass --itemize-changes to rsync for readable diffs
EOF
}

# ─── version ───────────────────────────────────────────────────────────────
cmd_version() {
  local sha=""
  if [[ -d "$WS_HOME/.git" ]]; then
    sha=$(git -C "$WS_HOME" log -1 --format='%h %cd' --date=short 2>/dev/null || true)
  fi
  if [[ -n "$sha" ]]; then
    print -r -- "ws ${WS_VERSION} (${sha})"
  else
    print -r -- "ws ${WS_VERSION}"
  fi
}

# ─── config loading ────────────────────────────────────────────────────────
require_config() {
  require_cmd jq
  [[ -f "$CONFIG" ]] || die "config not found: $CONFIG (run 'ws init' to scaffold)"
  jq empty < "$CONFIG" 2>/dev/null || die "config is not valid JSON: $CONFIG"
}

cfg_target() {
  local t
  t=$(jq -r '.target // "~/workspace"' < "$CONFIG" 2>/dev/null) || t="~/workspace"
  expand_path "$t"
}

cfg_sources() {
  jq -c '.sources // [] | .[]' < "$CONFIG" 2>/dev/null
}

cfg_data_sources() {
  jq -c '.data_sources // [] | .[]' < "$CONFIG" 2>/dev/null
}

cfg_data_source_by_name() {
  jq -c --arg n "$1" '(.data_sources // [])[] | select(.name == $n)' < "$CONFIG" 2>/dev/null
}

cfg_projects_all() {
  jq -c '.projects // {}' < "$CONFIG" 2>/dev/null
}

cfg_project_get() {
  jq -c --arg n "$1" '.projects[$n] // {}' < "$CONFIG" 2>/dev/null
}

cfg_default() {
  jq -r --arg k "$1" '.defaults[$k] // empty' < "$CONFIG" 2>/dev/null
}

cfg_source_by_name() {
  jq -c --arg n "$1" '(.sources // [])[] | select(.name == $n)' < "$CONFIG" 2>/dev/null
}

# ─── source discovery ──────────────────────────────────────────────────────
# Each emits NDJSON {name, url, source} per discovered code repo.

discover_github() {
  local src_json="$1"
  local sname=$(jq -r '.name' <<<"$src_json")
  local owner=$(jq -r '.owner' <<<"$src_json")
  local skip_archived=$(jq -r '.skip_archived // false' <<<"$src_json")
  local skip_forks=$(jq -r '.skip_forks // false' <<<"$src_json")

  [[ -z "$owner" || "$owner" == "null" ]] && { err "github-list source '$sname' missing 'owner'"; return 1; }
  require_cmd gh

  local f='.[]'
  [[ "$skip_archived" == "true" ]] && f+=' | select(.isArchived | not)'
  [[ "$skip_forks" == "true" ]]    && f+=' | select(.isFork | not)'
  f+=' | {name: .name, url: .sshUrl}'

  gh repo list "$owner" --limit 200 \
    --json name,sshUrl,isArchived,isFork \
    --jq "$f" 2>/dev/null \
    | jq -c --arg s "$sname" '. + {source: $s}'
}

discover_sshglob() {
  local src_json="$1"
  local sname=$(jq -r '.name' <<<"$src_json")
  local host=$(jq -r '.host' <<<"$src_json")
  local path=$(jq -r '.path' <<<"$src_json")
  local glob=$(jq -r '.glob // "*.git"' <<<"$src_json")

  [[ -z "$host" || "$host" == "null" ]] && { err "ssh-glob source '$sname' missing 'host'"; return 1; }

  ssh -o BatchMode=yes "$host" "ls -1d '$path'/${glob} 2>/dev/null" 2>/dev/null \
    | while IFS= read -r remote_dir; do
        [[ -z "$remote_dir" ]] && continue
        local base="${remote_dir##*/}"
        local name="${base%.git}"
        jq -nc --arg n "$name" --arg u "${host}:${remote_dir}" --arg s "$sname" \
          '{name:$n, url:$u, source:$s}'
      done
}

# returns NDJSON {name, kind:"data"} for rsync-glob source's remote dirs
discover_rsyncglob() {
  local src_json="$1"
  local sname=$(jq -r '.name' <<<"$src_json")
  local host=$(jq -r '.host' <<<"$src_json")
  local rpath=$(jq -r '.remote_path' <<<"$src_json")
  local glob=$(jq -r '.glob // "*"' <<<"$src_json")

  [[ -z "$host" || "$host" == "null" ]] && { err "rsync-glob source '$sname' missing 'host'"; return 1; }

  ssh -o BatchMode=yes "$host" "ls -1d '$rpath'/${glob} 2>/dev/null" 2>/dev/null \
    | while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        local name="${d##*/}"
        jq -nc --arg n "$name" --arg s "$sname" '{name:$n, kind:"data", source:$s}'
      done
}

# Run all discover_<type> over all sources, emit unified NDJSON of code repos.
# Applies --source / --only / skip filters.
discover_all_code() {
  local source_filter="${1:-}" only_glob="${2:-}"
  cfg_sources | while IFS= read -r src; do
    local sname=$(jq -r '.name' <<<"$src")
    local stype=$(jq -r '.type' <<<"$src")
    [[ -n "$source_filter" && "$sname" != "$source_filter" ]] && continue
    case "$stype" in
      github-list) discover_github "$src" ;;
      ssh-glob)    discover_sshglob "$src" ;;
      *) ;;  # data sources handled elsewhere
    esac
  done | while IFS= read -r repo; do
    local name=$(jq -r '.name' <<<"$repo")
    # skip projects with skip:true
    if project_is_skipped "$name"; then continue; fi
    # --only glob filter
    if [[ -n "$only_glob" ]]; then
      case "$name" in
        ${~only_glob}) ;;
        *) continue ;;
      esac
    fi
    print -r -- "$repo"
  done
}

# Build the source URL pattern for matching. Used by `ws clone <url>`
# and by `ws prune` (to attribute a local repo to a source).
source_pattern() {
  local src_json="$1"
  local type=$(jq -r '.type' <<<"$src_json")
  case "$type" in
    github-list)
      local owner=$(jq -r '.owner' <<<"$src_json")
      print -r -- "github.com[:/]${owner}/"
      ;;
    ssh-glob)
      local host=$(jq -r '.host' <<<"$src_json")
      local path=$(jq -r '.path' <<<"$src_json")
      print -r -- "${host}:${path}"
      ;;
    *)
      print -r -- ""
      ;;
  esac
}

# Echo source name a URL matches (or empty).
match_source_by_url() {
  local url="$1"
  cfg_sources | while IFS= read -r src; do
    local pat=$(source_pattern "$src")
    [[ -z "$pat" ]] && continue
    if [[ "$url" =~ $pat ]]; then
      jq -r '.name' <<<"$src"
      return
    fi
  done
}

# ─── effective config resolution ───────────────────────────────────────────
project_is_skipped() {
  local name="$1"
  local proj=$(cfg_project_get "$name")
  [[ $(jq -r '.skip // false' <<<"$proj") == "true" ]]
}

# Resolve effective clone args: project override > source default
resolve_clone_args() {
  local name="$1" src_json="$2"
  local proj=$(cfg_project_get "$name")
  local plen=$(jq -r '.clone_args // [] | length' <<<"$proj")
  if [[ "$plen" -gt 0 ]]; then
    jq -r '.clone_args[]' <<<"$proj"
  else
    jq -r '.clone_args // [] | .[]' <<<"$src_json"
  fi
}

resolve_fetch_args() {
  local src_json="$1"
  jq -r '.fetch_args // [] | .[]' <<<"$src_json"
}

project_post_clone() {
  cfg_project_get "$1" | jq -r '.post_clone // [] | .[]'
}

# ─── pwd auto-scope ────────────────────────────────────────────────────────
detect_current_repo() {
  local target=$(cfg_target)
  [[ "$PWD" != "$target"/* ]] && return 1
  local rest="${PWD#$target/}"
  local name="${rest%%/*}"
  [[ -d "$target/$name/.git" || -f "$target/$name/.git" ]] || return 1
  print -r -- "$name"
}

# ─── per-repo lifecycle ────────────────────────────────────────────────────
# Args: repo_name, url, source_json, dry_run, verbose, log_file
# Echoes one of: "cloned <name>", "fetched <name>", "skip-collision <name>", "skip-nogit <name>", "failed <name>"
sync_repo() {
  local name="$1" url="$2" src_json="$3" dry="$4" verbose="$5" log_file="$6"
  local target=$(cfg_target)
  local dir="$target/$name"

  local -a clone_args=("${(@f)$(resolve_clone_args "$name" "$src_json")}")
  # strip empty array element if no args
  [[ ${#clone_args[@]} -eq 1 && -z "${clone_args[1]}" ]] && clone_args=()

  if [[ ! -e "$dir" ]]; then
    if [[ "$verbose" == "1" ]]; then
      info "would clone $name: git clone ${clone_args[*]} $url $dir"
    fi
    if [[ "$dry" == "1" ]]; then
      print -r -- "would-clone $name"
      return 0
    fi
    if git clone "${clone_args[@]}" "$url" "$dir" >> "$log_file" 2>&1; then
      # run post_clone if any
      local pc=$(project_post_clone "$name")
      if [[ -n "$pc" ]]; then
        print -r -- "$pc" | while IFS= read -r cmd; do
          [[ -z "$cmd" ]] && continue
          (cd "$dir" && eval "$cmd") >> "$log_file" 2>&1 \
            || warn "post_clone failed for $name: $cmd"
        done
      fi
      print -r -- "cloned $name"
    else
      print -r -- "failed $name"
    fi
    return 0
  fi

  if [[ ! -d "$dir/.git" && ! -f "$dir/.git" ]]; then
    print -r -- "skip-nogit $name"
    return 0
  fi

  local current_url
  current_url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  if [[ -n "$current_url" && "$current_url" != "$url" ]]; then
    warn "$name: origin URL mismatch (have '$current_url', expected '$url') — skipping"
    print -r -- "skip-collision $name"
    return 0
  fi

  local -a fa=("${(@f)$(resolve_fetch_args "$src_json")}")
  [[ ${#fa[@]} -eq 1 && -z "${fa[1]}" ]] && fa=()

  if [[ "$verbose" == "1" ]]; then
    info "would fetch $name: git fetch --all ${fa[*]}"
  fi
  if [[ "$dry" == "1" ]]; then
    print -r -- "would-fetch $name"
    return 0
  fi
  if git -C "$dir" fetch --all "${fa[@]}" --quiet >> "$log_file" 2>&1; then
    print -r -- "fetched $name"
  else
    print -r -- "failed $name"
  fi
}

# ─── arg parsing helpers ───────────────────────────────────────────────────
parse_global_flags() {
  # Consumes recognized global flags from "$@"; sets POSITIONALS array.
  POSITIONALS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)  CONFIG="$2"; shift 2 ;;
      --config=*) CONFIG="${1#--config=}"; shift ;;
      -h|--help) print_help; exit 0 ;;
      --version) cmd_version; exit 0 ;;
      *) POSITIONALS+=("$1"); shift ;;
    esac
  done
}

# ─── cmd: sync ─────────────────────────────────────────────────────────────
cmd_sync() {
  local source_filter="" only_glob="" dry=0 verbose=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)    source_filter="$2"; shift 2 ;;
      --source=*)  source_filter="${1#*=}"; shift ;;
      --only)      only_glob="$2"; shift 2 ;;
      --only=*)    only_glob="${1#*=}"; shift ;;
      --dry-run)   dry=1; shift ;;
      --verbose|-v) verbose=1; shift ;;
      -h|--help)   print -r -- "Usage: ws sync [--source <name>] [--only <glob>] [--dry-run] [--verbose]"; return 0 ;;
      *) die "ws sync: unknown flag '$1'" ;;
    esac
  done

  require_config
  local target=$(cfg_target)
  mkdir -p "$target"
  local log_file="$target/.ws.log"
  : > "$log_file"  # truncate

  local -A counts
  counts=(cloned 0 fetched 0 would-clone 0 would-fetch 0 skip-collision 0 skip-nogit 0 failed 0)
  local -a cloned_list fetched_list failed_list skip_list

  # iterate sources once, then per repo dispatch to sync_repo
  local total=0
  while IFS= read -r src; do
    local sname=$(jq -r '.name' <<<"$src")
    local stype=$(jq -r '.type' <<<"$src")
    [[ -n "$source_filter" && "$sname" != "$source_filter" ]] && continue
    case "$stype" in
      github-list|ssh-glob) ;;
      *) continue ;;
    esac

    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      local rname=$(jq -r '.name' <<<"$repo")
      local rurl=$(jq -r '.url' <<<"$repo")
      # filter: skip
      project_is_skipped "$rname" && continue
      # filter: --only
      if [[ -n "$only_glob" ]]; then
        case "$rname" in
          ${~only_glob}) ;;
          *) continue ;;
        esac
      fi
      total=$((total+1))
      local result=$(sync_repo "$rname" "$rurl" "$src" "$dry" "$verbose" "$log_file")
      local rkind="${result%% *}" rwhich="${result#* }"
      counts[$rkind]=$((${counts[$rkind]:-0} + 1))
      case "$rkind" in
        cloned)         cloned_list+=("$rwhich"); ok "cloned $rwhich" ;;
        fetched)        fetched_list+=("$rwhich") ;;
        failed)         failed_list+=("$rwhich"); err "failed $rwhich (see $log_file)" ;;
        skip-collision|skip-nogit) skip_list+=("$rwhich") ;;
        would-clone|would-fetch) print -r -- "$result" ;;
      esac
    done < <(case "$stype" in
      github-list) discover_github "$src" ;;
      ssh-glob)    discover_sshglob "$src" ;;
    esac)
  done < <(cfg_sources)

  # summary
  print -r -- ""
  print -r -- "${C_B}ws sync summary${C_0}"
  print -r -- "─────────────────────────────────"
  print -r -- "  considered:     $total"
  if [[ "$dry" == "1" ]]; then
    print -r -- "  would clone:    ${counts[would-clone]:-0}"
    print -r -- "  would fetch:    ${counts[would-fetch]:-0}"
  else
    print -r -- "  cloned:         ${counts[cloned]:-0}"
    print -r -- "  fetched:        ${counts[fetched]:-0}"
    print -r -- "  skipped:        $((${counts[skip-collision]:-0} + ${counts[skip-nogit]:-0}))"
    print -r -- "  failed:         ${counts[failed]:-0}"
  fi
  [[ ${counts[failed]:-0} -gt 0 ]] && return 1
  return 0
}

# ─── cmd: list ─────────────────────────────────────────────────────────────
cmd_list() {
  local names_only=0 source_filter="" only_glob=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --names-only) names_only=1; shift ;;
      --source)     source_filter="$2"; shift 2 ;;
      --only)       only_glob="$2"; shift 2 ;;
      -h|--help)    print -r -- "Usage: ws list [--source <name>] [--only <glob>] [--names-only]"; return 0 ;;
      *) die "ws list: unknown flag '$1'" ;;
    esac
  done

  require_config
  local target=$(cfg_target)

  if [[ "$names_only" == "1" ]]; then
    discover_all_code "$source_filter" "$only_glob" | jq -r '.name' | sort -u
    # also include local-only repos in the workspace
    if [[ -d "$target" ]]; then
      for d in "$target"/*(N/); do
        local name="${d##*/}"
        [[ -d "$d/.git" || -f "$d/.git" ]] && print -r -- "$name"
      done | sort -u
    fi
    return 0
  fi

  # Full dashboard. Header + per-repo line.
  {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' NAME SOURCE DIRTY AHEAD BEHIND LAST_FETCH REMOTE
    # union: discovered repos + local repos in target
    local -A seen
    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      local name=$(jq -r '.name' <<<"$repo")
      local src=$(jq -r '.source' <<<"$repo")
      project_is_skipped "$name" && continue
      seen[$name]="$src"
    done < <(discover_all_code "$source_filter" "$only_glob")

    # walk local dirs
    if [[ -d "$target" ]]; then
      for d in "$target"/*(N/); do
        local name="${d##*/}"
        [[ -d "$d/.git" || -f "$d/.git" ]] || continue
        [[ -z "${seen[$name]:-}" ]] && seen[$name]="local-only"
      done
    fi

    # render
    for name in ${(kon)seen}; do
      local dir="$target/$name"
      local src="${seen[$name]}"
      local dirty="-" ahead="-" behind="-" lastfetch="-" remote="-"
      if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then
        dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        local ab=$(git -C "$dir" rev-list --left-right --count '@{u}..HEAD' 2>/dev/null || print -r -- "?\t?")
        behind=$(print -r -- "$ab" | awk '{print $1}')
        ahead=$(print -r -- "$ab" | awk '{print $2}')
        [[ -z "$ahead" ]] && ahead="?"
        [[ -z "$behind" ]] && behind="?"
        if [[ -f "$dir/.git/FETCH_HEAD" ]]; then
          lastfetch=$(stat -f '%Sm' -t '%Y-%m-%d' "$dir/.git/FETCH_HEAD" 2>/dev/null || echo "-")
        fi
        remote=$(git -C "$dir" remote get-url origin 2>/dev/null || print -r -- "-")
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$src" "$dirty" "$ahead" "$behind" "$lastfetch" "$remote"
    done
  } | column -t -s $'\t'
}

# ─── cmd: status (alias for git status -sb) ────────────────────────────────
cmd_status() {
  cmd_git status -sb "$@"
}

# ─── cmd: git <args> ───────────────────────────────────────────────────────
# Runs `git -C <repo> <args>` across the resolved repo set.
cmd_git() {
  local source_filter="" only_glob="" force_all=0 parallel=1 fail_fast=0
  local -a passthru
  passthru=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)    source_filter="$2"; shift 2 ;;
      --only)      only_glob="$2"; shift 2 ;;
      --all)       force_all=1; shift ;;
      --parallel)  parallel="$2"; shift 2 ;;
      --fail-fast) fail_fast=1; shift ;;
      --)          shift; passthru+=("$@"); break ;;
      *)           passthru+=("$1"); shift ;;
    esac
  done

  require_config
  local target=$(cfg_target)
  local -a repos

  if [[ -z "$source_filter" && -z "$only_glob" && "$force_all" == "0" ]]; then
    local cur=$(detect_current_repo 2>/dev/null || true)
    if [[ -n "$cur" ]]; then
      info "scoped to $cur (use --all for whole workspace)"
      repos=("$cur")
    fi
  fi

  if [[ ${#repos[@]} -eq 0 ]]; then
    # walk local repos in target
    if [[ -d "$target" ]]; then
      for d in "$target"/*(N/); do
        local name="${d##*/}"
        [[ -d "$d/.git" || -f "$d/.git" ]] || continue
        project_is_skipped "$name" && continue
        if [[ -n "$only_glob" ]]; then
          case "$name" in ${~only_glob}) ;; *) continue ;; esac
        fi
        if [[ -n "$source_filter" ]]; then
          # check origin URL matches source pattern
          local src_json=$(cfg_source_by_name "$source_filter")
          [[ -z "$src_json" ]] && die "no source named '$source_filter'"
          local pat=$(source_pattern "$src_json")
          local url=$(git -C "$d" remote get-url origin 2>/dev/null || true)
          [[ -z "$pat" || ! "$url" =~ $pat ]] && continue
        fi
        repos+=("$name")
      done
    fi
  fi

  if [[ ${#repos[@]} -eq 0 ]]; then
    warn "no repos matched filter"
    return 0
  fi

  local rc=0
  if [[ "$parallel" -gt 1 ]]; then
    print -l -- "${repos[@]}" | xargs -I{} -P "$parallel" "$WS_SELF" _git_one "$target" {} -- "${passthru[@]}"
    rc=$?
  else
    for r in "${repos[@]}"; do
      cmd__git_one "$target" "$r" -- "${passthru[@]}" || {
        rc=$?
        [[ "$fail_fast" == "1" ]] && return $rc
      }
    done
  fi
  return $rc
}

# Internal helper invoked by `cmd_git --parallel`
cmd__git_one() {
  local target="$1" name="$2"; shift 2
  [[ "$1" == "--" ]] && shift
  local dir="$target/$name"
  [[ -d "$dir/.git" || -f "$dir/.git" ]] || { err "$name: not a git repo"; return 2; }
  local out
  out=$(git -C "$dir" "$@" 2>&1) || {
    local ec=$?
    print -r -- "${C_R}${name}${C_0}:"
    print -r -- "$out" | sed 's/^/  /'
    return $ec
  }
  if [[ -n "$out" ]]; then
    print -r -- "${C_G}${name}${C_0}:"
    print -r -- "$out" | sed 's/^/  /'
  fi
}

# ─── cmd: cd <pattern> ─────────────────────────────────────────────────────
cmd_cd() {
  local pat="${1:-}"
  require_config
  local target=$(cfg_target)
  [[ -d "$target" ]] || die "workspace target missing: $target"

  local -a candidates
  for d in "$target"/*(N/); do
    candidates+=("${d##*/}")
  done

  local pick=""
  if [[ -z "$pat" ]]; then
    if command -v fzf >/dev/null 2>&1; then
      pick=$(print -l -- "${candidates[@]}" | fzf --height=40% --reverse)
    else
      die "no pattern given and fzf not installed"
    fi
  else
    # exact match wins
    for c in "${candidates[@]}"; do
      [[ "$c" == "$pat" ]] && { pick="$c"; break; }
    done
    # else substring match
    if [[ -z "$pick" ]]; then
      local -a hits
      for c in "${candidates[@]}"; do
        [[ "$c" == *"$pat"* ]] && hits+=("$c")
      done
      if [[ ${#hits[@]} -eq 1 ]]; then
        pick="${hits[1]}"
      elif [[ ${#hits[@]} -gt 1 ]]; then
        if command -v fzf >/dev/null 2>&1; then
          pick=$(print -l -- "${hits[@]}" | fzf --height=40% --reverse --query="$pat")
        else
          pick="${hits[1]}"
        fi
      fi
    fi
  fi

  [[ -z "$pick" ]] && die "no match for '$pat'"
  print -r -- "$target/$pick"
}

# ─── cmd: clone <url> ──────────────────────────────────────────────────────
cmd_clone() {
  [[ $# -lt 1 ]] && die "Usage: ws clone <url>"
  local url="$1"
  require_config
  local sname=$(match_source_by_url "$url")
  if [[ -z "$sname" ]]; then
    err "no configured source matches URL: $url"
    print -u 2 -- "  configured patterns:"
    cfg_sources | while IFS= read -r s; do
      local n=$(jq -r '.name' <<<"$s")
      local p=$(source_pattern "$s")
      print -u 2 -- "    $n: $p"
    done
    print -u 2 -- "  add a source to ~/.config/ws/config.json, or use 'git clone' directly."
    return 1
  fi
  local src=$(cfg_source_by_name "$sname")
  local target=$(cfg_target)
  mkdir -p "$target"
  local name="${url##*/}"
  name="${name%.git}"
  local dir="$target/$name"
  [[ -e "$dir" ]] && die "$dir already exists"

  local -a clone_args=("${(@f)$(resolve_clone_args "$name" "$src")}")
  [[ ${#clone_args[@]} -eq 1 && -z "${clone_args[1]}" ]] && clone_args=()

  info "matched source: $sname"
  info "running: git clone ${clone_args[*]} $url $dir"
  git clone "${clone_args[@]}" "$url" "$dir"

  local pc=$(project_post_clone "$name")
  if [[ -n "$pc" ]]; then
    print -r -- "$pc" | while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      info "post_clone: $cmd"
      (cd "$dir" && eval "$cmd")
    done
  fi
}

# ─── cmd: new ──────────────────────────────────────────────────────────────
cmd_new() {
  local name="" remote="" public=0 template="" description="" branch="main"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote)      remote="$2"; shift 2 ;;
      --public)      public=1; shift ;;
      --template)    template="$2"; shift 2 ;;
      --description) description="$2"; shift 2 ;;
      --branch)      branch="$2"; shift 2 ;;
      -h|--help)     print -r -- "Usage: ws new <name> [--remote <r>] [--public] [--template <t>] [--description <s>] [--branch <b>]"; return 0 ;;
      -*)            die "ws new: unknown flag '$1'" ;;
      *)             [[ -z "$name" ]] && name="$1" || die "ws new: extra argument '$1'"; shift ;;
    esac
  done
  [[ -z "$name" ]] && die "Usage: ws new <name>"

  # validate name: no slashes, no leading dot
  [[ "$name" == */* ]]   && die "name cannot contain '/'"
  [[ "$name" == .* ]]    && die "name cannot start with '.'"

  require_config
  # resolve defaults
  [[ -z "$remote" ]]   && remote=$(cfg_default new_remote)
  [[ -z "$remote" ]]   && remote="github"
  [[ -z "$template" ]] && template=$(cfg_default new_template)
  [[ -z "$template" ]] && template="empty"

  local target=$(cfg_target)
  mkdir -p "$target"
  local dir="$target/$name"
  [[ -e "$dir" ]] && die "$dir already exists"

  # validate template if specified (and not "empty" with no template dir)
  local tpl_dir=""
  if [[ -n "$template" && "$template" != "none" ]]; then
    tpl_dir="$WS_TEMPLATES_DIR/$template"
    [[ -d "$tpl_dir" ]] || die "template not found: $tpl_dir"
  fi

  # validate remote
  case "$remote" in
    github|homelab|none) ;;
    *) die "--remote must be github | homelab | none (got '$remote')" ;;
  esac

  info "creating $dir (branch=$branch, template=$template, remote=$remote)"
  mkdir -p "$dir"
  git -C "$dir" init -b "$branch" -q

  # copy template with substitution on text files only
  if [[ -n "$tpl_dir" && -d "$tpl_dir" ]]; then
    info "scaffolding from template '$template'"
    # copy preserves permissions; -a copies symlinks etc.
    cp -a "$tpl_dir/." "$dir/"
    # rename files/dirs containing {{name}} in their path
    # -depth ensures leaves first (so files renamed before their parent dirs)
    find "$dir" -depth -name '*{{name}}*' -not -path '*/.git/*' 2>/dev/null \
      | while IFS= read -r f; do
          local newname="${f//\{\{name\}\}/$name}"
          [[ "$f" != "$newname" ]] && mv "$f" "$newname"
        done
    # find text files and substitute {{name}} / {{description}} in contents
    local desc_safe="${description:-A new project}"
    local mime=""
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      mime=$(file --mime "$f" 2>/dev/null | sed 's/.*: //')
      # gate on text-like MIME to avoid corrupting binaries (PNG/etc.)
      if [[ "$mime" == text/* || "$mime" == */json* || "$mime" == */xml* || "$mime" == */javascript* || "$mime" == */yaml* || "$mime" == */toml* ]]; then
        WS_NAME="$name" WS_DESC="$desc_safe" perl -i -pe 's/\{\{name\}\}/$ENV{WS_NAME}/g; s/\{\{description\}\}/$ENV{WS_DESC}/g' "$f"
      fi
    done < <(find "$dir" -type f -not -path '*/.git/*')
  fi

  # initial commit if any files exist
  if [[ -n "$(ls -A "$dir" 2>/dev/null | grep -v '^.git$' || true)" ]]; then
    git -C "$dir" add -A
    git -C "$dir" -c user.useConfigOnly=false commit -q -m "init" 2>/dev/null \
      || warn "initial commit failed (configure user.email / user.name and re-commit)"
  fi

  # remote setup
  case "$remote" in
    github)
      require_cmd gh
      local src=$(cfg_source_by_name "github" 2>/dev/null || cfg_source_by_name "$(cfg_default new_remote)" 2>/dev/null)
      local owner=$(jq -r '.owner // empty' <<<"$src" 2>/dev/null)
      [[ -z "$owner" ]] && owner="$(gh api user --jq .login 2>/dev/null)"
      local -a gh_args=("${(@f)$(jq -r '.create.gh_args // [] | .[]' <<<"$src")}")
      [[ ${#gh_args[@]} -eq 1 && -z "${gh_args[1]}" ]] && gh_args=()
      # default to private unless --public; existing config may already include --private
      if [[ "$public" == "1" ]]; then
        gh_args=(${gh_args[@]:#--private})
        gh_args+=(--public)
      fi
      [[ -n "$description" ]] && gh_args+=(--description "$description")
      info "running: gh repo create ${owner}/${name} ${gh_args[*]} --source=. --push"
      (cd "$dir" && gh repo create "${owner}/${name}" "${gh_args[@]}" --source=. --push) \
        || die "gh repo create failed"
      ok "created github.com/${owner}/${name} and pushed initial commit"
      ;;
    homelab)
      local src=$(cfg_source_by_name "homelab" 2>/dev/null)
      [[ -z "$src" ]] && die "no 'homelab' source in config; can't create homelab remote"
      local host=$(jq -r '.host' <<<"$src")
      local rpath=$(jq -r '.path' <<<"$src")
      local url="${host}:${rpath}/${name}.git"
      info "ssh $host: git init --bare $rpath/${name}.git"
      ssh "$host" "git init --bare $rpath/${name}.git" >/dev/null || die "homelab bare init failed"
      git -C "$dir" remote add origin "$url"
      git -C "$dir" push -u origin "$branch" || warn "initial push failed (you can retry: cd $dir && git push -u origin $branch)"
      ok "created $url and pushed initial commit"
      ;;
    none)
      info "skipping remote setup (local-only repo)"
      ;;
  esac

  print -r -- "$dir"
}

# ─── cmd: push ─────────────────────────────────────────────────────────────
cmd_push() {
  local source_filter="" only_glob="" force_all=0 dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source) source_filter="$2"; shift 2 ;;
      --only)   only_glob="$2"; shift 2 ;;
      --all)    force_all=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) die "ws push: unknown flag '$1'" ;;
    esac
  done

  require_config
  local target=$(cfg_target)
  local -a candidates
  for d in "$target"/*(N/); do
    local name="${d##*/}"
    [[ -d "$d/.git" || -f "$d/.git" ]] || continue
    project_is_skipped "$name" && continue
    if [[ -n "$only_glob" ]]; then
      case "$name" in ${~only_glob}) ;; *) continue ;; esac
    fi
    # ahead?
    local ahead=$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    if [[ "$ahead" -gt 0 ]]; then
      candidates+=("$name ($ahead ahead)")
    fi
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    info "no repos with unpushed commits"
    return 0
  fi

  print -r -- "Repos with unpushed commits:"
  for c in "${candidates[@]}"; do
    print -r -- "  - $c"
  done

  if [[ "$dry" == "1" ]]; then
    info "(dry-run: not pushing)"
    return 0
  fi

  print -r -- ""
  print -nr -- "Push all? [y/N] "
  read -k 1 ans
  print -r -- ""
  [[ "$ans" != "y" && "$ans" != "Y" ]] && { info "aborted"; return 0; }

  local rc=0
  for c in "${candidates[@]}"; do
    local name="${c%% *}"
    info "pushing $name"
    git -C "$target/$name" push || { err "$name push failed"; rc=1; }
  done
  return $rc
}

# ─── cmd: pull --safe ──────────────────────────────────────────────────────
cmd_pull() {
  local safe=0 source_filter="" only_glob=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --safe)   safe=1; shift ;;
      --source) source_filter="$2"; shift 2 ;;
      --only)   only_glob="$2"; shift 2 ;;
      *) die "ws pull: unknown flag '$1'" ;;
    esac
  done
  [[ "$safe" != "1" ]] && die "ws pull requires --safe (no other modes implemented; use 'ws git pull' for raw)"

  require_config
  local target=$(cfg_target)
  local rc=0
  for d in "$target"/*(N/); do
    local name="${d##*/}"
    [[ -d "$d/.git" || -f "$d/.git" ]] || continue
    project_is_skipped "$name" && continue
    if [[ -n "$only_glob" ]]; then
      case "$name" in ${~only_glob}) ;; *) continue ;; esac
    fi
    local dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$dirty" -gt 0 ]]; then
      warn "skip $name: dirty"
      continue
    fi
    local behind=$(git -C "$d" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
    if [[ "$behind" == 0 ]]; then
      continue
    fi
    local ahead=$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    if [[ "$ahead" -gt 0 ]]; then
      warn "skip $name: ahead $ahead (would not ff)"
      continue
    fi
    info "ff-pull $name (behind $behind)"
    git -C "$d" pull --ff-only --quiet || { err "$name pull failed"; rc=1; }
  done
  return $rc
}

# ─── cmd: prune --source <name> ────────────────────────────────────────────
cmd_prune() {
  local source_filter="" commit=0 archive=0 only_glob="" prune_all=0 dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)  source_filter="$2"; shift 2 ;;
      --only)    only_glob="$2"; shift 2 ;;
      --commit)  commit=1; shift ;;
      --archive) archive=1; shift ;;
      --all)     prune_all=1; shift ;;
      --dry-run) dry=1; shift ;;
      *) die "ws prune: unknown flag '$1'" ;;
    esac
  done

  if [[ -z "$source_filter" && "$prune_all" != "1" ]]; then
    die "ws prune requires --source <name> or --all (cross-source prune is unsafe by default)"
  fi

  require_config

  if [[ "$prune_all" == "1" ]]; then
    local rc=0
    while IFS= read -r src; do
      local sname=$(jq -r '.name' <<<"$src")
      print -r -- ""
      print -r -- "${C_B}=== source: $sname ===${C_0}"
      _prune_one_source "$src" "$only_glob" "$commit" "$archive" || rc=$?
    done < <(cfg_sources)
    return $rc
  fi

  local src=$(cfg_source_by_name "$source_filter")
  [[ -z "$src" ]] && die "no source named '$source_filter'"
  _prune_one_source "$src" "$only_glob" "$commit" "$archive"
}

# Helper: prune orphans for one source. Args: src_json, only_glob, commit, archive
_prune_one_source() {
  local src_json="$1" only_glob="$2" commit="$3" archive="$4"
  local sname=$(jq -r '.name' <<<"$src_json")
  local pat=$(source_pattern "$src_json")
  [[ -z "$pat" ]] && { warn "source '$sname' has no pattern for prune attribution; skipping"; return 0; }

  local stype=$(jq -r '.type' <<<"$src_json")
  local -A remote_set
  case "$stype" in
    github-list) while IFS= read -r r; do remote_set[$(jq -r '.name' <<<"$r")]=1; done < <(discover_github "$src_json") ;;
    ssh-glob)    while IFS= read -r r; do remote_set[$(jq -r '.name' <<<"$r")]=1; done < <(discover_sshglob "$src_json") ;;
    *) warn "ws prune: source type '$stype' not supported; skipping"; return 0 ;;
  esac

  local target=$(cfg_target)
  local -a orphans
  for d in "$target"/*(N/); do
    local name="${d##*/}"
    [[ -d "$d/.git" || -f "$d/.git" ]] || continue
    project_is_skipped "$name" && continue
    if [[ -n "$only_glob" ]]; then
      case "$name" in ${~only_glob}) ;; *) continue ;; esac
    fi
    local url=$(git -C "$d" remote get-url origin 2>/dev/null || true)
    [[ -z "$url" || ! "$url" =~ $pat ]] && continue
    if [[ -f "$d/.git/shallow" ]]; then
      warn "$name is a shallow clone; prune attribution may be unreliable"
    fi
    [[ -z "${remote_set[$name]:-}" ]] && orphans+=("$name")
  done

  if [[ ${#orphans[@]} -eq 0 ]]; then
    ok "no orphans for source '$sname'"
    return 0
  fi

  print -r -- "Local repos in source '$sname' that no longer exist on remote:"
  for o in "${orphans[@]}"; do
    print -r -- "  - $o"
  done

  if [[ "$commit" != "1" ]]; then
    info "(dry-run: pass --commit to actually remove)"
    return 0
  fi

  if [[ "$archive" == "1" ]]; then
    local stamp=$(date +%Y-%m-%d)
    local atticdir="$target/.attic/$stamp"
    mkdir -p "$atticdir"
    for o in "${orphans[@]}"; do
      info "archiving $o -> $atticdir/$o"
      mv "$target/$o" "$atticdir/$o"
    done
  else
    print -nr -- "Delete these directories? [y/N] "
    read -k 1 ans; print -r -- ""
    [[ "$ans" != "y" && "$ans" != "Y" ]] && { info "aborted"; return 0; }
    for o in "${orphans[@]}"; do
      info "removing $o"
      rm -rf "$target/$o"
    done
  fi
}

# ─── cmd: stale ────────────────────────────────────────────────────────────
cmd_stale() {
  local days=60 source_filter="" only_glob=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days)   days="$2"; shift 2 ;;
      --source) source_filter="$2"; shift 2 ;;
      --only)   only_glob="$2"; shift 2 ;;
      *) die "ws stale: unknown flag '$1'" ;;
    esac
  done

  require_config
  local target=$(cfg_target)
  local now=$(date +%s)
  local cutoff=$((now - days * 86400))

  {
    printf '%s\t%s\t%s\n' NAME DAYS_IDLE LAST_ACTIVITY
    for d in "$target"/*(N/); do
      local name="${d##*/}"
      [[ -d "$d/.git" || -f "$d/.git" ]] || continue
      project_is_skipped "$name" && continue
      if [[ -n "$only_glob" ]]; then
        case "$name" in ${~only_glob}) ;; *) continue ;; esac
      fi

      local head_mt=0 refs_mt=0 log_ct=0
      [[ -f "$d/.git/HEAD" ]] && head_mt=$(stat -f %m "$d/.git/HEAD" 2>/dev/null || echo 0)
      if [[ -d "$d/.git/refs" ]]; then
        refs_mt=$(find "$d/.git/refs" -type f -exec stat -f %m {} \; 2>/dev/null | sort -n | tail -1)
        [[ -z "$refs_mt" ]] && refs_mt=0
      fi
      log_ct=$(git -C "$d" log -1 --format=%ct 2>/dev/null || echo 0)

      # max of all three
      local newest=$head_mt
      [[ $refs_mt -gt $newest ]] && newest=$refs_mt
      [[ $log_ct -gt $newest ]] && newest=$log_ct
      [[ $newest -eq 0 ]] && continue
      [[ $newest -gt $cutoff ]] && continue

      local idle=$(( (now - newest) / 86400 ))
      local human=$(date -r "$newest" '+%Y-%m-%d' 2>/dev/null || echo "?")

      # shallow warning
      local shallow_note=""
      [[ -f "$d/.git/shallow" ]] && shallow_note=" (shallow: dates may be misleading)"

      printf '%s\t%d\t%s%s\n' "$name" "$idle" "$human" "$shallow_note"
    done
  } | column -t -s $'\t'
}

# ─── cmd: size ─────────────────────────────────────────────────────────────
cmd_size() {
  require_config
  local target=$(cfg_target)
  {
    printf '%s\t%s\t%s\n' SIZE NAME CLONE_ARGS
    for d in "$target"/*(N/); do
      local name="${d##*/}"
      [[ -d "$d/.git" || -f "$d/.git" ]] || continue
      local sz=$(du -sh "$d" 2>/dev/null | cut -f1)
      local sz_bytes=$(du -sk "$d" 2>/dev/null | cut -f1)
      # try to find which source this repo came from for clone_args
      local url=$(git -C "$d" remote get-url origin 2>/dev/null || true)
      local matched=""
      if [[ -n "$url" ]]; then
        matched=$(match_source_by_url "$url")
      fi
      local args=""
      if [[ -n "$matched" ]]; then
        local src=$(cfg_source_by_name "$matched")
        args=$(jq -r '.clone_args // [] | join(" ")' <<<"$src")
      fi
      # project override
      local proj=$(cfg_project_get "$name")
      local plen=$(jq -r '.clone_args // [] | length' <<<"$proj")
      [[ "$plen" -gt 0 ]] && args=$(jq -r '.clone_args | join(" ")' <<<"$proj")"  (override)"
      printf '%s\t%s\t%s\t%s\n' "$sz_bytes" "$sz" "$name" "${args:--}"
    done | sort -rn | cut -f2-
  } | column -t -s $'\t'
}

# ─── cmd: init-remote ──────────────────────────────────────────────────────
cmd_init_remote() {
  local name="${1:-}"
  [[ -z "$name" ]] && die "Usage: ws init-remote <name>"
  require_config
  local src=$(cfg_source_by_name "homelab")
  [[ -z "$src" ]] && die "no 'homelab' source in config"
  local host=$(jq -r '.host' <<<"$src")
  local path=$(jq -r '.path' <<<"$src")
  info "ssh $host: mkdir -p $path && git init --bare $path/${name}.git"
  ssh "$host" "mkdir -p $path && cd $path && git init --bare ${name}.git" \
    && ok "created ${host}:${path}/${name}.git"
}

# ─── cmd: reclone ──────────────────────────────────────────────────────────
cmd_reclone() {
  local name="${1:-}"
  [[ -z "$name" ]] && die "Usage: ws reclone <name>"
  require_config
  local target=$(cfg_target)
  local dir="$target/$name"
  [[ -d "$dir/.git" || -f "$dir/.git" ]] || die "$name is not a git repo at $dir"

  local url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  [[ -z "$url" ]] && die "$name has no origin URL"
  local sname=$(match_source_by_url "$url")
  [[ -z "$sname" ]] && die "$name origin doesn't match any configured source; refusing to reclone"
  local src=$(cfg_source_by_name "$sname")

  local -a clone_args=("${(@f)$(resolve_clone_args "$name" "$src")}")
  [[ ${#clone_args[@]} -eq 1 && -z "${clone_args[1]}" ]] && clone_args=()

  local stamp=$(date +%s)
  local bak="${dir}.bak-${stamp}"
  info "backing up $dir -> $bak"
  mv "$dir" "$bak"

  info "running: git clone ${clone_args[*]} $url $dir"
  if ! git clone "${clone_args[@]}" "$url" "$dir"; then
    err "reclone failed; restoring backup"
    rm -rf "$dir"
    mv "$bak" "$dir"
    return 1
  fi

  local pc=$(project_post_clone "$name")
  if [[ -n "$pc" ]]; then
    print -r -- "$pc" | while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      (cd "$dir" && eval "$cmd")
    done
  fi

  print -r -- "Backup at: $bak"
  print -nr -- "Delete backup? [y/N] "
  read -k 1 ans; print -r -- ""
  if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
    rm -rf "$bak"
    ok "backup removed"
  else
    info "backup preserved at $bak"
  fi
}

# ─── cmd: explain ──────────────────────────────────────────────────────────
cmd_explain() {
  local name="${1:-}"
  [[ -z "$name" ]] && die "Usage: ws explain <name>"
  require_config
  local target=$(cfg_target)
  local dir="$target/$name"

  print -r -- "${C_B}project: $name${C_0}"
  print -r -- "  path:  $dir"

  if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then
    local url=$(git -C "$dir" remote get-url origin 2>/dev/null || print -r -- "(none)")
    print -r -- "  origin: $url"
    local sname=$(match_source_by_url "$url")
    print -r -- "  matched source: ${sname:-(none)}"
  else
    print -r -- "  origin: (not a git repo)"
  fi

  local proj=$(cfg_project_get "$name")
  if [[ "$proj" != "{}" ]]; then
    print -r -- "  project config:"
    print -r -- "$proj" | jq . | sed 's/^/    /'
  else
    print -r -- "  project config: (none — uses source defaults)"
  fi

  # effective clone_args
  local sname2=""
  if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then
    local url2=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
    sname2=$(match_source_by_url "$url2")
  fi
  if [[ -n "$sname2" ]]; then
    local src=$(cfg_source_by_name "$sname2")
    print -r -- "  effective clone_args:"
    resolve_clone_args "$name" "$src" | sed 's/^/    /'
  fi

  # data surfaces
  local dcount=$(jq -r '.data // [] | length' <<<"$proj")
  if [[ "$dcount" -gt 0 ]]; then
    print -r -- "  data surfaces:"
    jq -c '.data[]' <<<"$proj" | while IFS= read -r ds; do
      print -r -- "    - $ds"
    done
  fi
}

# ─── cmd: init ─────────────────────────────────────────────────────────────
cmd_init() {
  info "initializing ws install at $WS_HOME"

  # ensure ~/.local/bin
  mkdir -p "$(dirname "$WS_BIN_LINK")"
  if [[ -L "$WS_BIN_LINK" && "$(readlink "$WS_BIN_LINK")" == "$WS_HOME/ws" ]]; then
    ok "PATH symlink already correct: $WS_BIN_LINK"
  elif [[ -e "$WS_BIN_LINK" ]]; then
    warn "$WS_BIN_LINK exists and isn't our symlink — leaving it alone"
  else
    ln -s "$WS_HOME/ws" "$WS_BIN_LINK"
    ok "linked $WS_BIN_LINK -> $WS_HOME/ws"
  fi

  # config from example
  if [[ -f "$CONFIG" ]]; then
    ok "config exists: $CONFIG"
  elif [[ -f "$WS_CONFIG_EXAMPLE" ]]; then
    cp "$WS_CONFIG_EXAMPLE" "$CONFIG"
    ok "created config from template: $CONFIG (edit before first sync)"
  else
    warn "no config.example.json found; you'll need to create $CONFIG manually"
  fi

  # workspace dir
  local target=""
  if [[ -f "$CONFIG" ]]; then
    target=$(cfg_target 2>/dev/null || expand_path "~/workspace")
  else
    target=$(expand_path "~/workspace")
  fi
  mkdir -p "$target"
  ok "workspace dir: $target"

  # completion hint — respect ZDOTDIR
  local zdir="${ZDOTDIR:-$HOME}"
  local zshrc="$zdir/.zshrc"
  if [[ -f "$zshrc" ]] && grep -q "$WS_COMPLETIONS_DIR" "$zshrc" 2>/dev/null; then
    ok "zsh completion already wired in $zshrc"
  elif [[ -f "$zshrc" ]]; then
    info "to enable tab-completion, add this line to $zshrc:"
    print -r -- ""
    print -r -- "    fpath=($WS_COMPLETIONS_DIR \$fpath); autoload -U compinit && compinit"
    print -r -- ""
  else
    info "to enable tab-completion, add to your .zshrc (or whichever rc you use):"
    print -r -- ""
    print -r -- "    fpath=($WS_COMPLETIONS_DIR \$fpath); autoload -U compinit && compinit"
    print -r -- ""
  fi

  ok "init complete. Next: \$EDITOR $CONFIG  then  ws sync"
}

# ─── cmd: upgrade ──────────────────────────────────────────────────────────
cmd_upgrade() {
  [[ -d "$WS_HOME/.git" ]] || die "$WS_HOME is not a git repo; can't upgrade"
  info "git -C $WS_HOME pull --ff-only"
  git -C "$WS_HOME" pull --ff-only || die "upgrade failed (non-ff or network)"
  cmd_version
}

# ─── cmd: data ─────────────────────────────────────────────────────────────
cmd_data() {
  local sub="${1:-status}"
  shift || true

  local dry=0 delete=0 itemize=0
  local -a positional
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --delete)  delete=1; shift ;;
      --itemize) itemize=1; shift ;;
      *) positional+=("$1"); shift ;;
    esac
  done

  local project_filter="${positional[1]:-}"

  case "$sub" in
    status|plan|link|pull|push) ;;
    *) die "ws data: unknown subcommand '$sub' (status|link|pull|push|plan)" ;;
  esac

  require_config
  local target=$(cfg_target)

  # iterate projects with .data[]
  jq -r '.projects // {} | to_entries | .[] | select(.value.data != null) | .key' < "$CONFIG" \
    | while IFS= read -r pname; do
        [[ -n "$project_filter" && "$pname" != "$project_filter" ]] && continue
        local proj=$(cfg_project_get "$pname")
        jq -c '.data[]' <<<"$proj" | while IFS= read -r surface; do
          data_one "$sub" "$pname" "$surface" "$dry" "$delete" "$itemize"
        done
      done
}

data_one() {
  local sub="$1" pname="$2" surface="$3" dry="$4" delete="$5" itemize="$6"
  local target=$(cfg_target)
  local path=$(jq -r '.path' <<<"$surface")
  local mode=$(jq -r '.mode' <<<"$surface")
  local source=$(jq -r '.source' <<<"$surface")
  local remote=$(jq -r '.remote // empty' <<<"$surface")
  local local_path=$(jq -r '.local // empty' <<<"$surface")
  local direction=$(jq -r '.direction // "pull-only"' <<<"$surface")
  local repo_dir="$target/$pname"
  local link_path="$repo_dir/$path"

  local ds=$(cfg_data_source_by_name "$source")
  [[ -z "$ds" ]] && { err "$pname:$path references unknown data source '$source'"; return 1; }
  local ds_type=$(jq -r '.type' <<<"$ds")

  case "$mode" in
    link)
      [[ "$ds_type" != "mount-link" ]] && warn "$pname:$path mode=link expects mount-link source (got $ds_type)"
      local mount_root=$(jq -r '.mount_root // empty' <<<"$ds")
      local resolved_local=$(expand_path "$local_path")

      case "$sub" in
        status|plan)
          if [[ ! -d "$mount_root" ]]; then
            print -r -- "  ${C_Y}$pname:$path${C_0}  link  mount missing ($mount_root)"
          elif [[ ! -e "$resolved_local" ]]; then
            print -r -- "  ${C_Y}$pname:$path${C_0}  link  source missing ($resolved_local)"
          elif [[ -L "$link_path" && "$(readlink "$link_path")" == "$resolved_local" ]]; then
            print -r -- "  ${C_G}$pname:$path${C_0}  link  ok -> $resolved_local"
          elif [[ -e "$link_path" ]]; then
            print -r -- "  ${C_R}$pname:$path${C_0}  link  conflicting non-link exists at $link_path"
          else
            print -r -- "  ${C_Y}$pname:$path${C_0}  link  needs creation -> $resolved_local"
          fi
          ;;
        link)
          if [[ ! -d "$mount_root" ]]; then
            warn "$pname:$path mount missing: $mount_root — skipping"
            return 0
          fi
          if [[ ! -e "$resolved_local" ]]; then
            warn "$pname:$path source missing: $resolved_local — skipping"
            return 0
          fi
          if [[ -L "$link_path" && "$(readlink "$link_path")" == "$resolved_local" ]]; then
            return 0
          fi
          if [[ -e "$link_path" && ! -L "$link_path" ]]; then
            err "$pname:$path refusing to overwrite existing directory at $link_path"
            return 1
          fi
          if [[ "$dry" == "1" ]]; then
            print -r -- "  would link: $link_path -> $resolved_local"
            return 0
          fi
          [[ -d "$repo_dir" ]] || { warn "$pname: repo dir missing ($repo_dir); skipping link"; return 0; }
          ln -sf "$resolved_local" "$link_path"
          ok "linked $link_path -> $resolved_local"
          ;;
        pull|push)
          warn "$pname:$path mode=link does not support $sub; use ws data link"
          ;;
      esac
      ;;

    rsync)
      [[ "$ds_type" != "rsync-glob" ]] && warn "$pname:$path mode=rsync expects rsync-glob source (got $ds_type)"
      local host=$(jq -r '.host' <<<"$ds")
      local remote_path=$(jq -r '.remote_path' <<<"$ds")
      local -a rsync_args=("${(@f)$(jq -r '.rsync_args // ["-a","--partial"] | .[]' <<<"$ds")}")
      local -a excludes=()
      while IFS= read -r e; do
        [[ -n "$e" ]] && excludes+=(--exclude="$e")
      done < <(jq -r '.exclude // [] | .[]' <<<"$ds")
      [[ "$itemize" == "1" ]] && rsync_args+=(--itemize-changes)
      local resolved_local=$(expand_path "$local_path")
      local resolved_remote="${host}:${remote_path}/${remote}/"

      case "$sub" in
        status|plan)
          local existsmark="—"
          [[ -d "$resolved_local" ]] && existsmark="cached $(du -sh "$resolved_local" 2>/dev/null | cut -f1)"
          if [[ "$sub" == "plan" ]]; then
            print -r -- "  ${pname}:${path}"
            print -r -- "    pull: rsync ${rsync_args[*]} ${excludes[*]} ${resolved_remote} ${resolved_local}/"
            [[ "$direction" == "push-explicit" ]] && \
              print -r -- "    push: rsync ${rsync_args[*]} ${excludes[*]} ${resolved_local}/ ${resolved_remote}"
          else
            print -r -- "  ${C_G}$pname:$path${C_0}  rsync  $existsmark  (direction=$direction)"
          fi
          ;;
        pull)
          mkdir -p "$resolved_local"
          local -a final_args=("${rsync_args[@]}" "${excludes[@]}")
          [[ "$delete" == "1" ]] && final_args+=(--delete)
          [[ "$dry" == "1" ]] && final_args+=(--dry-run)
          info "rsync ${final_args[*]} ${resolved_remote} ${resolved_local}/"
          rsync "${final_args[@]}" "$resolved_remote" "$resolved_local/" \
            || { err "$pname:$path rsync pull failed"; return 1; }
          ;;
        push)
          [[ "$direction" != "push-explicit" ]] && { err "$pname:$path push not allowed (direction=$direction)"; return 1; }
          local -a final_args=("${rsync_args[@]}" "${excludes[@]}")
          [[ "$delete" == "1" ]] && final_args+=(--delete)
          # always dry-run first
          info "DRY: rsync ${final_args[*]} --dry-run ${resolved_local}/ ${resolved_remote}"
          rsync "${final_args[@]}" --dry-run "$resolved_local/" "$resolved_remote" \
            || { err "$pname:$path rsync dry push failed"; return 1; }
          if [[ "$dry" == "1" ]]; then
            return 0
          fi
          print -nr -- "Proceed with real push? [y/N] "
          read -k 1 ans; print -r -- ""
          [[ "$ans" != "y" && "$ans" != "Y" ]] && { info "aborted"; return 0; }
          rsync "${final_args[@]}" "$resolved_local/" "$resolved_remote" \
            || { err "$pname:$path rsync push failed"; return 1; }
          ;;
        link)
          warn "$pname:$path mode=rsync does not support link; use mode=link with mount-link source"
          ;;
      esac
      ;;
  esac
}

# ─── dispatch ──────────────────────────────────────────────────────────────
main() {
  parse_global_flags "$@"
  set -- "${POSITIONALS[@]}"

  local cmd="${1:-help}"
  [[ $# -gt 0 ]] && shift

  case "$cmd" in
    help|"")        print_help ;;
    --version)      cmd_version ;;
    version)        cmd_version ;;
    init)           cmd_init "$@" ;;
    upgrade)        cmd_upgrade "$@" ;;
    sync)           cmd_sync "$@" ;;
    new)            cmd_new "$@" ;;
    clone)          cmd_clone "$@" ;;
    git)            cmd_git "$@" ;;
    _git_one)       cmd__git_one "$@" ;;
    status)         cmd_status "$@" ;;
    list)           cmd_list "$@" ;;
    cd)             cmd_cd "$@" ;;
    push)           cmd_push "$@" ;;
    pull)           cmd_pull "$@" ;;
    prune)          cmd_prune "$@" ;;
    stale)          cmd_stale "$@" ;;
    size)           cmd_size "$@" ;;
    init-remote)    cmd_init_remote "$@" ;;
    reclone)        cmd_reclone "$@" ;;
    explain)        cmd_explain "$@" ;;
    data)           cmd_data "$@" ;;
    *)              die "unknown command: $cmd (try 'ws --help')" ;;
  esac
}

main "$@"
