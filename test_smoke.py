#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""前端冒烟测试(unittest)。

无需 prod.keys、无需 Xcode 即可跑绿:
- 用临时目录当游戏库,放一个假 NSP / 假 XCI;
- 用 NXFE_CONFIG 环境变量把 server.py 指向临时 config.json;
- 以子进程方式启动 server.py --port <PORT> --no-open,等 /api/status 就绪后逐项断言。

约定(对后端 server.py 的要求):
- 必须支持环境变量 NXFE_CONFIG 覆盖 config.json 路径;
- 必须支持 --port / --no-open 命令行参数。
若 server.py 尚不存在或不支持 NXFE_CONFIG,本文件整体跳过并打印警告(并行开发阶段可先落地)。
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

FRONTEND = Path(__file__).resolve().parent
SERVER_PY = FRONTEND / "server.py"
PORT = int(os.environ.get("NXFE_TEST_PORT", "18974"))
BASE = "http://127.0.0.1:%d" % PORT


def _server_supports_nxfe_config():
    if not SERVER_PY.is_file():
        return False
    try:
        src = SERVER_PY.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    return "NXFE_CONFIG" in src


SUPPORTED = _server_supports_nxfe_config()
if not SUPPORTED:
    if not SERVER_PY.is_file():
        print("警告: server.py 尚不存在,跳过全部冒烟测试(并行开发阶段)", file=sys.stderr)
    else:
        print("警告: server.py 不支持 NXFE_CONFIG 环境变量,跳过全部冒烟测试", file=sys.stderr)


def http_json(method, path, body=None, timeout=15):
    """发一个请求,返回 (status, parsed_json_or_None, raw_text, content_type)。"""
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            status = resp.status
            ctype = resp.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        status = e.code
        ctype = e.headers.get("Content-Type", "")
    try:
        parsed = json.loads(raw) if raw else None
    except ValueError:
        parsed = None
    return status, parsed, raw, ctype


@unittest.skipUnless(SUPPORTED, "server.py 不存在或不支持 NXFE_CONFIG,跳过冒烟测试")
class SmokeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmpdir = Path(tempfile.mkdtemp(prefix="nxfe_smoke_"))
        cls.addClassCleanup(cls._cleanup)

        # 假游戏库: 一个子文件夹游戏 + 根目录自身一个游戏
        cls.lib = cls.tmpdir / "library"
        cls.lib.mkdir()
        demo = cls.lib / "DemoGame"
        demo.mkdir()
        (demo / "Demo [0100ABCDEF123456][v0].nsp").write_bytes(b"FAKE NSP")
        (cls.lib / "Root [0100000000000001][v1].xci").write_bytes(b"FAKE XCI")

        # 临时 config.json(经 NXFE_CONFIG 注入)
        cls.config_path = cls.tmpdir / "config.json"
        config = {
            "keys": "",
            "library": str(cls.lib),
            "language": "",
            "extra_env": {},
        }
        cls.config_path.write_text(
            json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )

        env = os.environ.copy()
        env["NXFE_CONFIG"] = str(cls.config_path)
        env["PORT"] = str(PORT)

        cls.server_log_path = cls.tmpdir / "server_stdout.log"
        cls.server_log = cls.server_log_path.open("w", encoding="utf-8")
        cls.proc = subprocess.Popen(
            [sys.executable, str(SERVER_PY), "--port", str(PORT), "--no-open"],
            cwd=str(FRONTEND),
            env=env,
            stdout=cls.server_log,
            stderr=subprocess.STDOUT,
        )

        # 等待就绪(/api/status 可能含 xcrun 探测,给足时间)
        deadline = time.time() + 30
        last_err = None
        while time.time() < deadline:
            if cls.proc.poll() is not None:
                break
            try:
                status, _, _, _ = http_json("GET", "/api/status", timeout=12)
                if status == 200:
                    return
            except (urllib.error.URLError, ConnectionError, OSError) as e:
                last_err = e
            time.sleep(0.2)

        detail = ""
        try:
            detail = cls.server_log_path.read_text(encoding="utf-8", errors="replace")[-2000:]
        except OSError:
            pass
        raise RuntimeError(
            "服务器启动失败 (exit=%s, last_err=%s)\n--- server 日志尾部 ---\n%s"
            % (cls.proc.poll(), last_err, detail)
        )

    @classmethod
    def _cleanup(cls):
        proc = getattr(cls, "proc", None)
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
        log = getattr(cls, "server_log", None)
        if log is not None and not log.closed:
            log.close()
        tmpdir = getattr(cls, "tmpdir", None)
        if tmpdir is not None:
            shutil.rmtree(tmpdir, ignore_errors=True)

    # ---- 用例 ----

    def test_status(self):
        status, data, _, _ = http_json("GET", "/api/status")
        self.assertEqual(status, 200)
        self.assertIsInstance(data, dict)
        for key in ("repo", "repo_ok", "keys", "keys_ok", "library", "library_ok", "tools"):
            self.assertIn(key, data)
        self.assertIsInstance(data["repo"], str)
        self.assertIsInstance(data["repo_ok"], bool)
        self.assertIsInstance(data["keys_ok"], bool)
        self.assertTrue(data["library_ok"], "临时游戏库应被识别为存在")
        self.assertEqual(
            os.path.realpath(data["library"]), os.path.realpath(str(self.lib))
        )
        tools = data["tools"]
        self.assertIsInstance(tools, dict)
        for name in ("xcodebuild", "xcodegen", "dotnet", "zstd", "spirv-cross", "metal"):
            self.assertIn(name, tools)
            self.assertIsInstance(tools[name], bool)

    def test_config_roundtrip(self):
        status, cfg, _, _ = http_json("GET", "/api/config")
        self.assertEqual(status, 200)
        self.assertIsInstance(cfg, dict)
        for key in ("keys", "library", "language", "extra_env"):
            self.assertIn(key, cfg)
        self.assertEqual(os.path.realpath(cfg["library"]), os.path.realpath(str(self.lib)))

        cfg["language"] = "zh"
        status, new_cfg, _, _ = http_json("PUT", "/api/config", cfg)
        self.assertEqual(status, 200, "PUT /api/config 应成功")
        self.assertIsInstance(new_cfg, dict)
        self.assertEqual(new_cfg.get("language"), "zh")

        status, again, _, _ = http_json("GET", "/api/config")
        self.assertEqual(status, 200)
        self.assertEqual(again.get("language"), "zh")

        # 还原,避免影响其他用例
        again["language"] = ""
        http_json("PUT", "/api/config", again)

    def test_games_scan(self):
        status, data, _, _ = http_json("GET", "/api/games")
        self.assertEqual(status, 200)
        self.assertIsInstance(data, dict)
        self.assertIn("games", data)
        self.assertIn("names", data)
        games = data["games"]
        self.assertIsInstance(games, list)
        self.assertIsInstance(data["names"], dict)

        by_folder = {g["folder"]: g for g in games}
        self.assertIn("DemoGame", by_folder, "应扫描到 DemoGame 子文件夹")

        demo = by_folder["DemoGame"]
        for key in (
            "folder",
            "path",
            "title_ids",
            "display_name",
            "profile",
            "versions",
            "size_gb",
            "build",
            "ipa",
        ):
            self.assertIn(key, demo)
        self.assertEqual(
            os.path.realpath(demo["path"]),
            os.path.realpath(str(self.lib / "DemoGame")),
        )
        self.assertEqual(demo["title_ids"], ["0100ABCDEF123456"])
        self.assertEqual(demo["versions"], [0])
        # 假 title id 不在 dm/games 映射里 -> 回退为文件夹名
        self.assertEqual(demo["display_name"], "DemoGame")
        self.assertIsInstance(demo["size_gb"], float)
        self.assertGreaterEqual(demo["size_gb"], 0.0)
        self.assertIsNone(demo["build"], "假游戏不应有构建产物")
        self.assertIsNone(demo["ipa"])

        # library 根目录自身含 xci,也算一个游戏(folder 显示 ".")
        self.assertIn(".", by_folder, "library 根目录自身应算一个游戏")
        root = by_folder["."]
        self.assertEqual(root["title_ids"], ["0100000000000001"])
        self.assertEqual(root["versions"], [1])

    def test_build_unknown_folder_404(self):
        status, data, _, _ = http_json("POST", "/api/build", {"folder": "NoSuchGame"})
        self.assertIn(status, (400, 404), "不存在的文件夹应返回 404/400,实际 %s" % status)

    def test_static_index(self):
        if not (FRONTEND / "static" / "index.html").is_file():
            self.skipTest("static/index.html 尚未生成(并行开发阶段)")
        req = urllib.request.Request(BASE + "/")
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            self.assertEqual(resp.status, 200)
            self.assertIn("text/html", resp.headers.get("Content-Type", ""))
            self.assertIn("<html", body.lower())

    def test_path_traversal_rejected(self):
        for bad in ("../x", "..", "/etc", "DemoGame/../../etc"):
            status, _, _, _ = http_json("POST", "/api/build", {"folder": bad})
            self.assertGreaterEqual(
                status, 400, "folder=%r 应被拒绝,实际 %s" % (bad, status)
            )
            self.assertLess(status, 500, "folder=%r 不应 5xx" % (bad,))
        # 日志接口同样校验
        status, _, _, _ = http_json("GET", "/api/build/log?folder=../x")
        self.assertGreaterEqual(status, 400, "build/log 路径穿越应被拒绝")
        self.assertLess(status, 500)


if __name__ == "__main__":
    unittest.main(verbosity=2)
