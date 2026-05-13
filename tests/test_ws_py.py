#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import importlib.machinery
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WS_PATH = ROOT / "ws"


def load_ws():
    loader = importlib.machinery.SourceFileLoader("ws_cli", str(WS_PATH))
    spec = importlib.util.spec_from_loader("ws_cli", loader)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


ws = load_ws()


class WsPureTests(unittest.TestCase):
    def test_github_url_normalization(self):
        cases = [
            "git@github.com:kendreaditya/ws.git",
            "ssh://git@github.com/kendreaditya/ws.git",
            "https://github.com/kendreaditya/ws.git",
            "http://github.com/kendreaditya/ws",
        ]
        normalized = {ws.canonical_repo_url(value) for value in cases}
        self.assertEqual(normalized, {"github.com/kendreaditya/ws"})

    def test_color_disabled_by_no_color(self):
        ui = ws.UI(color=False)
        self.assertEqual(ui.c("green", "OK"), "OK")

    def test_expand_path_does_not_resolve_symlink(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / "missing-target"
            link = root / "link"
            os.symlink(str(target), str(link))
            self.assertEqual(ws.expand_path(str(link)), link)

    def test_symlink_is_not_treated_as_git_repo(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / "data"
            link = root / "workspace-link"
            target.mkdir()
            os.symlink(str(target), str(link))
            self.assertFalse(ws.is_git_repo(link))


    def test_no_legacy_fallback_constant(self):
        self.assertFalse(hasattr(ws, "LEGACY"))
        self.assertFalse((ROOT / "ws.legacy").exists())

    def test_resolve_link_target_remote(self):
        config = {
            "data_sources": [
                {"name": "data-mount", "type": "mount-link", "mount_root": "/Volumes/data"}
            ]
        }
        surface = {
            "path": "photos",
            "mode": "link",
            "source": "data-mount",
            "remote": "weekly-photo-wall/photos",
        }
        self.assertEqual(
            ws.resolve_link_target(config, "weekly-photo-wall", surface),
            Path("/Volumes/data/weekly-photo-wall/photos"),
        )


class WsIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.repo = self.workspace / "demo"
        subprocess.run(["git", "init", "-b", "main", str(self.repo)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email", "test@example.com"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name", "Test"], check=True)
        (self.repo / "README.md").write_text("hello\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "README.md"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-m", "init"], check=True, stdout=subprocess.DEVNULL)

    async def asyncTearDown(self):
        self.tmp.cleanup()

    async def test_repo_status_detects_dirty(self):
        (self.repo / "README.md").write_text("changed\n")
        status = await ws.repo_status(self.repo)
        self.assertEqual(status.name, "demo")
        self.assertEqual(status.dirty, 1)
        self.assertFalse(status.failed)

    async def test_data_surface_state_ok(self):
        data_root = self.root / "data"
        data_root.mkdir()
        source = data_root / "demo" / "photos"
        source.mkdir(parents=True)
        os.symlink(str(source), str(self.repo / "photos"))
        config = {
            "target": str(self.workspace),
            "data_sources": [
                {"name": "data-mount", "type": "mount-link", "mount_root": str(data_root)}
            ],
        }
        surface = {"path": "photos", "mode": "link", "source": "data-mount", "remote": "demo/photos"}
        state = ws.data_surface_state(config, self.repo, surface)
        self.assertEqual(state["state"], "ok")


if __name__ == "__main__":
    unittest.main()
