#!/usr/bin/env python3
"""ws — async workspace sync over GitHub, Tailscale git, and server-backed data."""

from __future__ import annotations

import argparse
import asyncio
import fnmatch
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


if hasattr(signal, "SIGPIPE"):
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)


WS_VERSION = "0.3.1"
WS_HOME = Path.home() / ".config" / "ws"
DEFAULT_CONFIG = WS_HOME / "config.json"
CONFIG_EXAMPLE = WS_HOME / "config.example.json"
BIN_LINK = Path.home() / ".local" / "bin" / "ws"

READ_JOBS = 32
STATUS_JOBS = 16
NETWORK_JOBS = 8
PUSH_JOBS = 4


@dataclass
class RunResult:
    args: list[str]
    returncode: int
    stdout: str = ""
    stderr: str = ""
    cwd: Path | None = None


@dataclass
class RepoSpec:
    name: str
    url: str
    source: dict[str, Any] = field(default_factory=dict)


@dataclass
class RepoStatus:
    name: str
    path: Path
    branch: str = ""
    upstream: str = ""
    dirty: int = 0
    ahead: int = 0
    behind: int = 0
    failed: bool = False
    error: str = ""
    raw: str = ""

    @property
    def clean(self) -> bool:
        return not self.failed and self.dirty == 0 and self.ahead == 0 and self.behind == 0

    @property
    def diverged(self) -> bool:
        return self.ahead > 0 and self.behind > 0

    def to_json(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "path": str(self.path),
            "branch": self.branch,
            "upstream": self.upstream,
            "dirty": self.dirty,
            "ahead": self.ahead,
            "behind": self.behind,
            "diverged": self.diverged,
            "failed": self.failed,
            "error": self.error,
        }


class UI:
    def __init__(self, color: bool, verbose: bool = False, json_mode: bool = False) -> None:
        self.color = color
        self.verbose = verbose
        self.json_mode = json_mode

    def c(self, name: str, text: str) -> str:
        if not self.color:
            return text
        codes = {
            "red": "\033[31m",
            "green": "\033[32m",
            "yellow": "\033[33m",
            "blue": "\033[34m",
            "muted": "\033[2m",
            "bold": "\033[1m",
        }
        return f"{codes.get(name, '')}{text}\033[0m"

    def print(self, text: str = "") -> None:
        print(text)

    def err(self, text: str) -> None:
        print(f"{self.c('red', 'ws:')} {text}", file=sys.stderr)

    def warn(self, text: str) -> None:
        print(f"{self.c('yellow', 'ws:')} {text}", file=sys.stderr)

    def info(self, text: str) -> None:
        if self.verbose:
            print(f"{self.c('blue', 'ws:')} {text}", file=sys.stderr)

    def ok(self, text: str) -> None:
        print(f"{self.c('green', 'ws:')} {text}", file=sys.stderr)


class WsError(Exception):
    pass


def expand_path(value: str) -> Path:
    # Do not resolve symlinks here: data mounts may contain absolute symlinks
    # that are valid on nitai (/data/...) but intentionally viewed through a
    # different mount root on macOS (/Volumes/data/...).
    return Path(os.path.expandvars(os.path.expanduser(value)))


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise WsError(f"config missing: {path}")
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise WsError(f"config is not valid JSON: {path}: {exc}") from exc


def target_dir(config: dict[str, Any]) -> Path:
    return expand_path(str(config.get("target") or "~/workspace"))


def skipped(config: dict[str, Any], name: str) -> bool:
    if name in set(config.get("skip_list") or []):
        return True
    legacy = (config.get("projects") or {}).get(name) or {}
    return bool(legacy.get("skip"))


def project_legacy(config: dict[str, Any], name: str) -> dict[str, Any]:
    return dict((config.get("projects") or {}).get(name) or {})


def project_override(config: dict[str, Any], name: str) -> dict[str, Any]:
    return dict((config.get("clone_overrides") or {}).get(name) or {})


def read_repo_config(repo: Path) -> dict[str, Any]:
    path = repo / ".ws.json"
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except json.JSONDecodeError:
        return {}


def data_source(config: dict[str, Any], name: str) -> dict[str, Any] | None:
    for source in config.get("data_sources") or []:
        if source.get("name") == name:
            return source
    return None


def canonical_repo_url(url: str) -> str:
    value = url.strip()
    if value.endswith(".git"):
        value = value[:-4]
    if value.startswith("git@github.com:"):
        return "github.com/" + value.removeprefix("git@github.com:")
    if value.startswith("ssh://git@github.com/"):
        return "github.com/" + value.removeprefix("ssh://git@github.com/")
    if value.startswith("https://github.com/"):
        return "github.com/" + value.removeprefix("https://github.com/")
    if value.startswith("http://github.com/"):
        return "github.com/" + value.removeprefix("http://github.com/")
    token_match = re.match(r"https://[^@]+@github\.com/(.+)", value)
    if token_match:
        return "github.com/" + token_match.group(1)
    return value


def urls_equivalent(a: str, b: str) -> bool:
    return canonical_repo_url(a) == canonical_repo_url(b)


def source_pattern(source: dict[str, Any]) -> str:
    stype = source.get("type")
    if stype == "github-list":
        return rf"github\.com[:/]{re.escape(str(source.get('owner', '')))}/"
    if stype == "ssh-glob":
        return re.escape(f"{source.get('host')}:{source.get('path')}")
    return ""


def repo_matches_source(origin: str, source: dict[str, Any]) -> bool:
    pattern = source_pattern(source)
    return bool(pattern and re.search(pattern, origin))


def is_git_repo(path: Path) -> bool:
    return (path / ".git").exists()


def is_workspace_symlink(path: Path) -> bool:
    return os.path.islink(path)


def path_exists_or_link(path: Path) -> bool:
    return os.path.lexists(path)


def local_repos(config: dict[str, Any], only: str = "", source_filter: str = "") -> list[Path]:
    target = target_dir(config)
    if not target.exists():
        return []
    sources = {s.get("name"): s for s in config.get("sources") or []}
    repos: list[Path] = []
    for child in sorted(target.iterdir(), key=lambda p: p.name.lower()):
        if not is_git_repo(child) or skipped(config, child.name):
            continue
        if only and not fnmatch.fnmatch(child.name, only):
            continue
        if source_filter:
            src = sources.get(source_filter)
            if not src:
                continue
            origin = subprocess.run(
                ["git", "-C", str(child), "remote", "get-url", "origin"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            ).stdout.strip()
            if not origin or not repo_matches_source(origin, src):
                continue
        repos.append(child)
    return repos


def current_repo(config: dict[str, Any]) -> Path | None:
    target = target_dir(config)
    try:
        cwd = Path.cwd().resolve()
        rel = cwd.relative_to(target)
    except ValueError:
        return None
    if not rel.parts:
        return None
    repo = target / rel.parts[0]
    return repo if is_git_repo(repo) else None


async def run_cmd(
    args: list[str],
    cwd: Path | None = None,
    timeout: float | None = None,
    input_text: str | None = None,
) -> RunResult:
    proc = await asyncio.create_subprocess_exec(
        *args,
        cwd=str(cwd) if cwd else None,
        stdin=asyncio.subprocess.PIPE if input_text is not None else None,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout_b, stderr_b = await asyncio.wait_for(
            proc.communicate(input_text.encode() if input_text is not None else None),
            timeout=timeout,
        )
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return RunResult(args, 124, "", "timeout", cwd)
    return RunResult(
        args=args,
        returncode=proc.returncode or 0,
        stdout=stdout_b.decode("utf-8", "replace"),
        stderr=stderr_b.decode("utf-8", "replace"),
        cwd=cwd,
    )


async def gather_limited(items: list[Any], jobs: int, fn):
    sem = asyncio.Semaphore(max(1, jobs))

    async def one(item):
        async with sem:
            return await fn(item)

    return await asyncio.gather(*(one(item) for item in items))


async def git(repo: Path, *args: str) -> RunResult:
    return await run_cmd(["git", "-C", str(repo), *args])


async def repo_status(repo: Path) -> RepoStatus:
    status = await git(repo, "status", "--porcelain=v1", "-b")
    rs = RepoStatus(name=repo.name, path=repo)
    if status.returncode != 0:
        rs.failed = True
        rs.error = (status.stderr or status.stdout).strip()
        return rs
    rs.raw = status.stdout.rstrip()
    lines = status.stdout.splitlines()
    if lines:
        first = lines[0].removeprefix("## ").strip()
        if "..." in first:
            rs.branch, rest = first.split("...", 1)
            rs.upstream = rest.split(" ", 1)[0]
        else:
            rs.branch = first.split(" ", 1)[0]
        bracket = re.search(r"\[(.*?)\]", first)
        if bracket:
            for part in bracket.group(1).split(","):
                part = part.strip()
                if part.startswith("ahead "):
                    rs.ahead = int(part.removeprefix("ahead ").strip() or "0")
                elif part.startswith("behind "):
                    rs.behind = int(part.removeprefix("behind ").strip() or "0")
    rs.dirty = sum(1 for line in lines[1:] if line.strip())
    return rs


def render_status(ui: UI, statuses: list[RepoStatus], verbose: bool = False) -> None:
    failed = [s for s in statuses if s.failed]
    dirty = [s for s in statuses if s.dirty and not s.failed]
    ahead = [s for s in statuses if s.ahead and not s.failed]
    behind = [s for s in statuses if s.behind and not s.failed]
    clean = [s for s in statuses if s.clean]

    if verbose:
        for s in statuses:
            ui.print(f"{ui.c('green' if s.clean else 'yellow', s.name)}:")
            if s.failed:
                ui.print(f"  failed: {s.error}")
            elif s.raw:
                for line in s.raw.splitlines():
                    ui.print(f"  {line}")
            else:
                ui.print(f"  ## {s.branch or '?'}")
        return

    health = "OK" if not failed and not dirty and not ahead and not behind else "Needs attention"
    ui.print(f"Workspace status: {ui.c('green' if health == 'OK' else 'yellow', health)}")
    ui.print("")
    ui.print(f"Repos checked: {len(statuses)}")
    ui.print(f"Clean:         {len(clean)}")
    ui.print(f"Dirty:         {len(dirty)}")
    ui.print(f"Ahead:         {len(ahead)}")
    ui.print(f"Behind:        {len(behind)}")
    ui.print(f"Failed:        {len(failed)}")

    anomalies: list[RepoStatus] = []
    seen: set[str] = set()
    for group in (failed, dirty, ahead, behind):
        for item in group:
            if item.name not in seen:
                seen.add(item.name)
                anomalies.append(item)

    if anomalies:
        ui.print("")
        ui.print(ui.c("bold", "Attention"))
        for s in anomalies:
            bits = []
            if s.failed:
                bits.append(ui.c("red", "failed"))
            if s.dirty:
                bits.append(ui.c("yellow", f"{s.dirty} dirty"))
            if s.ahead:
                bits.append(ui.c("blue", f"ahead {s.ahead}"))
            if s.behind:
                bits.append(ui.c("yellow", f"behind {s.behind}"))
            if s.diverged:
                bits.append(ui.c("red", "diverged"))
            ui.print(f"  {s.name:<34} {'; '.join(bits)}")


async def cmd_status(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    verbose = ui.verbose or "--all" in args
    repos = local_repos(config)
    statuses = await gather_limited(repos, jobs or STATUS_JOBS, repo_status)
    statuses = sorted(statuses, key=lambda s: s.name.lower())
    if ui.json_mode:
        for s in statuses:
            print(json.dumps(s.to_json(), sort_keys=True))
    else:
        render_status(ui, statuses, verbose=verbose)
    return 1 if any(s.failed for s in statuses) else 0


async def discover_github(source: dict[str, Any]) -> list[RepoSpec]:
    owner = str(source.get("owner") or "")
    clone_protocol = str(source.get("clone_protocol") or "https")
    result = await run_cmd(
        [
            "gh",
            "repo",
            "list",
            owner,
            "--limit",
            "1000",
            "--json",
            "name,url,sshUrl,isArchived,isFork",
        ]
    )
    if result.returncode != 0:
        raise WsError(f"gh repo list failed for {owner}: {result.stderr.strip()}")
    repos = json.loads(result.stdout or "[]")
    specs: list[RepoSpec] = []
    for item in repos:
        if source.get("skip_archived") and item.get("isArchived"):
            continue
        if source.get("skip_forks") and item.get("isFork"):
            continue
        url = item.get("sshUrl") if clone_protocol == "ssh" else item.get("url")
        if item.get("name") and url:
            specs.append(RepoSpec(name=item["name"], url=url, source=source))
    return specs


async def discover_sshglob(source: dict[str, Any]) -> list[RepoSpec]:
    host = str(source.get("host") or "")
    root = str(source.get("path") or "")
    glob = str(source.get("glob") or "*.git")
    script = f'for d in "{root}"/{glob}; do [ -e "$d" ] || continue; basename "$d"; done'
    result = await run_cmd(["ssh", host, script])
    if result.returncode != 0:
        raise WsError(f"ssh-glob discovery failed for {source.get('name')}: {result.stderr.strip()}")
    specs = []
    for line in result.stdout.splitlines():
        base = line.strip()
        if not base:
            continue
        name = base[:-4] if base.endswith(".git") else base
        specs.append(RepoSpec(name=name, url=f"{host}:{root.rstrip('/')}/{base}", source=source))
    return specs


async def discover_all_code(config: dict[str, Any], source_filter: str = "", only: str = "") -> list[RepoSpec]:
    specs: list[RepoSpec] = []
    for source in config.get("sources") or []:
        if source_filter and source.get("name") != source_filter:
            continue
        stype = source.get("type")
        if stype == "github-list":
            found = await discover_github(source)
        elif stype == "ssh-glob":
            found = await discover_sshglob(source)
        else:
            continue
        for spec in found:
            if skipped(config, spec.name):
                continue
            if only and not fnmatch.fnmatch(spec.name, only):
                continue
            specs.append(spec)
    by_name = {spec.name: spec for spec in specs}
    return [by_name[k] for k in sorted(by_name, key=str.lower)]


def clone_args(config: dict[str, Any], spec: RepoSpec) -> list[str]:
    override = project_override(config, spec.name)
    legacy = project_legacy(config, spec.name)
    if isinstance(override.get("clone_args"), list):
        return [str(x) for x in override["clone_args"]]
    if isinstance(legacy.get("clone_args"), list):
        return [str(x) for x in legacy["clone_args"]]
    return [str(x) for x in spec.source.get("clone_args") or []]


def fetch_args(spec: RepoSpec) -> list[str]:
    return [str(x) for x in spec.source.get("fetch_args") or []]


def project_data_surfaces(config: dict[str, Any], repo: Path) -> list[dict[str, Any]]:
    repo_cfg = read_repo_config(repo)
    repo_data = repo_cfg.get("data")
    if isinstance(repo_data, list) and repo_data:
        return [x for x in repo_data if isinstance(x, dict)]
    legacy = project_legacy(config, repo.name)
    legacy_data = legacy.get("data")
    if isinstance(legacy_data, list):
        return [x for x in legacy_data if isinstance(x, dict)]
    return []


def resolve_link_target(config: dict[str, Any], project: str, surface: dict[str, Any]) -> Path | None:
    source_name = str(surface.get("source") or "")
    ds = data_source(config, source_name)
    if not ds:
        return None
    local_path = str(surface.get("local") or "")
    remote = str(surface.get("remote") or "")
    mount_root = str(ds.get("mount_root") or "")
    if local_path:
        return expand_path(local_path)
    if remote and mount_root:
        return expand_path(str(Path(mount_root) / remote))
    if mount_root:
        return expand_path(str(Path(mount_root) / project / str(surface.get("path") or ".")))
    return None


async def materialize_project_links(config: dict[str, Any], repo: Path, dry_run: bool = False) -> dict[str, int]:
    stats = {"ok": 0, "linked": 0, "needs": 0, "missing": 0, "conflict": 0, "skipped": 0}
    for surface in project_data_surfaces(config, repo):
        if surface.get("mode") != "link":
            stats["skipped"] += 1
            continue
        surface_path = str(surface.get("path") or ".")
        source_name = str(surface.get("source") or "")
        ds = data_source(config, source_name)
        target = resolve_link_target(config, repo.name, surface)
        if not ds or not target:
            stats["missing"] += 1
            continue
        mount_root = expand_path(str(ds.get("mount_root") or ""))
        link_path = repo / surface_path
        if not mount_root.exists() or not path_exists_or_link(target):
            stats["missing"] += 1
            continue
        if link_path.is_symlink() and os.readlink(link_path) == str(target):
            stats["ok"] += 1
            continue
        if path_exists_or_link(link_path) and not link_path.is_symlink():
            stats["conflict"] += 1
            continue
        if dry_run:
            stats["needs"] += 1
            continue
        link_path.parent.mkdir(parents=True, exist_ok=True)
        if link_path.is_symlink() or path_exists_or_link(link_path):
            link_path.unlink()
        os.symlink(str(target), str(link_path))
        stats["linked"] += 1
    return stats


def root_alias_specs(config: dict[str, Any], only: str = "", source_filter: str = "") -> list[tuple[str, Path, str]]:
    specs = []
    for ds in config.get("data_sources") or []:
        if ds.get("type") != "mount-link" or ds.get("root_aliases", True) is False:
            continue
        if source_filter and ds.get("name") != source_filter:
            continue
        mount_root = expand_path(str(ds.get("mount_root") or ""))
        if not mount_root.exists():
            continue
        for child in sorted(mount_root.iterdir(), key=lambda p: p.name.lower()):
            if not child.is_dir() or child.name.startswith("."):
                continue
            if skipped(config, child.name):
                continue
            if only and not fnmatch.fnmatch(child.name, only):
                continue
            specs.append((child.name, child, str(ds.get("name") or "")))
    return specs


def root_alias_status(config: dict[str, Any], name: str, target_path: Path) -> str:
    link = target_dir(config) / name
    if not target_path.exists():
        return "source-missing"
    if link.is_symlink() and os.readlink(link) == str(target_path):
        return "ok"
    if path_exists_or_link(link):
        return "skipped"
    return "needs"


def materialize_root_alias(config: dict[str, Any], name: str, target_path: Path, dry_run: bool = False) -> str:
    link = target_dir(config) / name
    state = root_alias_status(config, name, target_path)
    if state != "needs":
        return state
    if dry_run:
        return "needs"
    link.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(str(target_path), str(link))
    return "linked"


async def sync_one(config: dict[str, Any], spec: RepoSpec, dry: bool, verbose: bool) -> tuple[str, str, str]:
    target = target_dir(config)
    repo = target / spec.name
    if not repo.exists() and not repo.is_symlink():
        if dry:
            return ("would-clone", spec.name, "")
        result = await run_cmd(["git", "clone", *clone_args(config, spec), spec.url, str(repo)])
        if result.returncode != 0:
            return ("failed", spec.name, result.stderr.strip() or result.stdout.strip())
        await materialize_project_links(config, repo)
        return ("cloned", spec.name, "")

    if not is_git_repo(repo):
        return ("skip-nogit", spec.name, "")

    origin = await git(repo, "remote", "get-url", "origin")
    if origin.returncode == 0 and origin.stdout.strip() and not urls_equivalent(origin.stdout.strip(), spec.url):
        return ("skip-collision", spec.name, f"have {origin.stdout.strip()}, expected {spec.url}")

    if dry:
        return ("would-fetch", spec.name, "")
    result = await git(repo, "fetch", "--all", *fetch_args(spec), "--quiet")
    if result.returncode != 0:
        return ("failed", spec.name, result.stderr.strip() or result.stdout.strip())
    await materialize_project_links(config, repo)
    return ("fetched", spec.name, "")


async def cmd_sync(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    dry = "--dry-run" in args
    source_filter = ""
    only = ""
    i = 0
    while i < len(args):
        if args[i] == "--source" and i + 1 < len(args):
            source_filter = args[i + 1]
            i += 2
        elif args[i] == "--only" and i + 1 < len(args):
            only = args[i + 1]
            i += 2
        else:
            i += 1
    specs = await discover_all_code(config, source_filter, only)
    target_dir(config).mkdir(parents=True, exist_ok=True)

    async def one(spec: RepoSpec):
        return await sync_one(config, spec, dry=dry, verbose=ui.verbose)

    results = await gather_limited(specs, jobs or NETWORK_JOBS, one)
    counts: dict[str, int] = {}
    failures: list[tuple[str, str]] = []
    for kind, name, detail in results:
        counts[kind] = counts.get(kind, 0) + 1
        if ui.verbose or kind in {"cloned", "failed", "skip-collision", "skip-nogit"}:
            if dry and kind == "would-fetch" and not ui.verbose:
                pass
            else:
                ui.print(f"{kind.replace('-', ' ')}: {name}{f' ({detail})' if detail else ''}")
        if kind == "failed":
            failures.append((name, detail))

    alias_counts: dict[str, int] = {}
    for name, path, _source in root_alias_specs(config, only=only, source_filter=source_filter):
        state = materialize_root_alias(config, name, path, dry_run=dry)
        alias_counts[state] = alias_counts.get(state, 0) + 1
        if ui.verbose and state in {"needs", "linked"}:
            ui.print(f"{'would link data' if dry else 'linked data'}: {name} -> {path}")

    if ui.json_mode:
        print(json.dumps({"repos": counts, "data_aliases": alias_counts}, sort_keys=True))
        return 1 if failures else 0

    ui.print("")
    ui.print(ui.c("bold", "ws sync summary"))
    ui.print("─────────────────────────────────")
    ui.print(f"  considered:       {len(specs)}")
    if dry:
        ui.print(f"  would clone:      {counts.get('would-clone', 0)}")
        ui.print(f"  remote checks:    {counts.get('would-fetch', 0)}")
        ui.print(f"  would link data:  {alias_counts.get('needs', 0)}")
    else:
        ui.print(f"  cloned:           {counts.get('cloned', 0)}")
        ui.print(f"  fetched:          {counts.get('fetched', 0)}")
        ui.print(f"  data linked:      {alias_counts.get('linked', 0)}")
        ui.print(f"  skipped:          {counts.get('skip-collision', 0) + counts.get('skip-nogit', 0)}")
        ui.print(f"  failed:           {counts.get('failed', 0)}")
    if failures:
        ui.print("")
        for name, detail in failures[:10]:
            ui.print(f"  {ui.c('red', name)}: {detail}")
    return 1 if failures else 0


async def cmd_pull(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    if "--safe" not in args:
        ui.err("ws pull requires --safe; use `ws git --all pull` for raw git pull")
        return 2
    repos = local_repos(config)
    statuses = await gather_limited(repos, jobs or STATUS_JOBS, repo_status)
    pullable = [s for s in statuses if not s.failed and s.dirty == 0 and s.behind > 0 and s.ahead == 0]
    skipped_dirty = [s for s in statuses if s.dirty]
    skipped_diverged = [s for s in statuses if s.diverged]
    failed: list[tuple[str, str]] = []

    async def pull_one(status: RepoStatus):
        result = await git(status.path, "pull", "--ff-only")
        return status.name, result

    pulled = 0
    for name, result in await gather_limited(pullable, jobs or NETWORK_JOBS, pull_one):
        if result.returncode == 0:
            pulled += 1
            if ui.verbose:
                ui.print(f"pulled: {name}")
        else:
            failed.append((name, result.stderr.strip() or result.stdout.strip()))

    attention_names = {s.name for s in pullable}
    attention_names.update(s.name for s in skipped_dirty)
    attention_names.update(s.name for s in skipped_diverged)
    attention_names.update(name for name, _detail in failed)
    already_current = max(0, len(statuses) - len(attention_names))

    ui.print("Safe pull complete.")
    ui.print("")
    ui.print(f"Fast-forwarded:   {pulled}")
    ui.print(f"Already/current:  {already_current}")
    ui.print(f"Skipped dirty:    {len(skipped_dirty)}")
    ui.print(f"Skipped diverged: {len(skipped_diverged)}")
    ui.print(f"Failed:           {len(failed)}")
    if skipped_dirty or skipped_diverged or failed:
        ui.print("")
        for s in skipped_dirty:
            ui.print(f"  {ui.c('yellow', s.name)} skipped: dirty")
        for s in skipped_diverged:
            ui.print(f"  {ui.c('red', s.name)} skipped: diverged")
        for name, detail in failed:
            ui.print(f"  {ui.c('red', name)} failed: {detail}")
    return 1 if failed else 0


async def cmd_git(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    source_filter = ""
    only = ""
    force_all = False
    fail_fast = False
    passthru: list[str] = []
    i = 0
    while i < len(args):
        if args[i] == "--source" and i + 1 < len(args):
            source_filter = args[i + 1]
            i += 2
        elif args[i] == "--only" and i + 1 < len(args):
            only = args[i + 1]
            i += 2
        elif args[i] == "--all":
            force_all = True
            i += 1
        elif args[i] == "--fail-fast":
            fail_fast = True
            i += 1
        elif args[i] == "--parallel" and i + 1 < len(args):
            jobs = int(args[i + 1])
            i += 2
        elif args[i] == "--":
            passthru.extend(args[i + 1 :])
            break
        else:
            passthru.append(args[i])
            i += 1
    if len(passthru) >= 2 and passthru[0] == "clone":
        return await cmd_clone(passthru[1:], config, ui)
    if not passthru:
        ui.err("ws git: missing git arguments")
        return 2
    repos: list[Path]
    scoped = current_repo(config)
    if scoped and not force_all and not source_filter and not only:
        repos = [scoped]
        ui.info(f"scoped to {scoped.name} (use --all for whole workspace)")
    else:
        repos = local_repos(config, only=only, source_filter=source_filter)

    async def one(repo: Path):
        result = await git(repo, *passthru)
        return repo.name, result

    rc = 0
    if fail_fast:
        for repo in repos:
            name, result = await one(repo)
            if result.stdout.strip():
                ui.print(f"{ui.c('green', name)}:")
                ui.print("\n".join(f"  {line}" for line in result.stdout.rstrip().splitlines()))
            if result.returncode != 0:
                ui.print(f"{ui.c('red', name)}:")
                ui.print("\n".join(f"  {line}" for line in (result.stderr or result.stdout).rstrip().splitlines()))
                return result.returncode
        return 0

    results = await gather_limited(repos, jobs or READ_JOBS, one)
    for name, result in results:
        out = result.stdout.rstrip()
        err = result.stderr.rstrip()
        if result.returncode != 0:
            rc = result.returncode
            ui.print(f"{ui.c('red', name)}:")
            if err or out:
                ui.print("\n".join(f"  {line}" for line in (err or out).splitlines()))
        elif out:
            ui.print(f"{ui.c('green', name)}:")
            ui.print("\n".join(f"  {line}" for line in out.splitlines()))
    return rc


def collect_data_surfaces(config: dict[str, Any], project_filter: str = "") -> list[tuple[Path, dict[str, Any]]]:
    target = target_dir(config)
    by_project: dict[str, Path] = {}
    if target.exists():
        for repo in target.iterdir():
            if repo.is_dir() and (repo / ".ws.json").exists():
                cfg = read_repo_config(repo)
                if isinstance(cfg.get("data"), list) and cfg.get("data"):
                    by_project[repo.name] = repo
    for name, value in (config.get("projects") or {}).items():
        if isinstance(value, dict) and isinstance(value.get("data"), list):
            by_project.setdefault(name, target / name)
    items = []
    for name, repo in sorted(by_project.items(), key=lambda kv: kv[0].lower()):
        if project_filter and name != project_filter:
            continue
        for surface in project_data_surfaces(config, repo):
            items.append((repo, surface))
    return items


def data_surface_state(config: dict[str, Any], repo: Path, surface: dict[str, Any]) -> dict[str, Any]:
    mode = surface.get("mode")
    path = str(surface.get("path") or ".")
    state = {
        "project": repo.name,
        "path": path,
        "mode": mode,
        "state": "unknown",
        "target": "",
    }
    if mode == "link":
        target = resolve_link_target(config, repo.name, surface)
        ds = data_source(config, str(surface.get("source") or ""))
        mount_root = expand_path(str(ds.get("mount_root") or "")) if ds else None
        link_path = repo / path
        state["target"] = str(target) if target else ""
        if not ds or not mount_root or not mount_root.exists():
            state["state"] = "mount-missing"
        elif not target:
            state["state"] = "unresolved"
        elif not path_exists_or_link(target):
            state["state"] = "source-missing"
        elif link_path.is_symlink() and os.readlink(link_path) == str(target):
            state["state"] = "ok"
        elif path_exists_or_link(link_path) and not link_path.is_symlink():
            state["state"] = "conflict"
        else:
            state["state"] = "needs-link"
    elif mode == "rsync":
        local_path = expand_path(str(surface.get("local") or ""))
        state["target"] = str(local_path)
        state["state"] = "cached" if local_path.exists() else "missing-cache"
    return state


async def cmd_data(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    sub = args[0] if args else "status"
    rest = args[1:] if args else []
    dry = "--dry-run" in rest
    positional = [a for a in rest if not a.startswith("--")]
    project_filter = positional[0] if positional else ""
    if sub not in {"status", "plan", "link", "pull", "push", "mount", "unmount", "remount"}:
        ui.err(f"ws data: unknown subcommand '{sub}'")
        return 2
    if sub in {"mount", "unmount", "remount"}:
        return await cmd_data_mount(sub, rest, config, ui)
    if sub in {"pull", "push"}:
        return await cmd_data_rsync(sub, rest, config, ui, jobs or NETWORK_JOBS)

    items = collect_data_surfaces(config, project_filter)
    async def state_one(item: tuple[Path, dict[str, Any]]) -> dict[str, Any]:
        repo, surface = item
        return await asyncio.to_thread(data_surface_state, config, repo, surface)

    states = await gather_limited(items, jobs or STATUS_JOBS, state_one)
    root_states = []
    if not project_filter and sub in {"status", "plan", "link"}:
        for name, path, source in root_alias_specs(config):
            root_states.append(
                {
                    "project": name,
                    "path": ".",
                    "mode": "root-link",
                    "state": root_alias_status(config, name, path),
                    "target": str(path),
                    "source": source,
                }
            )

    if sub == "link":
        linked = 0
        conflicts = 0
        for repo, surface in items:
            before = data_surface_state(config, repo, surface)
            if before["state"] == "conflict":
                conflicts += 1
            stats = await materialize_project_links(config, repo, dry_run=dry)
            linked += stats.get("linked", 0)
        for name, path, _source in root_alias_specs(config):
            result = materialize_root_alias(config, name, path, dry_run=dry)
            if result == "linked":
                linked += 1
        ui.print("Data link complete." if not dry else "Data link dry-run complete.")
        ui.print(f"Linked:    {linked}")
        ui.print(f"Conflicts: {conflicts}")
        return 1 if conflicts else 0

    all_states = states + root_states
    if ui.json_mode:
        for state in all_states:
            print(json.dumps(state, sort_keys=True))
        return 0
    counts: dict[str, int] = {}
    for state in all_states:
        counts[state["state"]] = counts.get(state["state"], 0) + 1
    mounts = [
        ds
        for ds in config.get("data_sources") or []
        if ds.get("type") == "mount-link"
    ]
    ui.print("Data status")
    ui.print("")
    for ds in mounts:
        root = expand_path(str(ds.get("mount_root") or ""))
        label = ui.c("green", "ok") if root.exists() else ui.c("red", "missing")
        ui.print(f"Mount: {ds.get('name')} -> {root}  {label}")
    ui.print("")
    ui.print(f"Project surfaces: {len(states)}")
    ui.print(f"Root aliases:     {len(root_states)}")
    ui.print(f"Healthy links:    {counts.get('ok', 0)}")
    ui.print(f"Need links:       {counts.get('needs-link', 0) + counts.get('needs', 0)}")
    ui.print(f"Missing sources:  {counts.get('source-missing', 0)}")
    ui.print(f"Missing mounts:   {counts.get('mount-missing', 0)}")
    ui.print(f"Conflicts:        {counts.get('conflict', 0)}")
    if ui.verbose or project_filter or any(k not in {"ok", "skipped"} for k in counts):
        ui.print("")
        for state in all_states:
            if not ui.verbose and state["state"] in {"ok", "skipped"} and not project_filter:
                continue
            color = "green" if state["state"] == "ok" else "yellow"
            if state["state"] in {"conflict", "mount-missing", "source-missing"}:
                color = "red"
            label = f"{state['project']}:{state['path']}"
            ui.print(f"  {ui.c(color, label):<44} {state['mode']:<10} {state['state']} -> {state['target']}")
    bad = sum(counts.get(k, 0) for k in ("source-missing", "mount-missing", "conflict"))
    return 1 if bad else 0


async def classify_workspace(config: dict[str, Any]) -> list[dict[str, Any]]:
    target = target_dir(config)
    if not target.exists():
        return []
    sources = config.get("sources") or []
    rows: list[dict[str, Any]] = []
    root_alias_targets = {str(path): name for name, path, _source in root_alias_specs(config)}
    for child in sorted(target.iterdir(), key=lambda p: p.name.lower()):
        name = child.name
        row: dict[str, Any] = {"name": name, "path": str(child), "category": "unmanaged"}
        if skipped(config, name):
            row["category"] = "skipped"
        elif child.is_symlink():
            target_path = os.readlink(child)
            row["target"] = target_path
            if target_path in root_alias_targets or target_path.startswith("/Volumes/data/") or target_path.startswith("/data/"):
                row["category"] = "data"
            else:
                row["category"] = "loose"
        elif is_git_repo(child):
            origin = await git(child, "remote", "get-url", "origin")
            origin_s = origin.stdout.strip() if origin.returncode == 0 else ""
            row["origin"] = origin_s
            adopted = (config.get("adopted_repos") or {}).get(name) or {}
            if adopted:
                row["category"] = "adopted"
                row["adoption_kind"] = adopted.get("kind")
            elif origin_s and any(repo_matches_source(origin_s, s) for s in sources):
                row["category"] = "managed"
            elif origin_s:
                row["category"] = "third-party"
            else:
                row["category"] = "local-only"
        elif child.is_dir():
            row["category"] = "data"
        else:
            row["category"] = "loose"
        rows.append(row)
    return rows


async def cmd_audit(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    category = ""
    i = 0
    while i < len(args):
        if args[i] == "--category" and i + 1 < len(args):
            category = args[i + 1]
            i += 2
        else:
            i += 1
    rows = await classify_workspace(config)
    if category == "unmanaged":
        rows = [r for r in rows if r["category"] not in {"managed", "adopted", "skipped", "data"}]
    elif category:
        rows = [r for r in rows if r["category"] == category]
    if ui.json_mode:
        for row in rows:
            print(json.dumps(row, sort_keys=True))
        return 0
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["category"]] = counts.get(row["category"], 0) + 1
    ui.print("Workspace audit")
    ui.print("")
    for cat in ["managed", "adopted", "third-party", "local-only", "data", "loose", "skipped"]:
        ui.print(f"{cat.replace('-', ' ').title():<18} {counts.get(cat, 0)}")
    anomalies = [r for r in rows if r["category"] in {"third-party", "local-only", "loose", "unmanaged"}]
    if anomalies:
        ui.print("")
        ui.print(ui.c("bold", "Needs classification"))
        for row in anomalies:
            ui.print(f"  {row['name']:<34} {row['category']}")
    if ui.verbose or category:
        ui.print("")
        for row in rows:
            extra = row.get("target") or row.get("origin") or ""
            ui.print(f"  {row['name']:<40} {row['category']:<12} {extra}")
    return 0


async def cmd_doctor(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    specs = await discover_all_code(config)
    repos = local_repos(config)
    statuses = await gather_limited(repos, jobs or STATUS_JOBS, repo_status)
    rows = await classify_workspace(config)
    missing = [spec for spec in specs if not (target_dir(config) / spec.name).exists()]
    data_items = collect_data_surfaces(config)

    async def state_one(item: tuple[Path, dict[str, Any]]) -> dict[str, Any]:
        repo, surface = item
        return await asyncio.to_thread(data_surface_state, config, repo, surface)

    data_states = await gather_limited(data_items, jobs or STATUS_JOBS, state_one)
    bad_data = [s for s in data_states if s["state"] in {"mount-missing", "source-missing", "conflict"}]
    dirty = [s for s in statuses if s.dirty]
    behind = [s for s in statuses if s.behind]
    ahead = [s for s in statuses if s.ahead]
    unmanaged = [r for r in rows if r["category"] in {"third-party", "local-only", "loose", "unmanaged"}]
    ok = not missing and not bad_data and not dirty and not unmanaged and not any(s.failed for s in statuses)
    ui.print(f"Workspace health: {ui.c('green' if ok else 'yellow', 'OK' if ok else 'Needs attention')}")
    ui.print("")
    ui.print("Git")
    ui.print(f"  managed repos:  {len(repos)}")
    ui.print(f"  missing clones: {len(missing)}")
    ui.print(f"  dirty:          {len(dirty)}")
    ui.print(f"  ahead:          {len(ahead)}")
    ui.print(f"  behind:         {len(behind)}")
    ui.print("")
    ui.print("Data")
    for ds in config.get("data_sources") or []:
        if ds.get("type") == "mount-link":
            root = expand_path(str(ds.get("mount_root") or ""))
            ui.print(f"  {ds.get('name')}: {root} {'ok' if root.exists() else 'missing'}")
    ui.print(f"  project surfaces: {len(data_states)}")
    ui.print(f"  issues:           {len(bad_data)}")
    ui.print("")
    ui.print("Workspace")
    ui.print(f"  unmanaged entries: {len(unmanaged)}")
    return 1 if not ok else 0


async def cmd_list(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    repos = local_repos(config)
    statuses = {s.name: s for s in await gather_limited(repos, jobs or STATUS_JOBS, repo_status)}
    print(f"{'NAME':<36} {'DIRTY':>5} {'AHEAD':>5} {'BEHIND':>6} {'BRANCH':<20} REMOTE")
    for repo in repos:
        s = statuses[repo.name]
        origin = await git(repo, "remote", "get-url", "origin")
        print(
            f"{repo.name:<36} {s.dirty:>5} {s.ahead:>5} {s.behind:>6} "
            f"{(s.branch or '-'): <20} {origin.stdout.strip() if origin.returncode == 0 else '-'}"
        )
    return 0


def source_by_name(config: dict[str, Any], name: str) -> dict[str, Any] | None:
    for source in config.get("sources") or []:
        if source.get("name") == name:
            return source
    return None


def cfg_default(config: dict[str, Any], key: str, fallback: str = "") -> str:
    defaults = config.get("defaults") or {}
    return str(defaults.get(key) or fallback)


def github_repo_name(url: str) -> str:
    canon = canonical_repo_url(url)
    if canon.startswith("github.com/"):
        rest = canon.removeprefix("github.com/")
        parts = rest.split("/")
        if len(parts) >= 2:
            return parts[1]
    name = url.rstrip("/").split("/")[-1]
    return name[:-4] if name.endswith(".git") else name


def github_repo_owner(url: str) -> str:
    canon = canonical_repo_url(url)
    if canon.startswith("github.com/"):
        rest = canon.removeprefix("github.com/")
        parts = rest.split("/")
        if len(parts) >= 2:
            return parts[0]
    return ""


def is_github_repo_url(url: str) -> bool:
    return canonical_repo_url(url).startswith("github.com/")


def match_source_by_url(config: dict[str, Any], url: str) -> dict[str, Any] | None:
    for source in config.get("sources") or []:
        if repo_matches_source(url, source):
            return source
    return None


def write_config(path: Path, config: dict[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(config, indent=2) + "\n")
    tmp.replace(path)


def config_backup(path: Path) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(path.name + f".bak-{stamp}")
    shutil.copyfile(path, backup)
    return backup


def human_size(num: int) -> str:
    value = float(num)
    for unit in ["B", "K", "M", "G", "T"]:
        if value < 1024 or unit == "T":
            if unit == "B":
                return f"{int(value)}B"
            return f"{value:.1f}{unit}".replace(".0", "")
        value /= 1024
    return f"{num}B"


def confirm(prompt: str) -> bool:
    if not sys.stdin.isatty():
        return False
    answer = input(f"{prompt} [y/N] ").strip().lower()
    return answer in {"y", "yes"}


async def run_foreground(args: list[str], cwd: Path | None = None) -> int:
    proc = await asyncio.create_subprocess_exec(*args, cwd=str(cwd) if cwd else None)
    return await proc.wait()


async def setup_github_remote(config: dict[str, Any], name: str, repo: Path, public: bool, description: str, ui: UI) -> int:
    source = source_by_name(config, "github") or source_by_name(config, cfg_default(config, "new_remote")) or {}
    owner = str(source.get("owner") or "")
    if not owner:
        who = await run_cmd(["gh", "api", "user", "--jq", ".login"])
        owner = who.stdout.strip() if who.returncode == 0 else ""
    if not owner:
        ui.err("could not resolve GitHub owner")
        return 1
    gh_args = [str(x) for x in ((source.get("create") or {}).get("gh_args") or [])]
    if public:
        gh_args = [x for x in gh_args if x != "--private"] + ["--public"]
    if description:
        gh_args += ["--description", description]
    ui.info(f"gh repo create {owner}/{name}")
    return await run_foreground(["gh", "repo", "create", f"{owner}/{name}", *gh_args, "--source=.", "--push"], cwd=repo)


async def setup_homelab_remote(config: dict[str, Any], name: str, repo: Path, branch: str, ui: UI) -> int:
    source = source_by_name(config, "homelab")
    if not source:
        ui.err("no 'homelab' source in config")
        return 1
    host = str(source.get("host") or "")
    root = str(source.get("path") or "")
    if not host or not root:
        ui.err("homelab source needs host and path")
        return 1
    init = await run_cmd(["ssh", host, f"mkdir -p {root} && cd {root} && git init --bare {name}.git"])
    if init.returncode != 0:
        ui.err(init.stderr.strip() or init.stdout.strip() or "homelab bare init failed")
        return init.returncode
    url = f"{host}:{root.rstrip('/')}/{name}.git"
    await git(repo, "remote", "add", "origin", url)
    await git(repo, "remote", "set-url", "origin", url)
    return (await run_foreground(["git", "push", "-u", "origin", branch], cwd=repo))


async def cmd_cd(args: list[str], config: dict[str, Any], ui: UI) -> int:
    pattern = args[0] if args else ""
    target = target_dir(config)
    if not target.exists():
        ui.err(f"workspace target missing: {target}")
        return 1
    candidates = sorted([p.name for p in target.iterdir() if p.is_dir() or p.is_symlink()], key=str.lower)
    pick = ""
    if not pattern:
        if shutil.which("fzf"):
            result = await run_cmd(["fzf", "--height=40%", "--reverse"], input_text="\n".join(candidates) + "\n")
            pick = result.stdout.strip()
        else:
            ui.err("no pattern given and fzf not installed")
            return 1
    elif pattern in candidates:
        pick = pattern
    else:
        hits = [c for c in candidates if pattern in c]
        if len(hits) == 1:
            pick = hits[0]
        elif len(hits) > 1 and shutil.which("fzf"):
            result = await run_cmd(["fzf", "--height=40%", "--reverse", f"--query={pattern}"], input_text="\n".join(hits) + "\n")
            pick = result.stdout.strip()
        elif hits:
            pick = hits[0]
    if not pick:
        ui.err(f"no match for '{pattern}'")
        return 1
    print(str(target / pick))
    return 0


async def cmd_clone(args: list[str], config: dict[str, Any], ui: UI) -> int:
    adopt_kind = "third-party"
    no_adopt = False
    url = ""
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--kind" and i + 1 < len(args):
            adopt_kind = args[i + 1]
            i += 2
        elif arg.startswith("--kind="):
            adopt_kind = arg.split("=", 1)[1]
            i += 1
        elif arg == "--no-adopt":
            no_adopt = True
            i += 1
        elif arg in {"-h", "--help"}:
            print("Usage: ws clone [--kind third-party|fork-backed|owned] [--no-adopt] <url>")
            return 0
        elif arg.startswith("-"):
            ui.err(f"ws clone: unknown flag '{arg}'")
            return 2
        elif not url:
            url = arg
            i += 1
        else:
            ui.err(f"ws clone: extra arg '{arg}'")
            return 2
    if not url:
        ui.err("Usage: ws clone [--kind third-party|fork-backed|owned] [--no-adopt] <url>")
        return 2
    if adopt_kind not in {"third-party", "fork-backed", "owned"}:
        ui.err(f"ws clone: invalid --kind '{adopt_kind}'")
        return 2
    source = match_source_by_url(config, url)
    external_github = False
    if not source:
        if not is_github_repo_url(url):
            ui.err(f"no configured source matches URL: {url}")
            return 1
        external_github = True
        source = {"name": "external-github", "type": "github-external", "clone_args": ["--filter=blob:none"], "fetch_args": ["--prune", "--tags"]}
    name = github_repo_name(url)
    target = target_dir(config)
    target.mkdir(parents=True, exist_ok=True)
    repo = target / name
    if path_exists_or_link(repo):
        ui.err(f"{repo} already exists")
        return 1
    spec = RepoSpec(name=name, url=url, source=source)
    rc = await run_foreground(["git", "clone", *clone_args(config, spec), url, str(repo)])
    if rc != 0:
        return rc
    if external_github and not no_adopt:
        config.setdefault("adopted_repos", {})[name] = {"kind": adopt_kind, "origin": url, "adopted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        write_config(Path(os.environ.get("WS_CONFIG", DEFAULT_CONFIG)), config)
        ui.ok(f"marked {name} as adopted {adopt_kind}")
    await materialize_project_links(config, repo)
    return 0


async def cmd_new(args: list[str], config: dict[str, Any], ui: UI) -> int:
    name = ""
    remote = ""
    public = False
    template = ""
    description = ""
    branch = "main"
    with_data = False
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--remote" and i + 1 < len(args):
            remote = args[i + 1]
            i += 2
        elif arg == "--public":
            public = True
            i += 1
        elif arg == "--template" and i + 1 < len(args):
            template = args[i + 1]
            i += 2
        elif arg == "--description" and i + 1 < len(args):
            description = args[i + 1]
            i += 2
        elif arg == "--branch" and i + 1 < len(args):
            branch = args[i + 1]
            i += 2
        elif arg == "--with-data":
            with_data = True
            i += 1
        elif arg in {"-h", "--help"}:
            print("Usage: ws new <name> [--remote <r>] [--public] [--template <t>] [--description <s>] [--branch <b>] [--with-data]")
            return 0
        elif arg.startswith("-"):
            ui.err(f"ws new: unknown flag '{arg}'")
            return 2
        elif not name:
            name = arg
            i += 1
        else:
            ui.err(f"ws new: extra argument '{arg}'")
            return 2
    if not name or "/" in name or name.startswith("."):
        ui.err("Usage: ws new <name> (name cannot contain '/' or start with '.')")
        return 2
    remote = remote or cfg_default(config, "new_remote", "github")
    template = template or cfg_default(config, "new_template", "empty")
    if remote not in {"github", "homelab", "none"}:
        ui.err("--remote must be github | homelab | none")
        return 2
    target = target_dir(config)
    repo = target / name
    if path_exists_or_link(repo):
        ui.err(f"{repo} already exists")
        return 1
    repo.mkdir(parents=True)
    await git(repo, "init", "-b", branch, "-q")
    tpl_dir = WS_HOME / "templates" / template
    if template and template != "none":
        if not tpl_dir.exists():
            ui.err(f"template not found: {tpl_dir}")
            return 1
        shutil.copytree(tpl_dir, repo, dirs_exist_ok=True)
        for path in sorted(repo.rglob("*{{name}}*"), key=lambda p: len(p.parts), reverse=True):
            path.rename(path.with_name(path.name.replace("{{name}}", name)))
        for path in repo.rglob("*"):
            if path.is_file() and ".git" not in path.parts:
                try:
                    text = path.read_text()
                except UnicodeDecodeError:
                    continue
                path.write_text(text.replace("{{name}}", name).replace("{{description}}", description or "A new project"))
    if with_data:
        (repo / ".ws.json").write_text(json.dumps({"_comment": "Per-repo ws config. See ~/.config/ws/docs/per-repo-config.md.", "clone_args": [], "post_clone": [], "data": []}, indent=2) + "\n")
    if any(p.name != ".git" for p in repo.iterdir()):
        await git(repo, "add", "-A")
        await run_cmd(["git", "-C", str(repo), "-c", "user.useConfigOnly=false", "commit", "-q", "-m", "init"])
    if remote == "github":
        rc = await setup_github_remote(config, name, repo, public, description, ui)
    elif remote == "homelab":
        rc = await setup_homelab_remote(config, name, repo, branch, ui)
    else:
        rc = 0
    print(str(repo))
    return rc


async def cmd_push(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    dry = "--dry-run" in args
    only = ""
    i = 0
    while i < len(args):
        if args[i] == "--only" and i + 1 < len(args):
            only = args[i + 1]
            i += 2
        else:
            i += 1
    repos = local_repos(config, only=only)
    statuses = await gather_limited(repos, jobs or STATUS_JOBS, repo_status)
    candidates = [s for s in statuses if s.ahead > 0 and not s.failed]
    if not candidates:
        ui.print("No repos with unpushed commits.")
        return 0
    ui.print("Repos with unpushed commits:")
    for s in candidates:
        ui.print(f"  - {s.name} ({s.ahead} ahead)")
    if dry:
        ui.print("Dry-run: not pushing.")
        return 0
    if not confirm("Push all?"):
        ui.print("aborted")
        return 0
    async def one(status: RepoStatus):
        result = await git(status.path, "push")
        return status.name, result
    results = await gather_limited(candidates, jobs or PUSH_JOBS, one)
    rc = 0
    for name, result in results:
        if result.returncode != 0:
            rc = result.returncode
            ui.err(f"{name} push failed: {(result.stderr or result.stdout).strip()}")
    return rc


async def cmd_prune(args: list[str], config: dict[str, Any], ui: UI) -> int:
    source_filter = ""
    only = ""
    commit = False
    archive = False
    prune_all = False
    i = 0
    while i < len(args):
        if args[i] == "--source" and i + 1 < len(args):
            source_filter = args[i + 1]
            i += 2
        elif args[i] == "--only" and i + 1 < len(args):
            only = args[i + 1]
            i += 2
        elif args[i] == "--commit":
            commit = True
            i += 1
        elif args[i] == "--archive":
            archive = True
            i += 1
        elif args[i] == "--all":
            prune_all = True
            i += 1
        else:
            i += 1
    if not source_filter and not prune_all:
        ui.err("ws prune requires --source <name> or --all")
        return 2
    sources = config.get("sources") or []
    if source_filter:
        src = source_by_name(config, source_filter)
        if not src:
            ui.err(f"no source named '{source_filter}'")
            return 1
        sources = [src]
    rc = 0
    for source in sources:
        remote = {spec.name for spec in await discover_all_code({**config, "sources": [source]}, only=only)}
        local = []
        for repo in local_repos(config, only=only):
            origin = (await git(repo, "remote", "get-url", "origin")).stdout.strip()
            if origin and repo_matches_source(origin, source) and repo.name not in remote:
                local.append(repo)
        if not local:
            ui.print(f"no orphans for source '{source.get('name')}'")
            continue
        ui.print(f"Local repos in source '{source.get('name')}' that no longer exist on remote:")
        for repo in local:
            ui.print(f"  - {repo.name}")
        if not commit:
            ui.print("dry-run: pass --commit to remove/archive")
            continue
        if archive:
            attic = target_dir(config) / ".attic" / time.strftime("%Y-%m-%d")
            attic.mkdir(parents=True, exist_ok=True)
            for repo in local:
                shutil.move(str(repo), str(attic / repo.name))
        elif confirm("Delete these directories?"):
            for repo in local:
                shutil.rmtree(repo)
        else:
            ui.print("aborted")
    return rc


async def cmd_stale(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    days = 60
    only = ""
    i = 0
    while i < len(args):
        if args[i] == "--days" and i + 1 < len(args):
            days = int(args[i + 1])
            i += 2
        elif args[i] == "--only" and i + 1 < len(args):
            only = args[i + 1]
            i += 2
        else:
            i += 1
    cutoff = time.time() - days * 86400
    repos = local_repos(config, only=only)
    async def one(repo: Path):
        log = await git(repo, "log", "-1", "--format=%ct")
        ts = int(log.stdout.strip() or "0") if log.returncode == 0 else 0
        return repo.name, ts
    rows = await gather_limited(repos, jobs or STATUS_JOBS, one)
    print(f"{'NAME':<36} {'DAYS_IDLE':>9} LAST_ACTIVITY")
    for name, ts in sorted(rows, key=lambda x: x[1]):
        if ts and ts <= cutoff:
            idle = int((time.time() - ts) // 86400)
            print(f"{name:<36} {idle:>9} {time.strftime('%Y-%m-%d', time.localtime(ts))}")
    return 0


async def cmd_size(args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    repos = local_repos(config)
    async def one(repo: Path):
        result = await run_cmd(["du", "-sk", str(repo)])
        kb = int(result.stdout.split()[0]) if result.returncode == 0 and result.stdout.split() else 0
        return repo.name, kb * 1024
    rows = await gather_limited(repos, jobs or STATUS_JOBS, one)
    print(f"{'SIZE':>8} NAME")
    for name, bytes_ in sorted(rows, key=lambda row: row[1], reverse=True):
        print(f"{human_size(bytes_):>8} {name}")
    return 0


async def cmd_init_remote(args: list[str], config: dict[str, Any], ui: UI) -> int:
    if not args:
        ui.err("Usage: ws init-remote <name>")
        return 2
    name = args[0]
    source = source_by_name(config, "homelab")
    if not source:
        ui.err("no 'homelab' source in config")
        return 1
    host = str(source.get("host") or "")
    root = str(source.get("path") or "")
    result = await run_cmd(["ssh", host, f"mkdir -p {root} && cd {root} && git init --bare {name}.git"])
    if result.returncode == 0:
        ui.ok(f"created {host}:{root}/{name}.git")
    else:
        ui.err(result.stderr.strip() or result.stdout.strip())
    return result.returncode


async def cmd_reclone(args: list[str], config: dict[str, Any], ui: UI) -> int:
    if not args:
        ui.err("Usage: ws reclone <name>")
        return 2
    name = args[0]
    repo = target_dir(config) / name
    if not is_git_repo(repo):
        ui.err(f"{name} is not a git repo at {repo}")
        return 1
    origin = (await git(repo, "remote", "get-url", "origin")).stdout.strip()
    source = match_source_by_url(config, origin)
    if not origin or not source:
        ui.err("origin missing or does not match a configured source")
        return 1
    backup = repo.with_name(f"{repo.name}.bak-{int(time.time())}")
    shutil.move(str(repo), str(backup))
    spec = RepoSpec(name=name, url=origin, source=source)
    rc = await run_foreground(["git", "clone", *clone_args(config, spec), origin, str(repo)])
    if rc != 0:
        if repo.exists():
            shutil.rmtree(repo)
        shutil.move(str(backup), str(repo))
        return rc
    await materialize_project_links(config, repo)
    print(f"Backup at: {backup}")
    if confirm("Delete backup?"):
        shutil.rmtree(backup)
    return 0


async def cmd_explain(args: list[str], config: dict[str, Any], ui: UI) -> int:
    if not args:
        ui.err("Usage: ws explain <name>")
        return 2
    name = args[0]
    repo = target_dir(config) / name
    print(f"project: {name}")
    print(f"  path:  {repo}")
    origin = ""
    if is_git_repo(repo):
        origin = (await git(repo, "remote", "get-url", "origin")).stdout.strip()
        print(f"  origin: {origin or '(none)'}")
        source = match_source_by_url(config, origin) if origin else None
        print(f"  matched source: {source.get('name') if source else '(none)'}")
    else:
        print("  origin: (not a git repo)")
    repo_cfg = read_repo_config(repo)
    legacy = project_legacy(config, name)
    merged = {**legacy, **repo_cfg}
    print("  project config:")
    print("\n".join("    " + line for line in json.dumps(merged or {}, indent=2).splitlines()))
    if origin:
        source = match_source_by_url(config, origin)
        if source:
            print("  effective clone_args:")
            for arg in clone_args(config, RepoSpec(name=name, url=origin, source=source)):
                print(f"    {arg}")
    return 0


async def cmd_config(args: list[str], config: dict[str, Any], ui: UI) -> int:
    migrate = "--migrate" in args
    print_mode = "--print" in args
    names = [a for a in args if not a.startswith("--")]
    config_path = Path(os.environ.get("WS_CONFIG", DEFAULT_CONFIG))
    if migrate:
        backup = config_backup(config_path)
        target = target_dir(config)
        projects = dict(config.get("projects") or {})
        migrated = 0
        deferred = 0
        for name, legacy in list(projects.items()):
            repo = target / name
            if legacy.get("skip"):
                config.setdefault("skip_list", [])
                if name not in config["skip_list"]:
                    config["skip_list"].append(name)
                del config["projects"][name]
                migrated += 1
                continue
            portable = {k: legacy[k] for k in ("clone_args", "post_clone", "data") if k in legacy}
            if not portable:
                del config["projects"][name]
                migrated += 1
                continue
            if not repo.exists():
                deferred += 1
                continue
            existing = read_repo_config(repo)
            existing.update(portable)
            (repo / ".ws.json").write_text(json.dumps(existing, indent=2) + "\n")
            del config["projects"][name]
            migrated += 1
        write_config(config_path, config)
        print(f"migrated {migrated}, deferred {deferred}")
        print(f"backup: {backup}")
        return 0
    if not names:
        ui.err("Usage: ws config <name> [--print] | ws config --migrate")
        return 2
    name = names[0]
    repo = target_dir(config) / name
    if not repo.exists():
        ui.err(f"{name}: not under {target_dir(config)}")
        return 1
    if print_mode:
        merged = {**project_legacy(config, name), **read_repo_config(repo)}
        print(json.dumps(merged, indent=2))
        return 0
    path = repo / ".ws.json"
    if not path.exists():
        path.write_text(json.dumps({"_comment": "Per-repo ws config. See ~/.config/ws/docs/per-repo-config.md.", "clone_args": [], "post_clone": [], "data": []}, indent=2) + "\n")
    editor = os.environ.get("EDITOR", "vi")
    rc = await run_foreground([editor, str(path)])
    try:
        json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        ui.err(f"{path} is not valid JSON: {exc}")
        return 1
    return rc


async def cmd_adopt(args: list[str], config: dict[str, Any], ui: UI) -> int:
    dry = "--dry-run" in args
    revert = "--revert" in args
    only_category = ""
    single = ""
    i = 0
    while i < len(args):
        if args[i] == "--only-category" and i + 1 < len(args):
            only_category = args[i + 1]
            i += 2
        elif args[i].startswith("--"):
            i += 1
        elif not single:
            single = args[i]
            i += 1
        else:
            i += 1
    config_path = Path(os.environ.get("WS_CONFIG", DEFAULT_CONFIG))
    if revert:
        backups = sorted(config_path.parent.glob(config_path.name + ".bak-*"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not backups:
            ui.err("no config backup to revert from")
            return 1
        shutil.copyfile(backups[0], config_path)
        ui.ok(f"reverted {config_path} from {backups[0]}")
        return 0
    rows = await classify_workspace(config)
    rows = [r for r in rows if r["category"] in {"third-party", "local-only", "data", "loose"}]
    if only_category:
        rows = [r for r in rows if r["category"] == only_category]
    if single:
        rows = [r for r in rows if r["name"] == single]
    if not rows:
        ui.print("nothing to adopt")
        return 0
    backup = None if dry else config_backup(config_path)
    for row in rows:
        name = row["name"]
        cat = row["category"]
        if dry:
            print(f"would review {name} ({cat})")
            continue
        if cat == "third-party":
            config.setdefault("adopted_repos", {})[name] = {"kind": "third-party", "origin": row.get("origin", ""), "adopted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
            print(f"marked {name} adopted third-party")
        elif cat == "loose":
            print(f"left loose file {name}")
        else:
            print(f"left {name} ({cat})")
    if not dry:
        write_config(config_path, config)
        print(f"backup: {backup}")
    return 0


async def mount_table_contains(path: Path) -> bool:
    result = await run_cmd(["mount"])
    return result.returncode == 0 and any(f" on {path} " in line for line in result.stdout.splitlines())


async def probe_mount(path: Path, timeout: float = 3.0) -> tuple[bool, str]:
    if not path_exists_or_link(path):
        return False, "missing"
    # Use subprocess timeouts instead of direct pathlib iteration; a stale
    # FUSE/SSHFS mount can hang Python filesystem calls for a long time.
    stat_result = await run_cmd(["/bin/ls", "-ld", str(path)], timeout=timeout)
    if stat_result.returncode == 124:
        return False, "stale-timeout"
    if stat_result.returncode != 0:
        return False, (stat_result.stderr or stat_result.stdout).strip() or "unreadable"
    list_result = await run_cmd(["/usr/bin/find", str(path), "-maxdepth", "1", "-mindepth", "1", "-print", "-quit"], timeout=timeout)
    if list_result.returncode == 124:
        return False, "stale-timeout"
    if list_result.returncode != 0:
        return False, (list_result.stderr or list_result.stdout).strip() or "unreadable"
    return True, "ok"


def mount_remote_for_source(ds: dict[str, Any]) -> str:
    if ds.get("remote"):
        return str(ds["remote"])
    host = str(ds.get("host") or os.environ.get("WS_DATA_HOST") or "nitai-node")
    remote_path = str(ds.get("remote_path") or os.environ.get("WS_DATA_REMOTE") or "/data")
    return f"{host}:{remote_path}"


async def ensure_mountpoint(path: Path, ui: UI) -> bool:
    if path.exists():
        return True
    try:
        path.mkdir(parents=True, exist_ok=True)
        return True
    except PermissionError:
        user = os.environ.get("USER", "$(whoami)")
        sudo = await run_cmd(["sudo", "-n", "mkdir", "-p", str(path)])
        if sudo.returncode == 0:
            chown = await run_cmd(["sudo", "-n", "chown", f"{user}:staff", str(path)])
            if chown.returncode == 0:
                return True
        ui.err(f"cannot create {path}; run: sudo mkdir -p {path} && sudo chown {user}:staff {path}")
        return False


async def unmount_path(path: Path, ui: UI) -> bool:
    if not await mount_table_contains(path):
        # Clean up stale helper processes if present anyway.
        await run_cmd(["pkill", "-f", f"sshfs -s .*:{re.escape(str(path))}"])
        return True
    result = await run_cmd(["diskutil", "unmount", "force", str(path)], timeout=10)
    if result.returncode != 0:
        result = await run_cmd(["umount", "-f", str(path)], timeout=10)
    await run_cmd(["pkill", "-f", f"sshfs -s .* {re.escape(str(path))}"])
    await run_cmd(["pkill", "-f", f"go-nfsv4 --volname .* {re.escape(str(path))}"])
    if result.returncode != 0:
        ui.err((result.stderr or result.stdout).strip() or f"failed to unmount {path}")
        return False
    return True


async def mount_source(ds: dict[str, Any], ui: UI) -> bool:
    path = expand_path(str(ds.get("mount_root") or ""))
    if not path:
        ui.err(f"{ds.get('name')}: missing mount_root")
        return False
    ok, reason = await probe_mount(path)
    mounted = await mount_table_contains(path)
    if ok and mounted:
        ui.print(f"{ds.get('name')}: mounted ok at {path}")
        return True
    if ok and not str(path).startswith("/Volumes/"):
        ui.print(f"{ds.get('name')}: direct path ok at {path}")
        return True
    if mounted:
        ui.warn(f"{ds.get('name')}: stale mount at {path} ({reason}); unmounting")
        if not await unmount_path(path, ui):
            return False
    if not await ensure_mountpoint(path, ui):
        return False
    remote = mount_remote_for_source(ds)
    ssh_host = remote.split(":", 1)[0]
    ssh_check = await run_cmd(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", ssh_host, "echo", "ssh-ok"], timeout=8)
    if ssh_check.returncode != 0:
        detail = (ssh_check.stderr or ssh_check.stdout).strip()
        match = re.search(r"https://login\\.tailscale\\.com/\\S+", detail)
        if match and sys.platform == "darwin":
            await run_cmd(["open", match.group(0)])
            ui.err(f"SSH/Tailscale auth is not ready for {ssh_host}; opened auth URL: {match.group(0)}")
        else:
            ui.err(f"SSH/Tailscale auth is not ready for {ssh_host}: {detail}")
        return False
    sshfs = shutil.which("sshfs")
    if not sshfs:
        ui.err("sshfs not found")
        return False
    result = await run_cmd([sshfs, "-s", remote, str(path), "-o", "reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,volname=data,no_readahead,sync_readdir,direct_io"], timeout=15)
    if result.returncode != 0:
        ui.err((result.stderr or result.stdout).strip() or f"failed to mount {remote} at {path}")
        return False
    ok, reason = await probe_mount(path)
    if not ok:
        ui.err(f"mounted {path}, but health probe failed: {reason}")
        return False
    ui.print(f"{ds.get('name')}: mounted {remote} -> {path}")
    return True


async def cmd_data_mount(sub: str, args: list[str], config: dict[str, Any], ui: UI) -> int:
    sources = [ds for ds in config.get("data_sources") or [] if ds.get("type") == "mount-link"]
    if args:
        wanted = set(a for a in args if not a.startswith("--"))
        sources = [ds for ds in sources if str(ds.get("name")) in wanted]
    if not sources:
        ui.print("No mount-link data sources matched.")
        return 0
    rc = 0
    for ds in sources:
        path = expand_path(str(ds.get("mount_root") or ""))
        if sub in {"unmount", "remount"}:
            if await unmount_path(path, ui):
                ui.print(f"{ds.get('name')}: unmounted {path}")
            else:
                rc = 1
                continue
        if sub in {"mount", "remount"}:
            if not await mount_source(ds, ui):
                rc = 1
    return rc


async def cmd_data_rsync(sub: str, args: list[str], config: dict[str, Any], ui: UI, jobs: int) -> int:
    dry = "--dry-run" in args
    delete = "--delete" in args
    itemize = "--itemize" in args
    positional = [a for a in args if not a.startswith("--")]
    project_filter = positional[0] if positional else ""
    surfaces = [(repo, s) for repo, s in collect_data_surfaces(config, project_filter) if s.get("mode") == "rsync"]
    if not surfaces:
        ui.print("No rsync data surfaces matched.")
        return 0
    async def one(item: tuple[Path, dict[str, Any]]):
        repo, surface = item
        ds = data_source(config, str(surface.get("source") or "")) or {}
        host = str(ds.get("host") or "")
        remote_path = str(ds.get("remote_path") or "")
        remote = str(surface.get("remote") or repo.name)
        local = expand_path(str(surface.get("local") or f"~/workspace-data/{repo.name}"))
        rsync_args = [str(x) for x in (ds.get("rsync_args") or ["-a", "--partial"])]
        for ex in ds.get("exclude") or []:
            rsync_args.append(f"--exclude={ex}")
        if itemize:
            rsync_args.append("--itemize-changes")
        if delete:
            rsync_args.append("--delete")
        if dry:
            rsync_args.append("--dry-run")
        if sub == "pull":
            local.mkdir(parents=True, exist_ok=True)
            cmd = ["rsync", *rsync_args, f"{host}:{remote_path.rstrip('/')}/{remote}/", str(local) + "/"]
        else:
            if surface.get("direction", "pull-only") != "push-explicit":
                return repo.name, RunResult([], 1, "", "push not allowed")
            dry_args = [a for a in rsync_args if a != "--dry-run"] + ["--dry-run"]
            preview = await run_cmd(["rsync", *dry_args, str(local) + "/", f"{host}:{remote_path.rstrip('/')}/{remote}/"])
            if preview.returncode != 0 or dry or not confirm(f"Push {repo.name}:{surface.get('path')}?"):
                return repo.name, preview
            cmd = ["rsync", *rsync_args, str(local) + "/", f"{host}:{remote_path.rstrip('/')}/{remote}/"]
        result = await run_cmd(cmd)
        return repo.name, result
    results = await gather_limited(surfaces, jobs or NETWORK_JOBS, one)
    rc = 0
    for name, result in results:
        if result.returncode != 0:
            rc = result.returncode
            ui.err(f"{name}: {(result.stderr or result.stdout).strip()}")
    return rc


async def cmd_init(args: list[str], config_path: Path, ui: UI) -> int:
    BIN_LINK.parent.mkdir(parents=True, exist_ok=True)
    if not config_path.exists() and CONFIG_EXAMPLE.exists():
        shutil.copyfile(CONFIG_EXAMPLE, config_path)
        ui.ok(f"created {config_path}")
    target = Path.home() / "workspace"
    try:
        config = load_config(config_path)
        target = target_dir(config)
    except WsError:
        pass
    target.mkdir(parents=True, exist_ok=True)
    if path_exists_or_link(BIN_LINK):
        if BIN_LINK.is_symlink() or BIN_LINK.exists():
            try:
                BIN_LINK.unlink()
            except IsADirectoryError:
                ui.err(f"{BIN_LINK} is a directory")
                return 1
    os.symlink(str(WS_HOME / "ws"), str(BIN_LINK))
    ui.ok(f"linked {BIN_LINK} -> {WS_HOME / 'ws'}")
    return 0


async def cmd_upgrade(args: list[str], ui: UI) -> int:
    result = await run_cmd(["git", "-C", str(WS_HOME), "pull", "--ff-only"])
    if result.stdout.strip():
        print(result.stdout.rstrip())
    if result.stderr.strip():
        print(result.stderr.rstrip(), file=sys.stderr)
    return result.returncode


async def cmd_version() -> int:
    result = await run_cmd(["git", "-C", str(WS_HOME), "rev-parse", "--short", "HEAD"])
    sha = result.stdout.strip() if result.returncode == 0 else "unknown"
    date = await run_cmd(["git", "-C", str(WS_HOME), "show", "-s", "--format=%cs", "HEAD"])
    print(f"ws {WS_VERSION} ({sha} {date.stdout.strip() if date.returncode == 0 else 'unknown'})")
    return 0


HELP = """ws — async workspace sync over GitHub, Tailscale git, and server-backed data dirs

USAGE
  ws [--jobs N] [--verbose] [--json] [--no-color] <command> [options]

DAILY
  doctor                 Health summary for repos, data, mounts, and unmanaged entries
  sync [--dry-run]       Clone missing repos, fetch existing repos, repair data aliases
  status                 Fast async anomaly-first repo status
  pull --safe            Fast-forward clean behind repos only
  data status [project]  Summarize mounted/symlinked data surfaces
  data mount|remount     Repair SSHFS/FUSE data mounts
  audit                  Classify ~/workspace entries

OTHER
  list                   Repo table
  git <args>             Run git command across repos
  init                   First-time setup
  upgrade                git pull --ff-only in ~/.config/ws
  --version              Show version

All commands are implemented in the Python CLI; ws.legacy has been removed.
"""


def parse_global(argv: list[str]) -> tuple[dict[str, Any], str, list[str]]:
    opts = {
        "config": Path(os.environ.get("WS_CONFIG", str(DEFAULT_CONFIG))),
        "jobs": 0,
        "verbose": False,
        "json": False,
        "no_color": False,
    }
    rest: list[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--config" and i + 1 < len(argv):
            opts["config"] = expand_path(argv[i + 1])
            i += 2
        elif arg.startswith("--config="):
            opts["config"] = expand_path(arg.split("=", 1)[1])
            i += 1
        elif arg == "--jobs" and i + 1 < len(argv):
            opts["jobs"] = int(argv[i + 1])
            i += 2
        elif arg.startswith("--jobs="):
            opts["jobs"] = int(arg.split("=", 1)[1])
            i += 1
        elif arg == "--verbose":
            opts["verbose"] = True
            i += 1
        elif arg == "--json":
            opts["json"] = True
            i += 1
        elif arg == "--no-color":
            opts["no_color"] = True
            i += 1
        elif arg in {"-h", "--help"}:
            return opts, "help", []
        elif arg == "--version":
            return opts, "version", []
        else:
            rest = argv[i:]
            break
    command = rest[0] if rest else "help"
    return opts, command, rest[1:] if rest else []


def consume_late_globals(args: list[str], opts: dict[str, Any]) -> list[str]:
    """Allow global flags after the command, stopping at passthrough `--`."""
    kept: list[str] = []
    i = 0
    passthrough = False
    while i < len(args):
        arg = args[i]
        if passthrough:
            kept.append(arg)
            i += 1
            continue
        if arg == "--":
            passthrough = True
            kept.append(arg)
            i += 1
        elif arg == "--verbose":
            opts["verbose"] = True
            i += 1
        elif arg == "--json":
            opts["json"] = True
            i += 1
        elif arg == "--no-color":
            opts["no_color"] = True
            i += 1
        elif arg == "--jobs" and i + 1 < len(args):
            opts["jobs"] = int(args[i + 1])
            i += 2
        elif arg.startswith("--jobs="):
            opts["jobs"] = int(arg.split("=", 1)[1])
            i += 1
        else:
            kept.append(arg)
            i += 1
    return kept


async def amain(argv: list[str]) -> int:
    opts, command, args = parse_global(argv)
    args = consume_late_globals(args, opts)
    os.environ["WS_CONFIG"] = str(opts["config"])
    color = sys.stdout.isatty() and not opts["no_color"] and "NO_COLOR" not in os.environ and not opts["json"]
    ui = UI(color=color, verbose=bool(opts["verbose"]), json_mode=bool(opts["json"]))
    if command == "help":
        print(HELP)
        return 0
    if command == "version":
        return await cmd_version()
    if command == "init":
        return await cmd_init(args, Path(opts["config"]), ui)
    if command == "upgrade":
        return await cmd_upgrade(args, ui)

    try:
        config = load_config(Path(opts["config"]))
    except WsError as exc:
        ui.err(str(exc))
        return 1

    jobs = int(opts["jobs"] or 0)
    try:
        if command == "status":
            return await cmd_status(args, config, ui, jobs or STATUS_JOBS)
        if command == "sync":
            return await cmd_sync(args, config, ui, jobs or NETWORK_JOBS)
        if command == "pull":
            return await cmd_pull(args, config, ui, jobs or NETWORK_JOBS)
        if command == "git":
            return await cmd_git(args, config, ui, jobs or READ_JOBS)
        if command == "data":
            return await cmd_data(args, config, ui, jobs or STATUS_JOBS)
        if command == "audit":
            return await cmd_audit(args, config, ui, jobs or STATUS_JOBS)
        if command == "doctor":
            return await cmd_doctor(args, config, ui, jobs or STATUS_JOBS)
        if command == "list":
            return await cmd_list(args, config, ui, jobs or STATUS_JOBS)
        if command == "cd":
            return await cmd_cd(args, config, ui)
        if command == "clone":
            return await cmd_clone(args, config, ui)
        if command == "new":
            return await cmd_new(args, config, ui)
        if command == "push":
            return await cmd_push(args, config, ui, jobs or PUSH_JOBS)
        if command == "prune":
            return await cmd_prune(args, config, ui)
        if command == "stale":
            return await cmd_stale(args, config, ui, jobs or STATUS_JOBS)
        if command == "size":
            return await cmd_size(args, config, ui, jobs or STATUS_JOBS)
        if command == "init-remote":
            return await cmd_init_remote(args, config, ui)
        if command == "reclone":
            return await cmd_reclone(args, config, ui)
        if command == "explain":
            return await cmd_explain(args, config, ui)
        if command == "config":
            return await cmd_config(args, config, ui)
        if command == "adopt":
            return await cmd_adopt(args, config, ui)
        ui.err(f"unknown command: {command}")
        print(HELP)
        return 2
    except WsError as exc:
        ui.err(str(exc))
        return 1
    except KeyboardInterrupt:
        ui.err("interrupted")
        return 130


if __name__ == "__main__":
    raise SystemExit(asyncio.run(amain(sys.argv[1:])))
