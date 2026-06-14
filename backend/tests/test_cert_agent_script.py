"""憑證派送 agent 腳本(agent/jt_ipam_cert_agent.py)的純邏輯測試:
content 組裝、profile 路徑解析、dry-run 不動檔、原子寫入。
"""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path

import pytest

_AGENT = Path(__file__).resolve().parents[2] / "agent" / "jt_ipam_cert_agent.py"

if not _AGENT.exists():
    pytest.skip("cert agent script not present", allow_module_level=True)

_spec = importlib.util.spec_from_file_location("jt_ipam_cert_agent", _AGENT)
agent = importlib.util.module_from_spec(_spec)
try:
    _spec.loader.exec_module(agent)  # type: ignore[union-attr]
except SystemExit:  # PyYAML 缺失時模組會 sys.exit
    pytest.skip("PyYAML not available for agent import", allow_module_level=True)

BUNDLE = {
    "cert_pem": "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----",
    "chain_pem": "-----BEGIN CERTIFICATE-----\nCHAIN\n-----END CERTIFICATE-----",
    "key_pem": "-----BEGIN PRIVATE KEY-----\nKEY\n-----END PRIVATE KEY-----",
    "fingerprint": "abc123", "not_after": "2030-01-01T00:00:00+00:00",
}


def test_content_kinds():
    assert "LEAF" in agent._content("cert", BUNDLE)
    assert "CHAIN" not in agent._content("cert", BUNDLE)
    fc = agent._content("fullchain", BUNDLE)
    assert "LEAF" in fc
    assert "CHAIN" in fc
    assert "KEY" not in fc
    comb = agent._content("combined", BUNDLE)
    assert "LEAF" in comb
    assert "CHAIN" in comb
    assert "KEY" in comb


def test_profile_path_resolution_and_override():
    t = agent._resolve_files({"cert": "wild", "profile": "nginx"}, agent.PROFILES["nginx"], "wild")
    kinds = {k: p for k, p, _ in t}
    assert kinds["fullchain"].endswith("wild.fullchain.pem")
    assert kinds["key"].endswith("wild.key")
    # config 覆寫路徑
    t2 = agent._resolve_files(
        {"cert": "w", "profile": "nginx", "key_path": "/custom/x.key"},
        agent.PROFILES["nginx"], "w")
    assert any(p == "/custom/x.key" for _, p, _ in t2)


def test_dry_run_writes_nothing(tmp_path):
    target = tmp_path / "out.pem"
    dep = {"cert": "x", "profile": "generic", "fullchain_path": str(target),
           "reload": "true"}
    res = agent.apply_deployment(dep, BUNDLE, dry_run=True)
    assert res["status"] == "dry-run"
    assert not target.exists()  # dry-run 不動檔


def test_generic_without_paths_fails():
    res = agent.apply_deployment({"cert": "x", "profile": "generic"}, BUNDLE, dry_run=False)
    assert res["status"] == "failed"


def test_real_apply_writes_and_runs(tmp_path):
    crt = tmp_path / "a.fullchain.pem"
    key = tmp_path / "a.key"
    dep = {"cert": "a", "profile": "generic",
           "fullchain_path": str(crt), "key_path": str(key),
           "test": "true", "reload": "true"}  # 用 true 當作 config-test/reload
    res = agent.apply_deployment(dep, BUNDLE, dry_run=False)
    assert res["status"] == "ok", res
    assert "LEAF" in crt.read_text()
    assert "CHAIN" in crt.read_text()
    assert "KEY" in key.read_text()
    assert oct(os.stat(key).st_mode)[-3:] == "600"  # 私鑰 0600


def test_apply_rolls_back_on_reload_failure(tmp_path):
    crt = tmp_path / "b.fullchain.pem"
    crt.write_text("OLD-CERT")  # 既有內容
    dep = {"cert": "b", "profile": "generic", "fullchain_path": str(crt),
           "reload": "false"}  # reload 失敗 → 應回滾
    res = agent.apply_deployment(dep, BUNDLE, dry_run=False)
    assert res["status"] == "failed"
    assert crt.read_text() == "OLD-CERT"  # 已回滾成舊內容


def test_self_update_noop_when_sha_matches(monkeypatch):
    """sha 相同 → 不下載、不 re-exec。"""
    calls = {"get": 0, "exec": 0}
    monkeypatch.setattr(agent, "_get_bytes", lambda *a, **k: calls.__setitem__("get", calls["get"] + 1))
    monkeypatch.setattr(agent.os, "execv", lambda *a: calls.__setitem__("exec", calls["exec"] + 1))
    agent._maybe_self_update({}, agent._self_sha())
    assert calls == {"get": 0, "exec": 0}


def test_self_update_disabled_by_config(monkeypatch):
    """auto_update: false → 即使 sha 不同也不動作。"""
    calls = {"get": 0}
    monkeypatch.setattr(agent, "_get_bytes", lambda *a, **k: calls.__setitem__("get", calls["get"] + 1))
    monkeypatch.setattr(agent.os, "execv", lambda *a: None)
    agent._maybe_self_update({"auto_update": False}, "different-sha-0000")
    assert calls["get"] == 0


def test_self_update_skips_on_sha_mismatch(monkeypatch):
    """下載內容 sha 與 server 宣告不符 → 不覆蓋、不 re-exec（防中間人/截斷）。"""
    calls = {"exec": 0}
    monkeypatch.setattr(agent, "_get_bytes", lambda *a, **k: b"tampered-bytes")
    monkeypatch.setattr(agent.os, "execv", lambda *a: calls.__setitem__("exec", calls["exec"] + 1))
    agent._maybe_self_update({}, "server-claims-this-sha")  # 與 tampered-bytes 的 sha 不符
    assert calls["exec"] == 0
