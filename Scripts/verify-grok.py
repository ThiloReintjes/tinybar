#!/usr/bin/env python3
"""Checks the Grok provider against the real Grok CLI, without an xAI account.

    swift build && python3 -I Scripts/verify-grok.py

This repo's owner has no Grok plan, so this runs the real CLI against a local mock of xAI's usage
endpoints, with its own home folder, and checks:

  - Limits: Grok's own client (`_x.ai/billing`, what its `/usage` reads) and Tinybar read the same
    responses and must agree. That keeps the mock honest: a shape the real client rejects fails here,
    not in production. The reports follow what CodexBar's users captured from live accounts.
  - Logins: Tinybar sends the same login as the real CLI, to the same address, and leaves alone what
    the CLI itself refuses. It never renews a login, and never writes to the CLI's files.
  - The live services: the real endpoints still answer an invalid token as Tinybar expects, through
    Tinybar itself, and the live status page still lists grok.com.

What this can't show is a real plan's response, the file a real `grok login` writes, or what a team
account gets. ADR 0012 lists that. Your real files are never touched, and that is checked at the end.
Downloads the CLI (about 180 MB) unless GROK points at one. GROK_VERSION tests another release.
"""
import hashlib
import json
import os
import platform
import re
import select
import shutil
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

VERSION = os.environ.get("GROK_VERSION", "1.0.70")
XAI_TEAM = "5Y6N3AJ54S"
ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build/debug"
LIVE = "https://cli-chat-proxy.grok.com/v1"
BILLING = "/v1/billing?format=credits"
SCOPE = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"
LEGACY_SCOPE = "https://accounts.x.ai/sign-in"
# These only ever go to the mock, except INVALID, which is what the live checks are for.
TOKEN = "mock-access-token"
INVALID = "not-a-real-token-from-tinybar"
PLAN = "SuperGrok Heavy"

failures = 0
passes = 0


def check(ok, what, detail=""):
    global failures, passes
    if ok:
        passes += 1
    else:
        failures += 1
    print(f"  {'ok  ' if ok else 'FAIL'} {what}{'' if ok or not detail else f': {detail}'}")


def stamp(when):
    """The live endpoint's own format: microseconds and +00:00."""
    return when.strftime("%Y-%m-%dT%H:%M:%S.537749+00:00")


NOW = datetime.now(timezone.utc)
START, END = NOW - timedelta(days=2), NOW + timedelta(days=5)
WEEK = {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": stamp(START), "end": stamp(END)}
MONTH = {"type": "USAGE_PERIOD_TYPE_MONTHLY", "start": stamp(NOW - timedelta(days=10)), "end": stamp(NOW + timedelta(days=20))}


def live_shape(percent, products, **extra):
    """As CodexBar's users captured it, with this week's dates."""
    config = {
        "currentPeriod": WEEK, "creditUsagePercent": percent, "onDemandCap": {"val": 0}, "onDemandUsed": {"val": 0},
        "productUsage": [{"product": k, "usagePercent": v} for k, v in products.items()], "isUnifiedBillingUser": True,
        "prepaidBalance": {"val": 0}, "topUpMethod": "TOP_UP_METHOD_SAVED_PAYMENT_METHOD",
        "billingPeriodStart": WEEK["start"], "billingPeriodEnd": WEEK["end"], **extra,
    }
    return {"config": {k: v for k, v in config.items() if v is not None}}


REPORTS = {
    "live-one-product": live_shape(1.0, {"GrokBuild": 1.0}),
    "live-two-products": live_shape(6.0, {"GrokChat": 4.0, "GrokBuild": 2.0}),
    "fractional": live_shape(37.25, {"GrokBuild": 37.25}),
    "used-up": live_shape(100.0, {"GrokBuild": 46.0, "GrokChat": 54.0}),
    "over": live_shape(104.2, {"GrokBuild": 104.2}),
    "zero-left-out": live_shape(None, {}),
    "monthly": live_shape(42.5, {"GrokBuild": 42.5}, currentPeriod=MONTH),
    "on-demand": live_shape(100.0, {"GrokBuild": 100.0}, onDemandCap={"val": 5000}, onDemandUsed={"val": 300}),
    "on-demand-zero-as-empty": live_shape(10.0, {"GrokBuild": 10.0}, onDemandCap={"val": 500}, onDemandUsed={}),
}
# The CLI treats these as an answer or an error too. Tinybar has nothing to draw from them.
NO_LIMIT = "Grok reports no usage limit for this account"
EMPTY = {"no-config": {}, "null-config": {"config": None}}
# From the CLI's own test: use in `used`, no percent. It reads this, and a bar from it would say nothing used.
LEGACY = {"config": {"monthlyLimit": {"val": 2000}, "used": {"val": 1234}, "billingPeriodStart": MONTH["start"], "billingPeriodEnd": MONTH["end"]}}
BROKEN = {"percent-as-text": {"config": {"creditUsagePercent": "12", "currentPeriod": WEEK}}, "not-an-object": ["no"]}
ENDED = live_shape(95.0, {"GrokBuild": 95.0}, currentPeriod={"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": stamp(NOW - timedelta(days=8)), "end": stamp(NOW - timedelta(days=1))})
SCENARIOS = REPORTS | EMPTY | BROKEN | {"legacy": LEGACY, "ended": ENDED}


class Mock(BaseHTTPRequestHandler):
    """xAI's CLI proxy. Only an invented token ever reaches it."""
    scenario = "live-one-product"
    settings = {"subscription_tier_display": PLAN, "on_demand_enabled": True}
    requests = []

    def log_message(self, *_):
        pass

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        headers = {k.lower(): v for k, v in self.headers.items()}
        Mock.requests.append({"method": "GET", "path": self.path, "headers": headers})
        if not headers.get("authorization", "").startswith("Bearer mock-"):
            return self.answer(401, {"error": "Invalid or expired credentials (auth_kind=bearer, reason=no auth context)"})
        if self.path == BILLING:
            return self.answer(200, SCENARIOS[Mock.scenario])
        if self.path == "/v1/settings":
            return self.answer(200, Mock.settings)
        return self.answer(200, {})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        Mock.requests.append({"method": "POST", "path": self.path, "headers": {}})
        self.answer(404, {"error": "not found"})


class Grok:
    """The real CLI as an editor runs it: an agent speaking JSON-RPC on stdio, in a sandbox."""
    # With GROK set, the binary isn't under the temporary folder, so a search by that path won't find it.
    running = []

    def __init__(self, binary, home, base):
        grok_home = home / ".grok"
        env = {"HOME": str(home), "GROK_HOME": str(grok_home), "PATH": "/usr/bin:/bin", "TERM": "dumb",
               "GROK_CLI_CHAT_PROXY_BASE_URL": base}
        self.process = subprocess.Popen(
            [str(binary), "agent", "stdio"], cwd=home, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        Grok.running.append(self)
        self.next_id = 0
        self.buffer = b""
        self.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})

    def call(self, method, params, timeout=40):
        self.next_id += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}).encode() + b"\n")
        self.process.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") == self.next_id:
                    return message
            if select.select([self.process.stdout], [], [], 1)[0]:
                chunk = os.read(self.process.stdout.fileno(), 1 << 16)
                if not chunk:
                    break
                self.buffer += chunk
        raise SystemExit(f"Grok didn't answer {method}")

    def billing(self):
        return self.call("_x.ai/billing", {})

    def close(self):
        self.process.kill()
        self.process.wait()
        Grok.running.remove(self)


def cli_billing(binary, home, base):
    """One read by a fresh real CLI, for checks that need only its answer."""
    client = Grok(binary, home, base)
    answer = client.billing()
    client.close()
    return answer


def tinybar(home, base=None):
    """Tinybar's reading, as (error, plan, {title: left}, extra usage line)."""
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "GROK_HOME": str(home / ".grok")}
    if base:
        env["GROK_CLI_CHAT_PROXY_BASE_URL"] = base
    out = subprocess.run([BIN / "tinybar-cli", "limits", "--provider=grok"], capture_output=True, text=True, timeout=60, env=env).stdout
    error = re.search(r"Grok error: (.*)", out)
    head = re.search(r"Grok (.*?) ?\[source", out)
    windows = {m[0].strip(): float(m[1]) for m in re.findall(r"^  (.+?)\s+(-?[\d.]+)% left", out, re.M)}
    extra = re.search(r"extra usage: (.*)", out)
    return (error[1] if error else None, head[1] if head else None, windows, extra[1] if extra else None)


def write_login(home, entries):
    folder = home / ".grok"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "auth.json"
    path.write_text(json.dumps(entries, indent=2))
    path.chmod(0o600)
    return path


def entry(token=TOKEN, mode="oidc", **extra):
    """The fields the CLI's `GrokAuth` requires and writes, from its source."""
    return {"key": token, "auth_mode": mode, "create_time": stamp(NOW - timedelta(hours=1)), "user_id": "mock-user", "email": "mock@example.com",
            "team_id": "mock-personal-team", "oidc_issuer": "https://auth.x.ai", "oidc_client_id": SCOPE.split("::")[1],
            "refresh_token": "mock-refresh-token", "expires_at": stamp(NOW + timedelta(days=3)), **extra}


def fingerprint(folder):
    return {str(file): hashlib.sha256(file.read_bytes()).hexdigest()
            for file in folder.rglob("*") if file.is_file() and "logs" not in file.parts}


def expected(report):
    """What the real client's answer means for a bar: {title: left}."""
    config = report.get("config")
    if not config:
        return {}
    kind = (config.get("currentPeriod") or {}).get("type", "")
    title = {"USAGE_PERIOD_TYPE_WEEKLY": "Weekly", "USAGE_PERIOD_TYPE_MONTHLY": "Monthly"}.get(kind, "Credits")
    used = config.get("creditUsagePercent", 0)
    return {title: round(min(max(100 - used, 0), 100), 1)}


def differential(root, binary, base):
    print(f"\nLimits: Grok {VERSION}'s own client and Tinybar read the same responses")
    home = root / "differential"
    write_login(home, {SCOPE: entry()})
    client = Grok(binary, home, base)
    for name in REPORTS:
        Mock.scenario = name
        theirs = client.billing()
        ok = "result" in theirs and theirs["result"].get("config") is not None
        check(ok, f"{name}: the real CLI accepts it", str(theirs)[:300])
        if not ok:
            continue
        result = theirs["result"]
        sent = SCENARIOS[name]["config"]
        check(result["config"].get("creditUsagePercent") == sent.get("creditUsagePercent"), f"{name}: and reads the same share")
        error, plan, windows, extra = tinybar(home, base)
        check(error is None and windows == expected(result), f"{name}: Tinybar shows {windows}", f"error {error}, wanted {expected(result)}")
        check(plan == result.get("subscription_tier") == PLAN, f"{name}: both name the plan", f"{plan} vs {result.get('subscription_tier')}")
        cap, used = (result["config"].get(k, {}).get("val", 0) for k in ("onDemandCap", "onDemandUsed"))
        if cap or used:
            check(extra == f"{used / 100:.2f} / {cap / 100:.2f} USD", f"{name}: on-demand spend is in cents, as the CLI's source says", str(extra))
        else:
            check(extra is None, f"{name}: no on-demand spend to show", str(extra))
    for name in EMPTY:
        Mock.scenario = name
        theirs = client.billing()
        check((theirs.get("result") or {}).get("config") is None, f"{name}: the real CLI finds no config", str(theirs)[:200])
        error, _, windows, _ = tinybar(home, base)
        check(error == NO_LIMIT and not windows, f"{name}: Tinybar says so", str(error))
    Mock.scenario = "legacy"
    theirs = client.billing()
    check((theirs.get("result") or {}).get("config", {}).get("used", {}).get("val") == 1234, "legacy: the real CLI reads the older report", str(theirs)[:200])
    error, _, windows, _ = tinybar(home, base)
    check(error == NO_LIMIT and not windows, "legacy: Tinybar doesn't call that nothing used", str(error))
    Mock.scenario = "ended"
    check("result" in client.billing(), "ended: the real CLI reads a period that's over")
    error, _, windows, _ = tinybar(home, base)
    check(error == "Grok reported a usage period that has already ended" and not windows, "ended: Tinybar won't call that a fresh reading", str(error))
    for name in BROKEN:
        Mock.scenario = name
        theirs = client.billing()
        check("error" in theirs, f"{name}: the real CLI rejects it", str(theirs)[:200])
        error, _, windows, _ = tinybar(home, base)
        check(error == "Unexpected Grok usage response" and not windows, f"{name}: Tinybar rejects it too", str(error))
    client.close()
    Mock.scenario = "live-one-product"


def logins(root, binary, base):
    print("\nLogins: the file the real CLI reads")
    home = root / "logins"
    path = write_login(home, {SCOPE: entry()})
    Mock.requests.clear()
    answer = cli_billing(binary, home, base)
    theirs = next((r for r in Mock.requests if r["path"] == BILLING), None)
    check("result" in answer and theirs is not None, "the real CLI uses this login", str(answer)[:300])
    written = (home / ".grok/config.toml").read_text() if (home / ".grok/config.toml").exists() else ""

    Mock.requests.clear()
    before = path.read_bytes()
    error, _, windows, _ = tinybar(home, base)
    ours = [r for r in Mock.requests if r["path"] == BILLING]
    check(error is None and windows, f"Tinybar reads it, with the config.toml the CLI wrote beside it ({written.count(chr(10))} lines)", str(error))
    check(len(ours) == 1 and theirs and ours[0]["headers"].get("authorization") == theirs["headers"].get("authorization"), "and sends the same login")
    check(ours and theirs and ours[0]["headers"].get("x-xai-token-auth") == theirs["headers"].get("x-xai-token-auth"), "with the CLI's token header")
    check(ours and ours[0]["headers"].get("user-agent") == "Tinybar", "and says it's Tinybar")
    paths = {r["path"] for r in Mock.requests}
    check(paths == {BILLING, "/v1/settings"} and all(r["method"] == "GET" for r in Mock.requests),
          "two reads and nothing else: no refresh, no prompt", str(paths))
    check(path.read_bytes() == before, "auth.json is left as it was")

    print("\nLogins: what the real CLI won't use, Tinybar leaves alone")
    for name, entries in {
        "an API key": {"xai::api_key": entry(mode="api_key")},
        "an old web login": {SCOPE: entry(mode="web_login")},
        "the same under its older name": {SCOPE: entry(mode="grok")},
        "another deployment's login": {"https://idp.example.com::client": entry(oidc_issuer="https://idp.example.com")},
        "an old web login beside an older good one": {SCOPE: entry(mode="web_login"), LEGACY_SCOPE: entry(token="mock-other-account")},
    }.items():
        strange = root / re.sub(r"\W+", "-", name)
        write_login(strange, entries)
        answer = cli_billing(binary, strange, base)
        check("error" in answer, f"{name}: the real CLI won't read billing with it", str(answer)[:200])
        Mock.requests.clear()
        error, *_ = tinybar(strange, base)
        check(error == "Not signed in" and not Mock.requests, f"{name}: Tinybar stays signed out and sends nothing", str(error))

    print("\nLogins: the rest")
    legacy = root / "legacy"
    write_login(legacy, {LEGACY_SCOPE: entry(token="mock-legacy-token")})
    answer = cli_billing(binary, legacy, base)
    check("result" in answer, "the real CLI still uses a login under the older scope", str(answer)[:200])
    Mock.requests.clear()
    error, _, windows, _ = tinybar(legacy, base)
    check(error is None and windows and all(r["headers"].get("authorization") == "Bearer mock-legacy-token" for r in Mock.requests),
          "and so does Tinybar", str(error))
    expired = root / "expired"
    write_login(expired, {SCOPE: entry(expires_at=stamp(NOW - timedelta(minutes=1)))})
    Mock.requests.clear()
    error, *_ = tinybar(expired, base)
    check(error == "Login expired" and not Mock.requests, "an expired login sends nothing and says so, for the CLI to renew", str(error))
    custom = root / "custom"
    write_login(custom, {SCOPE: entry()})
    (custom / ".grok/config.toml").write_text('[grok_com_config.oidc]\nissuer = "https://idp.example.com"\n')
    Mock.requests.clear()
    error, *_ = tinybar(custom, base)
    check(error == "Not signed in" and not Mock.requests, "a custom deployment is left to the CLI", str(error))
    error, *_ = tinybar(home, "https://proxy.example.com/v1")
    check(error == "Not signed in", "a login isn't sent to another server, even if the CLI is pointed at one", str(error))
    Mock.settings, kept = {"subscription_tier_display": ""}, Mock.settings
    _, plan, windows, _ = tinybar(home, base)
    check(not plan and windows, "no plan name still shows the limits", str(plan))
    Mock.settings = kept


def live(root):
    print("\nThe live services")
    for path in ("billing?format=credits", "settings"):
        request = urllib.request.Request(f"{LIVE}/{path}", headers={
            "Authorization": f"Bearer {INVALID}", "X-XAI-Token-Auth": "xai-grok-cli", "User-Agent": "Tinybar", "Accept": "application/json"})
        try:
            urllib.request.urlopen(request, timeout=20)
            check(False, f"{path}: an invalid token is refused")
        except urllib.error.HTTPError as error:
            body = json.loads(error.read() or b"{}")
            check(error.code == 401 and "error" in body, f"{path}: an invalid token gets 401", f"{error.code} {body}")
    home = root / "live"
    write_login(home, {SCOPE: entry(token=INVALID)})
    error, *_ = tinybar(home)
    check(error == "Login expired", "through Tinybar itself, that reads as an expired login", str(error))
    page = json.load(urllib.request.urlopen(urllib.request.Request(
        "https://status.x.ai/api/status", headers={"User-Agent": "Tinybar", "Accept": "application/json"}), timeout=20))
    grok = next((p for p in page.get("products", []) if p.get("id") == "grok"), {})
    site = next((c for c in grok.get("components", []) if c.get("id") == "grok-com"), None)
    check(site is not None and isinstance(site.get("status"), str), "the status page still lists grok.com", str(grok)[:300])
    print(f"       grok.com is {site and site.get('status')} right now")


def install(root):
    if binary := os.environ.get("GROK"):
        path = Path(binary).resolve()
    else:
        arch = "aarch64" if platform.machine() == "arm64" else "x86_64"
        path = root / "bin/grok"
        path.parent.mkdir()
        print(f"Downloading Grok {VERSION} (a temporary folder)")
        urllib.request.urlretrieve(f"https://x.ai/cli/grok-{VERSION}-macos-{arch}", path)
        path.chmod(0o755)
    signed_by_xai = f'anchor apple generic and certificate leaf[subject.OU] = "{XAI_TEAM}"'
    verified = subprocess.run(["codesign", "--verify", "--strict", f"-R={signed_by_xai}", path], capture_output=True)
    if verified.returncode != 0:
        raise SystemExit("That isn't a Grok CLI signed by xAI, so it won't be run.")
    return path


def main():
    if not (BIN / "tinybar-cli").exists():
        raise SystemExit("Run `swift build` first.")
    # A home folder doesn't sandbox this: the CLI would use a managed key and proxy from there.
    if Path("/etc/grok").exists():
        raise SystemExit("This Mac has a managed Grok config in /etc/grok, so the real CLI wouldn't stay on the mock.")
    real = Path.home() / ".grok"
    before = fingerprint(real)
    root = Path(tempfile.mkdtemp(prefix="verify-grok-")).resolve()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}/v1"
    try:
        binary = install(root)
        live(root)
        differential(root, binary, base)
        logins(root, binary, base)
    finally:
        for client in list(Grok.running):
            client.close()
        subprocess.run(["pkill", "-f", str(root)], check=False)
        time.sleep(1)
        check(not subprocess.run(["pgrep", "-f", str(root)], capture_output=True).stdout, "no Grok process left behind")
        print("\nYour own Grok data")
        check(fingerprint(real) == before, "~/.grok is unchanged")
        shutil.rmtree(root, ignore_errors=True)
    print(f"\nAll {passes} checks passed." if failures == 0 else f"\n{failures} of {passes + failures} checks FAILED.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
