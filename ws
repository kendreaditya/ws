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


WS_VERSION = "0.2.0"
WS_HOME = Path.home() / ".config" / "ws"
DEFAULT_CONFIG = WS_HOME / "config.json"
CONFIG_EXAMPLE = WS_HOME / "config.example.json"
LEGACY = WS_HOME / "ws.legacy"
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
        return await fallback(args=["pull", *args])
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
        return await fallback(["clone", *passthru[1:]])
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
    if sub not in {"status", "plan", "link", "pull", "push"}:
        ui.err(f"ws data: unknown subcommand '{sub}'")
        return 2
    if sub in {"pull", "push"}:
        return await fallback(["data", *args])

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


async def fallback(args: list[str]) -> int:
    if not LEGACY.exists():
        print(f"ws: legacy fallback missing: {LEGACY}", file=sys.stderr)
        return 127
    proc = await asyncio.create_subprocess_exec(
        str(LEGACY),
        *args,
        stdin=None,
        stdout=None,
        stderr=None,
    )
    return await proc.wait()


HELP = """ws — async workspace sync over GitHub, Tailscale git, and server-backed data dirs

USAGE
  ws [--jobs N] [--verbose] [--json] [--no-color] <command> [options]

DAILY
  doctor                 Health summary for repos, data, mounts, and unmanaged entries
  sync [--dry-run]       Clone missing repos, fetch existing repos, repair data aliases
  status                 Fast async anomaly-first repo status
  pull --safe            Fast-forward clean behind repos only
  data status [project]  Summarize mounted/symlinked data surfaces
  audit                  Classify ~/workspace entries

OTHER
  list                   Repo table
  git <args>             Run git command across repos
  init                   First-time setup
  upgrade                git pull --ff-only in ~/.config/ws
  --version              Show version

Rare lifecycle commands currently delegate to ws.legacy: new, clone, push, prune,
stale, size, init-remote, reclone, explain, adopt, config.
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
        if command in {"new", "clone", "push", "prune", "stale", "size", "init-remote", "reclone", "explain", "adopt", "config", "cd"}:
            return await fallback([command, *args])
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
