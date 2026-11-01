#!/usr/bin/env python3
"""Checks the OpenCode Go provider against the real OpenCode CLIs, without a subscription.

    swift build && python3 -I Scripts/verify-opencode.py [--out DIR]

Tinybar has no Go account to test with, so this runs OpenCode 1.x and 2.x against a local mock of
the Go API, each with its own HOME, and checks:

  - History: the rows the real CLIs write (responses, tool steps, forks, a compaction, the real
    1.x to 2.x upgrade) add up to the expected tokens in Tinybar, once each.
  - Logins: the credentials the real CLIs store are the ones Tinybar picks.
  - Limits: OpenCode's own client and Tinybar read the same mock responses and must agree. That
    keeps the mock honest: a shape OpenCode rejects fails here, not in production.
  - The live endpoint still answers 401 to an invalid key, in the shape the tests expect, and the
    live status page still reads.

What this can't show is what a real subscription returns, or that a Go key is accepted by the
usage endpoint. ADR 0009 lists that. Your real OpenCode data is never touched, and that is
checked at the end. Needs Node for npm. Set OC1/OC2 to test other versions.
"""
import argparse
import hashlib
import json
import os
import pty
import re
import select
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

OC1 = os.environ.get("OC1", "1.18.31")
OC2 = os.environ.get("OC2", "2.2.5")
ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build/debug"
MODEL = "opencode-go/glm-5.2"

# What the mock bills per request, and what OpenCode should make of it.
USAGE = {
    "prompt_tokens": 1200,
    "completion_tokens": 340,
    "total_tokens": 1540,
    "prompt_tokens_details": {"cached_tokens": 200},
    "completion_tokens_details": {"reasoning_tokens": 40},
}
PER_RESPONSE = {"input": 1000, "output": 340, "cache_write": 0, "cache_read": 200}
SUMMARY = "## Objective\nMock.\n\n## Next Move\nNone.\n"

# Without any OPENCODE_DB or the like of yours, which would point the CLIs at your real data.
CLEAN_ENV = {name: value for name, value in os.environ.items() if not name.startswith("OPENCODE_")}

failures = 0


def check(ok, what, detail=""):
    global failures
    print(("  ok    " if ok else "  FAIL  ") + what + (f"  ({detail})" if detail and not ok else ""))
    failures += 0 if ok else 1


# MARK: Mock of the Go API


class Mock(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    usage_response = (200, {})
    last_request = None

    def log_message(self, *_):
        pass

    def respond(self, status, body):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/zen/go/v1/usage":
            Mock.last_request = (self.headers.get("Authorization"), self.headers.get("x-opencode-org-id"))
            return self.respond(*Mock.usage_response)
        if self.path.endswith("/current-budgets"):
            return self.respond(200, [])
        self.respond(404, {"type": "error", "error": {"type": "NotFound", "message": self.path}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if not self.path.endswith("/chat/completions"):
            return self.respond(404, {"type": "error"})
        messages = body.get("messages", [])
        recent = json.dumps(messages[-3:])
        wants_tool = "USE-A-TOOL" in recent and not any(m.get("role") == "tool" for m in messages)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def chunk(delta, finish=None, usage=None):
            value = {
                "id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": int(time.time()),
                "model": body.get("model"), "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
            if usage:
                value["usage"] = usage
            self.wfile.write(f"data: {json.dumps(value)}\n\n".encode())
            self.wfile.flush()

        chunk({"role": "assistant", "content": ""})
        if wants_tool:
            call = {"name": "glob", "arguments": json.dumps({"pattern": "*"})}
            chunk({"tool_calls": [{"index": 0, "id": "call_mock", "type": "function", "function": call}]})
            finish = "tool_calls"
        else:
            chunk({"content": SUMMARY if "<template>" in json.dumps(messages) else "Mock reply."})
            finish = "stop"
        chunk({}, finish)
        chunk({}, finish, USAGE)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


# MARK: OpenCode, each version in its own HOME


class OpenCode:
    def __init__(self, binary, home, mock, version):
        self.binary, self.home, self.mock, self.version = str(binary), Path(home), mock, version
        self.server = None
        (self.home / "work").mkdir(parents=True, exist_ok=True)
        (self.home / ".config/opencode").mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "-q", "."], cwd=self.home / "work", check=True)
        base = f"{mock}/zen/go/v1"
        config = (
            {"provider": {"opencode-go": {"options": {"apiKey": "mock-key", "baseURL": base}}}}
            if version == 1
            else {"providers": {"opencode-go": {"settings": {"apiKey": "mock-key", "baseURL": base}}}}
        )
        (self.home / ".config/opencode/opencode.json").write_text(json.dumps(config))

    @property
    def env(self):
        h = str(self.home)
        return {
            **CLEAN_ENV, "HOME": h, "XDG_DATA_HOME": f"{h}/.local/share", "XDG_CONFIG_HOME": f"{h}/.config",
            "XDG_STATE_HOME": f"{h}/.local/state", "XDG_CACHE_HOME": f"{h}/.cache",
            "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_SERVER_PASSWORD": "verify", "TERM": "xterm",
            "PWD": f"{h}/work",  # OpenCode takes its directory from here
        }

    @property
    def database(self):
        return self.home / ".local/share/opencode/opencode.db"

    def ask(self, *args):
        # Without --standalone, 2.x starts a background service that outlives the run.
        flags = ["--standalone"] if self.version == 2 else []
        r = subprocess.run(
            [self.binary, *flags, "run", "-m", MODEL, *args], cwd=self.home / "work", env=self.env,
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
        if r.returncode != 0 or "Mock reply" not in r.stdout + r.stderr:
            raise SystemExit(f"opencode run failed:\n{r.stdout}\n{r.stderr}")

    def login_with_terminal(self, key):
        """1.x asks for the key on a terminal, so answer it on one."""
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.home / "work")
            os.execvpe(self.binary, [self.binary, "auth", "login", "--provider", "opencode-go"], self.env)
        sent, last, end = False, time.time(), time.time() + 30
        while time.time() < end:
            if select.select([fd], [], [], 0.5)[0]:
                try:
                    if not os.read(fd, 4096):
                        break
                except OSError:
                    break
                last = time.time()
            if not sent and time.time() - last > 2:
                os.write(fd, key.encode() + b"\r")
                sent = True
        os.waitpid(pid, 0)

    def serve(self, port):
        self.server = subprocess.Popen(
            [self.binary, "serve", "--port", str(port), "--hostname", "127.0.0.1"], cwd=self.home / "work",
            env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.api = f"http://127.0.0.1:{port}"
        for _ in range(60):
            try:
                self.call("GET", "/api/integration")
                return
            except (urllib.error.URLError, ConnectionError):
                time.sleep(0.5)
        raise SystemExit("opencode serve did not start")

    def call(self, method, path, body=None):
        request = urllib.request.Request(self.api + path, method=method, data=None if body is None else json.dumps(body).encode())
        request.add_header("Authorization", "Basic b3BlbmNvZGU6dmVyaWZ5")  # opencode:verify
        request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read()
        return json.loads(text) if text else None

    def stop(self):
        if self.server:
            self.server.terminate()
            self.server.wait(timeout=10)
            self.server = None


# MARK: Tinybar, pointed at the same HOME


class Tinybar:
    def __init__(self, scratch, opencode_home):
        self.db = Path(scratch) / "tinybar.sqlite"
        self.home = Path(scratch) / "home"
        self.home.mkdir(parents=True, exist_ok=True)
        self.env = {
            **CLEAN_ENV, "HOME": str(self.home), "CFFIXED_USER_HOME": str(self.home),
            "XDG_DATA_HOME": f"{opencode_home}/.local/share", "TINYBAR_DB": str(self.db),
            "CODEX_HOME": str(self.home / "codex"), "CLAUDE_CONFIG_DIR": str(self.home / "claude"),
        }

    def cli(self, *args):
        return subprocess.run([BIN / "tinybar-cli", *args], env=self.env, capture_output=True, text=True, timeout=60).stdout

    def ingest(self):
        self.cli("ingest", str(self.db))

    def tokens(self):
        row = rows(self.db, "SELECT sum(input), sum(output), sum(cache_write), sum(cache_read) FROM daily_usage WHERE provider = 'opencode'")[0]
        return dict(zip(PER_RESPONSE, (value or 0 for value in row)))

    def limits(self):
        """{'5-hour': (left, 'resets in …')}, or the error line."""
        out = self.cli("limits", "--provider=opencode")
        found = {m[1].strip(): (float(m[2]), m[3]) for m in re.finditer(r"^  (.+?)\s+([\d.]+)% left  resets in (\S+(?: \S+)?)", out, re.M)}
        error = re.search(r"error: (.*)", out)
        return found, error[1] if error else None


def expect_responses(tinybar, n, what):
    tinybar.ingest()
    got = tinybar.tokens()
    want = {k: v * n for k, v in PER_RESPONSE.items()}
    check(got == want, f"{what}: {n} responses, {want['input'] + want['output'] + want['cache_read']} tokens", str(got))
    tinybar.ingest()
    check(tinybar.tokens() == got, f"{what}: reading again adds nothing")


def expect_limit_error(tinybar, want, what):
    windows, error = tinybar.limits()
    check(error == want, what, str((windows, error)))


def stamp(hours):
    return (datetime.now(timezone.utc) + timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def meter(percent, hours=3, status="ok"):
    return {"status": status, "percent": percent, "resetsAt": stamp(hours)}


def fingerprint(directory):
    h = hashlib.sha256()
    for path in sorted(p for p in directory.rglob("*") if p.is_file() and p.parent.name != "log"):
        h.update(str(path).encode())
        h.update(path.read_bytes() if path.stat().st_size < 500_000_000 else b"")
    return h.hexdigest()


def rows(database, sql):
    with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as db:
        return db.execute(sql).fetchall()


def install(root, package, version):
    prefix = root / package.replace("/", "-")
    prefix.mkdir()
    subprocess.run(["npm", "install", "--no-audit", "--no-fund", "--silent", "--prefix", str(prefix), f"{package}@{version}"], check=True, capture_output=True)
    return prefix / "node_modules/.bin/opencode"


# MARK: The checks


def live_endpoint():
    print("\nThe live endpoint, with an invalid key")
    request = urllib.request.Request("https://opencode.ai/zen/go/v1/usage", headers={"Authorization": "Bearer invalid-tinybar-check", "Accept": "application/json", "User-Agent": "Tinybar"})
    try:
        with urllib.request.urlopen(request, timeout=20) as r:
            status, body = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, body = e.code, e.read()
    check(status == 401, "answers 401", str(status))
    check(json.loads(body) == {"type": "error", "error": {"type": "AuthError", "message": "Unauthorized"}}, "with the body the tests use", body.decode()[:200])
    status = subprocess.run([BIN / "tinybar-cli", "status"], capture_output=True, text=True, timeout=60).stdout
    check(re.search(r"^OpenCode Go: (no incidents|Degraded|Major outage)", status, re.M) is not None, "Tinybar reads the live status page", status)


def history_and_logins(root, binary1, binary2, mock):
    print(f"\nOpenCode {OC1}: login and history")
    one = OpenCode(binary1, root / "one", mock, 1)
    tinybar = Tinybar(root / "tinybar", one.home)
    expect_limit_error(tinybar, "Not signed in", "no login yet: not signed in")

    one.login_with_terminal("mock-1x-key")
    auth = json.loads((one.home / ".local/share/opencode/auth.json").read_text())
    check(auth.get("opencode-go") == {"type": "api", "key": "mock-1x-key"}, "1.x stores the key in auth.json", str(auth))
    one.ask("say hi")
    check(rows(one.database, "SELECT count(*) FROM credential") == [(0,)], "1.x leaves the credential table empty")
    # This key is invalid, so the real server turns it away: the key was found and sent to OpenCode.
    expect_limit_error(tinybar, "Login expired", "Tinybar finds the 1.x key, and opencode.ai rejects it")

    expect_responses(tinybar, 1, "one turn")
    one.ask("--continue", "second turn")
    expect_responses(tinybar, 2, "another turn")
    one.ask("USE-A-TOOL please")
    expect_responses(tinybar, 4, "a tool call, two steps")
    one.ask("--continue", "--fork", "forked turn")
    forks = rows(one.database, "SELECT count(*) FROM message WHERE json_extract(data, '$.role') = 'assistant'")[0][0]
    check(forks > 5, "the fork copied earlier responses under new ids", str(forks))
    expect_responses(tinybar, 5, "a fork counts only its new turn")

    print(f"\nThe real upgrade to OpenCode {OC2}, on a copy")
    two = OpenCode(binary2, root / "upgraded", mock, 2)
    shutil.copytree(one.home / ".local", two.home / ".local")
    tinybar = Tinybar(root / "tinybar", two.home)
    two.ask("after the upgrade")
    tables = {r[0] for r in rows(two.database, "SELECT name FROM sqlite_master WHERE type = 'table'")}
    check({"message", "session_message", "session_v2"} <= tables, "2.x keeps the old table beside the new one")
    credentials = rows(two.database, "SELECT integration_id, active, value FROM credential")
    check(len(credentials) == 1 and credentials[0][1] is None, "the converted key has no active flag", str(credentials))
    expect_limit_error(tinybar, "Login expired", "Tinybar still finds that key")
    expect_responses(tinybar, 6, "upgraded: only the new turn counts")
    two.ask("--continue", "--fork", "fork on 2.x")
    expect_responses(tinybar, 7, "2.x fork: only its new turn counts")
    # Logging out empties the table and leaves auth.json behind, which must then not count.
    with sqlite3.connect(two.database) as db:
        db.execute("DELETE FROM credential")
    check((two.home / ".local/share/opencode/auth.json").exists(), "2.x leaves auth.json behind")
    expect_limit_error(tinybar, "Not signed in", "stale auth.json is ignored on 2.x")
    return one


def differential(root, binary2, mock):
    print(f"\nLimits: OpenCode {OC2}'s client and Tinybar on the same responses")
    two = OpenCode(binary2, root / "two", mock, 2)
    two.serve(48772)
    created = two.call("POST", "/api/credential", {
        "integrationID": "opencode", "label": "Mock", "activate": True,
        "value": {"type": "key", "key": "mock-console-key", "metadata": {"server": f"{mock}/console", "orgID": "wrk_mock", "orgName": "Mock"}},
    })
    check(created["data"]["active"], "real 2.x stored a Console login")
    tinybar = Tinybar(root / "tinybar-two", two.home)
    resets = stamp(3)

    def opencode_reads():
        try:
            return two.call("GET", "/api/experimental/usage/limits")["data"].get("go"), None
        except urllib.error.HTTPError as e:
            return None, e.code

    def scenario(name, status, body, tinybar_error, opencode_status=None):
        Mock.usage_response = (status, body)
        go, failed = opencode_reads()
        client, Mock.last_request = Mock.last_request, None
        windows, error = tinybar.limits()
        check(client is not None and client == Mock.last_request, f"{name}: same token and workspace as OpenCode's request", f"{client} / {Mock.last_request}")
        if tinybar_error:
            check(error == tinybar_error, f"{name}: Tinybar says \"{tinybar_error}\"", str((windows, error)))
            check(go is None, f"{name}: OpenCode shows no allowance either", str((go, failed)))
            if opencode_status:
                check(failed == opencode_status, f"{name}: OpenCode answers {opencode_status}", str(failed))
            return
        check(go is not None and failed is None, f"{name}: OpenCode accepts the response", str((go, failed)))
        if go is None:
            return
        for key, title in (("rolling", "5-hour"), ("weekly", "Weekly"), ("monthly", "Monthly")):
            left = windows.get(title, (None,))[0]
            want = 0 if go[key]["limited"] else 100 - go[key]["percent"]
            check(left == want, f"{name}: {title} {want:g}% left in both", f"Tinybar {windows}")
        check(go["rolling"]["resetsAt"] == int(datetime.strptime(resets, "%Y-%m-%dT%H:%M:%S.000Z").replace(tzinfo=timezone.utc).timestamp() * 1000), f"{name}: OpenCode reads the Reset we sent")
        check(windows["5-hour"][1].startswith(("2h", "3h")), f"{name}: Tinybar shows the same Reset", windows["5-hour"][1])

    fixed = lambda percent, status="ok": {**meter(percent, status=status), "resetsAt": resets}
    ok = {"usage": {"rolling": fixed(42), "weekly": fixed(18), "monthly": fixed(100, "rate-limited")}}
    scenario("usual", 200, ok, None)
    scenario("limited below 100%", 200, {"usage": {"rolling": fixed(97, "rate-limited"), "weekly": fixed(0), "monthly": fixed(12.5)}}, None)
    scenario("no Go in this workspace", 403, {"type": "error"}, "This OpenCode login has no Go subscription")
    scenario("rejected login", 401, {"type": "error", "error": {"type": "AuthError", "message": "Unauthorized"}}, "Login expired", 503)
    # OpenCode reads every 403 as no Go; Tinybar tells a firewall's block apart, so no comparison.
    Mock.usage_response = (403, {"type": "https://developers.cloudflare.com/support/troubleshooting/", "title": "Error 1010: Access denied", "status": 403})
    expect_limit_error(tinybar, "OpenCode API returned HTTP 403", "firewall block: not mistaken for no subscription")
    scenario("server error", 500, b"oops", "OpenCode API returned HTTP 500", 503)
    scenario("not JSON", 200, b"<html></html>", "Unexpected OpenCode usage response", 503)
    Mock.usage_response = (429, {"type": "error"})
    expect_limit_error(tinybar, "Rate limited by provider", "rate limited: Tinybar backs off")
    two.stop()
    return two


def history_on_v2(two):
    print(f"\nOpenCode {OC2}: history in a fresh database")
    tinybar = Tinybar(two.home.parent / "tinybar-v2", two.home)
    two.ask("say hi")
    expect_responses(tinybar, 1, "one turn")
    two.ask("USE-A-TOOL please")
    expect_responses(tinybar, 3, "a tool call, two steps")
    two.serve(48773)
    session = rows(two.database, "SELECT id FROM session_v2 ORDER BY time_created DESC LIMIT 1")[0][0]
    two.call("POST", f"/api/session/{session}/compact", {})
    for _ in range(40):
        done = rows(two.database, "SELECT json_extract(data, '$.status') FROM session_message WHERE type = 'compaction'")
        if done and done[0][0] != "running":
            break
        time.sleep(0.25)
    check(done and done[0][0] == "completed", "a real compaction finished", str(done))
    expect_responses(tinybar, 4, "a compaction is billed too")
    two.stop()
    project = rows(tinybar.db, "SELECT project FROM daily_usage WHERE provider = 'opencode'")[0][0]
    check(Path(project).name == "work", "the Project comes from the session's directory", project)

    # A store from before OpenCode: normal ingestion waits, and the child process reads it once.
    with sqlite3.connect(tinybar.db) as db:
        db.executescript(
            "DELETE FROM daily_usage WHERE provider = 'opencode'; DELETE FROM opencode_message;"
            "DELETE FROM meta WHERE key IN ('opencode_cursor', 'opencode_import');")
    tinybar.ingest()
    check(tinybar.tokens()["input"] == 0, "an upgraded store leaves the first read to the child process")
    child = subprocess.run([BIN / "Tinybar", "--import-opencode"], env=tinybar.env, capture_output=True, timeout=60)
    check(child.returncode == 0, "the child process finishes", str(child.returncode))
    expect_responses(tinybar, 4, "upgraded store")


def cost(one):
    print("\nPrices: Tinybar's Theoretical Cost against what OpenCode recorded")
    request = urllib.request.Request("https://models.dev/api.json", headers={"User-Agent": "Tinybar"})
    with urllib.request.urlopen(request, timeout=30) as r:
        price = json.load(r)["opencode-go"]["models"]["glm-5.2"]["cost"]
    recorded = rows(one.database, "SELECT json_extract(data, '$.cost') FROM message WHERE json_extract(data, '$.role') = 'assistant' LIMIT 1")[0][0]
    t = PER_RESPONSE
    ours = (t["input"] * price["input"] + t["output"] * price["output"] + t["cache_read"] * price["cache_read"]) / 1e6
    check(abs(ours - recorded) < 1e-9, f"one response: ${ours:.6f}, the same as OpenCode's", f"OpenCode {recorded}")


def screenshots(two, root, out):
    print("\nThe app itself")
    if not (BIN / "Tinybar").exists():
        return check(False, "no debug build of the app")
    # A Go key for the auto-detection, pointed at the mock.
    with sqlite3.connect(two.database) as db:
        db.execute("DELETE FROM credential")
        value = json.dumps({"type": "key", "key": "mock-go-key", "metadata": {"server": f"{two.mock}/console", "orgID": "wrk_mock"}})
        db.execute("INSERT INTO credential (id, integration_id, label, value, active, time_created, time_updated) VALUES ('cred_verify', 'opencode-go', 'Go', ?, 1, 1, 1)", (value,))
    Mock.usage_response = (200, {"usage": {"rolling": meter(42), "weekly": meter(18, 100), "monthly": meter(61, 400)}})
    tinybar = Tinybar(root / "tinybar-v2", two.home)
    out.mkdir(parents=True, exist_ok=True)
    for page in ("opencode", "overview", "settings"):
        path = out / f"{page}.png"
        args = [BIN / "Tinybar", "--snapshot", path] + ([] if page == "overview" else ["--page", page])
        r = subprocess.run(args, env=tinybar.env, capture_output=True, text=True, timeout=120)
        check(r.returncode == 0 and path.exists(), f"rendered {path}", r.stderr[-300:])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, help="where to keep the app's screenshots")
    args = parser.parse_args()
    if not (BIN / "tinybar-cli").exists():
        raise SystemExit("Run `swift build` first.")
    real = Path.home() / ".local/share/opencode"
    before = fingerprint(real) if real.exists() else None

    root = Path(tempfile.mkdtemp(prefix="verify-opencode-")).resolve()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    mock = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        live_endpoint()
        print(f"\nInstalling OpenCode {OC1} and {OC2} (a temporary folder)")
        binary1 = install(root, "opencode-ai", OC1)
        binary2 = install(root, "@opencode/cli", OC2)
        cost(history_and_logins(root, binary1, binary2, mock))
        two = differential(root, binary2, mock)
        history_on_v2(two)
        screenshots(two, root, args.out or root / "screenshots")
    finally:
        subprocess.run(["pkill", "-f", str(root)], check=False)
        time.sleep(2)
        check(not subprocess.run(["pgrep", "-f", str(root)], capture_output=True).stdout, "no OpenCode process left running")
        print("\nYour own OpenCode data")
        if before:
            check(fingerprint(real) == before, f"{real} is unchanged")
        shutil.rmtree(root, ignore_errors=True)
    print(f"\n{'All checks passed.' if failures == 0 else f'{failures} checks FAILED.'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
