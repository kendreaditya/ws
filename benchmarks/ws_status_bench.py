#!/usr/bin/env python3
"""Benchmark status strategies for ws.

Compares:
  1. current `ws status` implementation
  2. asyncio subprocess fanout
  3. asyncio loop + thread-pool subprocess fanout
  4. plain thread-pool subprocess fanout

The async/threaded modes run the same core command per repo:
  git -C <repo> status -sb

Output is intentionally summarized so timings are not dominated by terminal
printing.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import statistics
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RunResult:
    name: str
    seconds: float
    repos: int | None = None
    dirty: int | None = None
    failed: int | None = None


def find_repos(workspace: Path) -> list[Path]:
    repos: list[Path] = []
    for child in sorted(workspace.iterdir(), key=lambda p: p.name.lower()):
        if not child.is_dir():
            continue
        if (child / ".git").exists():
            repos.append(child)
    return repos


def timed(fn, *args) -> tuple[float, object]:
    start = time.perf_counter()
    value = fn(*args)
    return time.perf_counter() - start, value


def run_ws_status(ws_bin: Path, workspace: Path) -> tuple[int, int, int]:
    proc = subprocess.run(
        [str(ws_bin), "status"],
        cwd=workspace,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    return (0, 0, 1 if proc.returncode else 0)


def git_status_one(repo: Path) -> tuple[str, bool, bool]:
    proc = subprocess.run(
        ["git", "-C", str(repo), "status", "-sb"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return (repo.name, False, True)
    lines = proc.stdout.splitlines()
    dirty = any(line and not line.startswith("## ") for line in lines)
    return (repo.name, dirty, False)


async def async_git_status_one(repo: Path, sem: asyncio.Semaphore) -> tuple[str, bool, bool]:
    async with sem:
        proc = await asyncio.create_subprocess_exec(
            "git",
            "-C",
            str(repo),
            "status",
            "-sb",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _stderr = await proc.communicate()
    if proc.returncode != 0:
        return (repo.name, False, True)
    lines = stdout.decode("utf-8", "replace").splitlines()
    dirty = any(line and not line.startswith("## ") for line in lines)
    return (repo.name, dirty, False)


async def run_asyncio(repos: list[Path], jobs: int) -> tuple[int, int, int]:
    sem = asyncio.Semaphore(jobs)
    results = await asyncio.gather(*(async_git_status_one(repo, sem) for repo in repos))
    dirty = sum(1 for _name, is_dirty, failed in results if is_dirty and not failed)
    failed = sum(1 for _name, _is_dirty, failed in results if failed)
    return (len(results), dirty, failed)


async def run_asyncio_threaded(repos: list[Path], jobs: int) -> tuple[int, int, int]:
    loop = asyncio.get_running_loop()
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [loop.run_in_executor(pool, git_status_one, repo) for repo in repos]
        results = await asyncio.gather(*futures)
    dirty = sum(1 for _name, is_dirty, failed in results if is_dirty and not failed)
    failed = sum(1 for _name, _is_dirty, failed in results if failed)
    return (len(results), dirty, failed)


def run_threaded(repos: list[Path], jobs: int) -> tuple[int, int, int]:
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(git_status_one, repos))
    dirty = sum(1 for _name, is_dirty, failed in results if is_dirty and not failed)
    failed = sum(1 for _name, _is_dirty, failed in results if failed)
    return (len(results), dirty, failed)


def summarize(name: str, samples: list[RunResult]) -> str:
    secs = [sample.seconds for sample in samples]
    best = min(secs)
    avg = statistics.mean(secs)
    last = samples[-1]
    details = ""
    if last.repos is not None:
        details = f" repos={last.repos} dirty={last.dirty} failed={last.failed}"
    return f"{name:18} best={best:7.3f}s avg={avg:7.3f}s{details}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark ws status implementations")
    parser.add_argument("--workspace", default=str(Path.home() / "workspace"))
    parser.add_argument("--ws-bin", default=str(Path.home() / ".config/ws/ws"))
    parser.add_argument("--jobs", type=int, default=min(32, (os.cpu_count() or 8) * 4))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--skip-baseline", action="store_true")
    args = parser.parse_args()

    workspace = Path(args.workspace).expanduser()
    ws_bin = Path(args.ws_bin).expanduser()
    repos = find_repos(workspace)

    print(f"workspace: {workspace}")
    print(f"repos:     {len(repos)}")
    print(f"jobs:      {args.jobs}")
    print(f"runs:      {args.runs}")
    print()

    buckets: dict[str, list[RunResult]] = {
        "asyncio": [],
        "asyncio+threads": [],
        "threaded": [],
    }
    if not args.skip_baseline:
        buckets = {"ws status": [], **buckets}

    for i in range(1, args.runs + 1):
        print(f"run {i}/{args.runs}")
        if not args.skip_baseline:
            seconds, (_repos, dirty, failed) = timed(run_ws_status, ws_bin, workspace)
            buckets["ws status"].append(RunResult("ws status", seconds, None, dirty, failed))
            print(f"  ws status          {seconds:7.3f}s")

        start = time.perf_counter()
        repo_count, dirty, failed = asyncio.run(run_asyncio(repos, args.jobs))
        seconds = time.perf_counter() - start
        buckets["asyncio"].append(RunResult("asyncio", seconds, repo_count, dirty, failed))
        print(f"  asyncio            {seconds:7.3f}s")

        start = time.perf_counter()
        repo_count, dirty, failed = asyncio.run(run_asyncio_threaded(repos, args.jobs))
        seconds = time.perf_counter() - start
        buckets["asyncio+threads"].append(
            RunResult("asyncio+threads", seconds, repo_count, dirty, failed)
        )
        print(f"  asyncio+threads    {seconds:7.3f}s")

        seconds, (repo_count, dirty, failed) = timed(run_threaded, repos, args.jobs)
        buckets["threaded"].append(RunResult("threaded", seconds, repo_count, dirty, failed))
        print(f"  threaded           {seconds:7.3f}s")
        print()

    print("summary")
    print("-------")
    for name, samples in buckets.items():
        print(summarize(name, samples))

    if not args.skip_baseline:
        base = min(sample.seconds for sample in buckets["ws status"])
        for name in ("asyncio", "asyncio+threads", "threaded"):
            best = min(sample.seconds for sample in buckets[name])
            print(f"{name:18} speedup={base / best:6.2f}x vs ws status")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
