#!/usr/bin/env python3
"""Checks the Copilot provider against the real Copilot CLI and gh, without a subscription.

    swift build && python3 -I Scripts/verify-copilot.py

This repo's owner has no active Copilot plan, so this runs the real Copilot CLI against a local mock
of GitHub's usage endpoint, with its own home folder and CA, and checks:

  - Limits: Copilot's own client and Tinybar read the same responses and must agree. That keeps the
    mock honest: a shape the real client rejects fails here, not in production.
  - Logins: the login the real CLI stores and the token the real `gh` hands out are what Tinybar
    sends, to the right server, and a login for any other server is never sent. Tinybar never lets
    a `gh` that can renew a token do so.
  - The live endpoint still answers 401 to an invalid token, the live status page still lists
    Copilot, and with a `gh` login, Tinybar and the real CLI agree on that real account.

What this can't show is a real active plan's response, the Keychain prompt, or a real editor plugin's
login. ADR 0011 lists that. Your real files are never touched, and that is checked at the end. Needs
Node for npm, gh and openssl. Set COPILOT to test another CLI version.
"""
import hashlib
import json
import os
import platform
import re
import select
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

COPILOT = os.environ.get("COPILOT", "1.0.105")
# Newer than this renews tokens unless told not to. Whatever `gh` is installed is tried as well.
GH = os.environ.get("GH", "2.103.3")
ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build/debug"
# Real tokens only ever come from `gh` and only go to GitHub. These go to the mock.
TOKEN = "gho_" + "mock0123456789" * 2
OTHER_TOKEN = "gho_" + "other012345678" * 2
LOGIN = "mock-user"
STAMP = "2026-11-02T09:00:00.000Z"
RESET = "2026-12-01T00:00:00.000Z"

failures = 0
passes = 0


def check(ok, what, detail=""):
    global failures, passes
    if ok:
        passes += 1
    else:
        failures += 1
    print(f"  {'ok  ' if ok else 'FAIL'} {what}{'' if ok or not detail else f': {detail}'}")


def quota(entitlement, percent, unlimited=False, **extra):
    return {
        "entitlement": entitlement, "overage_count": 0, "overage_permitted": False, "percent_remaining": percent,
        "quota_id": "x", "quota_remaining": float(max(entitlement, 0)) * percent / 100,
        "remaining": int(max(entitlement, 0) * percent / 100), "unlimited": unlimited, "timestamp_utc": STAMP, **extra,
    }


def plan(plan, sku, snapshots, **extra):
    return {
        "login": LOGIN, "copilot_plan": plan, "access_type_sku": sku, "quota_reset_date": RESET[:10],
        "quota_reset_date_utc": RESET, "chat_enabled": True, "cli_enabled": True, "quota_snapshots": snapshots, **extra,
    }


UNLIMITED = quota(0, 100.0, unlimited=True)

# The shapes behind each: the real account this was written on (ended), CodexBar issues from live
# accounts (#690, #2593, #1258, and -15% from its own tests), the SDK's types and VS Code's parser.
SCENARIOS = {
    "pro": plan("individual", "monthly_subscriber_quota", {
        "chat": UNLIMITED, "completions": UNLIMITED, "premium_interactions": quota(300, 62.5, overage_permitted=True)}),
    "pro-plus-live-numbers": plan("individual_pro", "monthly_subscriber_quota", {
        "chat": UNLIMITED, "completions": UNLIMITED, "premium_interactions": quota(1500, 75.9)}),
    "overage": plan("individual", "yearly_subscriber_quota", {
        "chat": UNLIMITED, "completions": UNLIMITED,
        "premium_interactions": quota(500, -15, overage_count=75, overage_permitted=True)}),
    "exhausted": plan("individual", "monthly_subscriber_quota", {"premium_interactions": quota(300, 0)}),
    "free-snapshots": plan("individual", "free_limited_copilot", {
        "chat": quota(50, 80), "completions": quota(2000, 25), "premium_interactions": quota(0, 0)}),
    "token-billed-allowance": plan("individual", "monthly_subscriber_quota", {
        "premium_interactions": quota(1000, 60, has_quota=False, token_based_billing=True)}, token_based_billing=True),
    "business-credits": plan("business", "copilot_for_business_seat_quota", {
        "chat": quota(0, 100.0, unlimited=True, credits_used=0),
        "completions": quota(0, 100.0, unlimited=True, credits_used=0),
        "premium_interactions": quota(0, 100.0, unlimited=True, credits_used=31, token_based_billing=True),
    }, token_based_billing=True),
    "business-blank": plan("business", "copilot_for_business_seat_quota", {
        "chat": quota(0, 100), "completions": quota(0, 100), "premium_interactions": quota(0, 100)}, token_based_billing=True),
    "ended": {"login": LOGIN, "access_type_sku": "subscription_ended", "copilot_plan": "individual",
              "chat_enabled": False, "cli_enabled": False, "can_signup_for_limited": True},
    "no-plan": {"login": LOGIN, "copilot_plan": "individual", "can_signup_for_limited": True},
}
# Not asked of the real client, which reads snapshots only: this older Free shape is from VS Code's parser.
NOT_FOR_THE_CLI = {"legacy-free": {"login": LOGIN, "copilot_plan": "individual", "access_type_sku": "free_limited_copilot",
               "limited_user_reset_date": RESET[:10], "monthly_quotas": {"chat": 500, "completions": 4000},
               "limited_user_quotas": {"chat": 125, "completions": 3000}}}
REPORTS = SCENARIOS | NOT_FOR_THE_CLI
ENDED = "This GitHub account's Copilot subscription has ended"
NOTHING_REPORTED = {"ended": ENDED, "no-plan": "This GitHub account has no Copilot plan"}

TITLES = {"premium_interactions": ("Premium", "AI Credits"), "chat": ("Chat",), "completions": ("Completions",)}


class Mock(BaseHTTPRequestHandler):
    """Copilot's usage endpoint. A real token never reaches it."""
    scenario = "pro"
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
        auth = self.headers.get("Authorization", "")
        Mock.requests.append({"path": self.path, "auth": auth, "agent": self.headers.get("User-Agent", "")})
        if not re.fullmatch(r"(Bearer|token) gh[a-z]_\w+", auth):
            return self.answer(401, {"message": "Bad credentials", "status": "401"})
        if self.path == "/user":
            return self.answer(200, {"login": LOGIN, "id": 1, "type": "User"})
        if self.path == "/copilot_internal/user":
            return self.answer(200, REPORTS[Mock.scenario])
        return self.answer(404, {"message": "Not Found"})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.answer(404, {"message": "Not Found"})


class Copilot:
    """The real CLI as the SDK runs it: a headless JSON-RPC server on stdio, in a sandbox."""

    def __init__(self, binary, home, ca=None, host=None):
        os.makedirs(home, exist_ok=True)
        env = {"HOME": str(home), "PWD": str(home), "PATH": "/usr/bin:/bin", "COPILOT_AUTO_UPDATE": "false", "NO_COLOR": "1"}
        if ca:
            env |= {"SSL_CERT_FILE": str(ca), "NODE_EXTRA_CA_CERTS": str(ca)}
        if host:
            env["COPILOT_GH_HOST"] = host
        self.process = subprocess.Popen(
            [str(binary), "--headless", "--no-auto-update", "--stdio"], cwd=home, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.next_id = 0
        self.buffer = b""

    def call(self, method, params, timeout=30):
        self.next_id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}).encode()
        self.process.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.process.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            while b"\r\n\r\n" in self.buffer:
                header, rest = self.buffer.split(b"\r\n\r\n", 1)
                size = int(re.search(rb"Content-Length: (\d+)", header).group(1))
                if len(rest) < size:
                    break
                message = json.loads(rest[:size])
                self.buffer = rest[size:]
                if message.get("id") == self.next_id:
                    return message
            if select.select([self.process.stdout], [], [], 1)[0]:
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    break
                self.buffer += chunk
        raise SystemExit(f"Copilot didn't answer {method}")

    def close(self):
        self.process.kill()
        self.process.wait()


def tinybar(cli_home, editor, gh_config, *flags, home=None):
    """Tinybar's reading, as (error, plan, {title: left}, credits). COPILOT_HOME and friends sandbox it."""
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "COPILOT_HOME": str(cli_home),
           "XDG_CONFIG_HOME": str(editor), "GH_CONFIG_DIR": str(gh_config)}
    if home:
        env["CFFIXED_USER_HOME"] = str(home)
    out = subprocess.run([BIN / "tinybar-cli", "limits", "--provider=copilot", *flags],
                         capture_output=True, text=True, timeout=60, env=env).stdout
    error = re.search(r"Copilot error: (.*)", out)
    head = re.search(r"Copilot (.*?) ?\[source", out)
    windows = {m[0].strip(): float(m[1]) for m in re.findall(r"^  (.+?)\s+(-?[\d.]+)% left", out, re.M)}
    credits = re.search(r"AI credits used: ([\d.]+)", out)
    return (error[1] if error else None, head[1] if head else None, windows, float(credits[1]) if credits else None)


def fingerprint(paths):
    found = {}
    for path in paths:
        files = [path] if path.is_file() else (sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [])
        for file in files:
            if "logs" not in file.parts:
                found[str(file)] = hashlib.sha256(file.read_bytes()).hexdigest()
    return found


def keychain_items():
    """Names only: who holds a `copilot-cli` item. Never asks for a secret, so never prompts."""
    dump = subprocess.run(["security", "dump-keychain"], capture_output=True, text=True).stdout
    return dump.count('"svce"<blob>="copilot-cli"')


def make_ca(root):
    """A CA for this run alone, trusted only by the sandboxed CLI through its environment."""
    ca, key, leaf, leaf_key, csr, ext = (root / n for n in ("ca.pem", "ca.key", "leaf.pem", "leaf.key", "leaf.csr", "ext"))
    def openssl(*args):
        subprocess.run(["openssl", *map(str, args)], check=True, capture_output=True)
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", ca, "-days", 1,
            "-subj", "/CN=Tinybar verify CA", "-addext", "basicConstraints=critical,CA:TRUE")
    openssl("req", "-newkey", "rsa:2048", "-nodes", "-keyout", leaf_key, "-out", csr, "-subj", "/CN=127.0.0.1")
    ext.write_text("subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n")
    openssl("x509", "-req", "-in", csr, "-CA", ca, "-CAkey", key, "-CAcreateserial", "-out", leaf, "-days", 1, "-extfile", ext)
    return ca, leaf, leaf_key


def install_gh(root):
    arch = "arm64" if platform.machine() == "arm64" else "amd64"
    folder = f"gh_{GH}_macOS_{arch}"
    archive = root / f"{folder}.zip"
    urllib.request.urlretrieve(f"https://github.com/cli/cli/releases/download/v{GH}/{folder}.zip", archive)
    subprocess.run(["unzip", "-qo", archive, "-d", root / "gh-release"], check=True)
    return root / "gh-release" / folder / "bin/gh"


def gh_token(gh):
    """Without renewing it, where this `gh` could. Goes to GitHub alone."""
    help_text = subprocess.run([gh, "auth", "token", "--help"], capture_output=True, text=True)
    if help_text.returncode != 0:
        return ""
    renews = "--no-refresh" in help_text.stdout
    arguments = ["auth", "token", "--hostname", "github.com", *(["--no-refresh"] if renews else [])]
    return subprocess.run([gh, *arguments], capture_output=True, text=True).stdout.strip()


class NoRedirects(urllib.request.HTTPRedirectHandler):
    """urllib keeps Authorization when it follows a redirect, wherever that goes."""

    def redirect_request(self, *_):
        return None


def github(path, token):
    request = urllib.request.Request(f"https://api.github.com/{path}", headers={
        "Authorization": f"Bearer {token}", "User-Agent": "Tinybar", "Accept": "application/json"})
    return json.load(urllib.request.build_opener(NoRedirects).open(request, timeout=20))


def install(root):
    prefix = root / "npm"
    subprocess.run(["npm", "install", "--silent", "--no-audit", "--no-fund", "--ignore-scripts", "--prefix", str(prefix),
                    f"@github/copilot@{COPILOT}"], check=True, timeout=300)
    binaries = list((prefix / "node_modules/@github").glob("copilot-darwin-*/copilot"))
    if not binaries:
        raise SystemExit("No Copilot binary for this Mac in the package.")
    return binaries[0]


def live(root, binary):
    print("\nThe live services")
    request = urllib.request.Request("https://api.github.com/copilot_internal/user", headers={
        "Authorization": "Bearer gho_notarealtoken", "User-Agent": "Tinybar", "Accept": "application/json"})
    try:
        urllib.request.urlopen(request, timeout=20)
        check(False, "an invalid token is refused")
    except urllib.error.HTTPError as error:
        body = json.loads(error.read() or b"{}")
        check(error.code == 401, "an invalid token gets 401", f"{error.code} {body}")
    summary = json.load(urllib.request.urlopen(urllib.request.Request(
        "https://www.githubstatus.com/api/v2/summary.json", headers={"User-Agent": "Tinybar"}), timeout=20))
    names = [c["name"] for c in summary["components"]]
    check("Copilot" in names, "the status page still lists Copilot", str(names))

    gh = shutil.which("gh")
    token = gh_token(gh) if gh else ""
    if not token:
        print("  (no gh login: skipping the real account)")
        return
    print("\nYour real account, read-only")
    report = github("copilot_internal/user", token)
    client = Copilot(binary, root / "real-account")
    answer = client.call("account.getQuota", {"gitHubToken": token})
    client.close()
    theirs = answer.get("result", {}).get("quotaSnapshots")
    check(theirs is not None, "the real CLI reads this account", str(answer.get("error", ""))[:200].replace(token, "<token>"))
    home = root / "real-home"
    (home / "cli").mkdir(parents=True)
    # Only names and the host: Tinybar asks the real `gh`, and its real config, for the token.
    login = github("user", token)["login"]
    (home / "cli/config.json").write_text(json.dumps({"last_logged_in_user": {"host": "https://github.com", "login": login}}))
    error, _, windows, _ = tinybar(home / "cli", home / "editor", Path.home() / ".config/gh")
    finite = {k for k, v in (theirs or {}).items() if not v.get("isUnlimitedEntitlement")}
    print(f"       sku {report.get('access_type_sku')}, {len(theirs or {})} quotas from the CLI, Tinybar says: {error or windows}")
    if report.get("access_type_sku") == "subscription_ended":
        check(error == ENDED, "Tinybar says the subscription has ended", str(error))
        check(not theirs, "and the real CLI reports no quotas either", str(theirs))
    else:
        check(len(windows) == len(finite), "Tinybar shows each quota the real CLI has a limit for", f"{windows} vs {finite}")


def differential(root, binary, ca, https, http, empty):
    print(f"\nLimits: Copilot {COPILOT}'s own client and Tinybar read the same responses")
    client = Copilot(binary, root / "differential", ca=ca, host=https.removeprefix("https://"))
    cli_home = root / "tinybar-cli-home"
    cli_home.mkdir()
    (cli_home / "config.json").write_text(json.dumps({
        "last_logged_in_user": {"host": http, "login": LOGIN}, "copilot_tokens": {f"{http}:{LOGIN}": TOKEN}}))
    def read(scenario):
        Mock.scenario = scenario
        return tinybar(cli_home, empty, empty)
    plans = {"pro": "Pro", "pro-plus-live-numbers": "Pro+", "free-snapshots": "Free", "business-credits": "Business", "business-blank": "Business"}
    for scenario, body in SCENARIOS.items():
        Mock.scenario = scenario
        # The real client remembers a token's report, so each scenario has its own.
        answer = client.call("account.getQuota", {"gitHubToken": "gho_" + re.sub(r"\W", "_", scenario) + "_mock0123456789"})
        theirs = answer.get("result", {}).get("quotaSnapshots")
        if theirs is None:
            check(False, f"{scenario}: the real CLI accepts the response", str(answer.get("error"))[:200])
            continue
        error, name, windows, credits = read(scenario)
        expected = {}
        for key, quota_ in theirs.items():
            # The real client reports what's there. A zero entitlement that isn't unlimited has no
            # share to speak of, which VS Code skips too. An overdrawn share is 0% left.
            if quota_.get("isUnlimitedEntitlement") or quota_.get("entitlementRequests") == 0:
                continue
            titles = TITLES[key]
            title = titles[1] if body.get("token_based_billing") and len(titles) > 1 else titles[0]
            expected[title] = max(min(quota_["remainingPercentage"], 100), 0)
        same = windows.keys() == expected.keys() and all(abs(windows[t] - expected[t]) < 0.051 for t in expected)
        if scenario in NOTHING_REPORTED:
            check(error == NOTHING_REPORTED[scenario] and not theirs, f"{scenario}: both report nothing, Tinybar says why", str(error))
        else:
            check(error is None and same, f"{scenario}: {expected or 'no limits'}", f"Tinybar {error or windows}, real CLI {theirs}")
        if scenario in plans:
            check(name == plans[scenario], f"{scenario}: plan is {plans[scenario]}", str(name))
        if scenario == "business-credits":
            check(credits == 31, "business-credits: 31 AI credits used", str(credits))
    client.close()
    # A CA the sandboxed CLI was told to trust means the requests really did reach the mock.
    agents = {r["agent"].split("/")[0] for r in Mock.requests if r["path"] == "/copilot_internal/user"}
    check(agents == {"copilot", "Tinybar"}, "both clients really asked the mock", str(agents))
    client_auth = {r["auth"].split()[0] for r in Mock.requests if r["agent"].startswith("copilot") and r["path"] == "/copilot_internal/user"}
    tinybar_auth = {r["auth"].split()[0] for r in Mock.requests if r["agent"] == "Tinybar"}
    check(client_auth == tinybar_auth == {"Bearer"}, "and sent the same kind of Authorization", f"{client_auth} {tinybar_auth}")

    error, name, windows, _ = read("legacy-free")
    check(error is None and windows == {"Chat": 25.0, "Completions": 75.0} and name == "Free", "legacy-free (VS Code's parser, not the CLI's)", f"{error} {name} {windows}")


def real_gh(root, gh, name, cli_home, http, empty):
    version = subprocess.run([gh, "--version"], capture_output=True, text=True).stdout.split("\n")[0]
    print(f"       the real gh: {version} ({name})")
    sandbox = root / f"gh-{name}"
    config_dir = sandbox / "config"
    config_dir.mkdir(parents=True)
    host = http.removeprefix("http://")
    # gh keeps tokens here with insecure storage. The active user is deliberately someone else, and
    # the user is spelled differently: GitHub ignores the case but gh's lookup doesn't.
    spelled = LOGIN.upper()
    (config_dir / "hosts.yml").write_text(
        f"{host}:\n    git_protocol: https\n    users:\n"
        f"        {spelled}:\n            oauth_token: {TOKEN}\n        someone-else:\n            oauth_token: {OTHER_TOKEN}\n"
        f"    user: someone-else\n    oauth_token: {OTHER_TOKEN}\n")
    os.chmod(config_dir / "hosts.yml", 0o600)
    env = {"PATH": "/usr/bin:/bin", "HOME": str(sandbox), "GH_CONFIG_DIR": str(config_dir)}
    direct = subprocess.run([gh, "auth", "token", "--hostname", host, "--user", spelled], capture_output=True, text=True, env=env).stdout.strip()
    check(direct == TOKEN, "hands out the user's token")
    can_renew = "--no-refresh" in subprocess.run([gh, "auth", "token", "--help"], capture_output=True, text=True, env=env).stdout
    # Tinybar looks in ~/.local/bin first. This records what it runs, then runs the real one.
    wrapper = sandbox / ".local/bin/gh"
    wrapper.parent.mkdir(parents=True)
    log = sandbox / "arguments"
    wrapper.write_text(f'#!/bin/sh\necho "$*" >> "{log}"\nexec "{gh}" "$@"\n')
    wrapper.chmod(0o755)
    Mock.scenario = "pro"
    Mock.requests.clear()
    error, _, windows, _ = tinybar(cli_home, empty, config_dir, home=sandbox)
    sent = [r["auth"] for r in Mock.requests]
    check(error is None and windows == {"Premium": 62.5}, "Tinybar reads limits with the real CLI's file and this gh", f"{error} {windows}")
    check(sent == [f"Bearer {TOKEN}"], "and sends the CLI user's token, not gh's active user's", f"{len(sent)} requests")
    asked = [line for line in log.read_text().splitlines() if "--help" not in line]
    check(len(asked) == 1 and f"--user {spelled}" in asked[0], "asking for it as gh spells the user", str(asked))
    check(("--no-refresh" in asked[0]) == can_renew, f"{'and forbidding a renewal' if can_renew else 'with no renewal to forbid'}", str(asked))


def logins(root, binary, ca, https, http, empty):
    print("\nLogins: what the real tools store is what Tinybar sends")
    home = root / "login-home"
    home.mkdir()
    client = Copilot(binary, home, ca=ca, host=https.removeprefix("https://"))
    answer = client.call("account.login", {"host": https, "login": LOGIN, "token": TOKEN})
    client.close()
    check("error" not in answer, "the real CLI logs in", str(answer.get("error"))[:200])
    raw = (home / ".copilot/config.json").read_text()
    check(raw.startswith("//"), "its config.json still starts with comments")
    config = json.loads(re.sub(r"(?m)^//.*$", "", raw))
    user = config.get("lastLoggedInUser") or config.get("last_logged_in_user") or {}
    check(user.get("login") == LOGIN and user.get("host") == https, "and names the user", str(sorted(config)))

    # Without its token, which this sandbox has no Keychain for, the real file names a user only.
    # Tinybar stays signed out rather than guess. Only the host changes: it can't trust this run's CA.
    (home / ".copilot/config.json").write_text(raw.replace(https, http))
    Mock.requests.clear()
    error, _, _, _ = tinybar(home / ".copilot", empty, empty)
    check(error == "Not signed in" and not Mock.requests, "with no token to hand, nothing is sent", f"{error} {len(Mock.requests)}")

    real_gh(root, install_gh(root), "newest", home / ".copilot", http, empty)
    if shutil.which("gh"):
        real_gh(root, Path(shutil.which("gh")).resolve(), "installed", home / ".copilot", http, empty)

    print("       refusals")
    strange = root / "strange"
    strange.mkdir()
    (strange / "config.json").write_text(json.dumps({
        "last_logged_in_user": {"host": "https://evil.example", "login": LOGIN},
        "copilot_tokens": {f"https://evil.example:{LOGIN}": TOKEN}}))
    Mock.requests.clear()
    error, _, _, _ = tinybar(strange, empty, empty)
    check(error == "This Copilot login is for a server Tinybar won't send it to", "a login for another server isn't sent there", str(error))
    keychain_only = root / "keychain-only"
    keychain_only.mkdir()
    (keychain_only / "config.json").write_text(json.dumps({"last_logged_in_user": {"host": "https://github.com", "login": "no-such-user-for-tinybar"}}))
    error, _, _, _ = tinybar(keychain_only, empty, empty)
    check(error == "Not signed in", "without opting in, a CLI user with no readable token stays signed out, with no prompt", str(error))


def main():
    if not (BIN / "tinybar-cli").exists():
        raise SystemExit("Run `swift build` first.")
    real = [Path.home() / ".copilot", Path.home() / ".config/gh", Path.home() / ".config/github-copilot"]
    before = fingerprint(real)
    items = keychain_items()

    root = Path(tempfile.mkdtemp(prefix="verify-copilot-")).resolve()
    ca, leaf, leaf_key = make_ca(root)
    plain = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    secure = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(leaf, leaf_key)
    secure.socket = context.wrap_socket(secure.socket, server_side=True)
    for server in (plain, secure):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    http = f"http://127.0.0.1:{plain.server_address[1]}"
    https = f"https://127.0.0.1:{secure.server_address[1]}"
    try:
        print(f"Installing Copilot {COPILOT} (a temporary folder)")
        binary = install(root)
        live(root, binary)
        empty = root / "empty"
        empty.mkdir()
        differential(root, binary, ca, https, http, empty)
        logins(root, binary, ca, https, http, empty)
    finally:
        subprocess.run(["pkill", "-f", str(root)], check=False)
        time.sleep(1)
        check(not subprocess.run(["pgrep", "-f", str(root)], capture_output=True).stdout, "no Copilot process left behind")
        print("\nYour own Copilot and gh data")
        check(fingerprint(real) == before, "~/.copilot, ~/.config/gh and ~/.config/github-copilot are unchanged")
        check(keychain_items() == items, "the Keychain has the same number of copilot-cli items")
        shutil.rmtree(root, ignore_errors=True)
    print(f"\nAll {passes} checks passed." if failures == 0 else f"\n{failures} of {passes + failures} checks FAILED.")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
