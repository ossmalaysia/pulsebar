"""Minimal stand-in for EzyChat's MCP endpoint and its OAuth sign-in, for PulseBar's self-tests.

Mirrors EzyChat Lite's rules: discovery (RFC 9728/8414), dynamic client registration (public
clients, redirect URIs that are https or loopback http, matched exactly), PKCE S256 only,
`resource` must be <origin>/mcp, one-time codes, no refresh tokens, and new app tokens WITHOUT
send permission (send_message is hidden from tools/list and "not found" on tools/call).

Usage:
  python3 scripts/mock_ezychat_mcp.py PORT SENT_LOG [--grant-send] [--deny] [--mcp-off]

  --grant-send  OAuth app tokens may send (as if "Can send WhatsApp messages" was turned on)
  --deny        the admin clicks "Deny" on the approval page
  --mcp-off     AI assistant access is off: every MCP/OAuth route answers 404

The static token ezc_pat_testtoken123 (used by --alerttest) always may send.
"""
import base64, hashlib, json, re, secrets, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, urlencode

PORT, LOG = int(sys.argv[1]), sys.argv[2]
FLAGS = set(sys.argv[3:])
BASE = f"http://127.0.0.1:{PORT}"
LOOPBACK = {"localhost", "127.0.0.1", "[::1]"}

clients = {}                                       # client_id -> {"redirect_uris": [...]}
codes = {}                                         # code -> {client_id, redirect_uri, challenge, expires}
tokens = {"ezc_pat_testtoken123": {"send"}}        # token -> scopes


def valid_redirect(u):
    p = urlparse(u)
    if p.fragment or p.username or p.password:
        return False
    if p.scheme == "https":
        return bool(p.hostname)
    if p.scheme == "http":
        return p.hostname in {"localhost", "127.0.0.1", "::1"}
    return p.scheme not in {"javascript", "data", "file", "vbscript", ""}


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj, headers=None):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)

    def redirect(self, url):
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def off(self):
        return "--mcp-off" in FLAGS

    # ---- discovery + authorize -------------------------------------------------------------
    def do_GET(self):
        u = urlparse(self.path)
        if self.off():
            return self.reply(404, {"error": {"code": "not_found"}})
        if u.path in ("/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"):
            return self.reply(200, {"resource": f"{BASE}/mcp", "authorization_servers": [BASE],
                                    "bearer_methods_supported": ["header"], "resource_name": "EzyChat"})
        if u.path == "/.well-known/oauth-authorization-server":
            return self.reply(200, {"issuer": BASE, "authorization_endpoint": f"{BASE}/oauth/authorize",
                                    "token_endpoint": f"{BASE}/mcp/oauth/token",
                                    "registration_endpoint": f"{BASE}/mcp/oauth/register",
                                    "response_types_supported": ["code"], "grant_types_supported": ["authorization_code"],
                                    "code_challenge_methods_supported": ["S256"],
                                    "token_endpoint_auth_methods_supported": ["none", "client_secret_basic", "client_secret_post"]})
        if u.path == "/oauth/authorize":
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            c = clients.get(q.get("client_id", ""))
            if not c:
                return self.reply(400, {"error": "unknown client"})
            ru = q.get("redirect_uri")
            if ru not in c["redirect_uris"]:
                return self.reply(400, {"error": "redirect_uri not registered (exact match required)"})
            if q.get("code_challenge_method") != "S256" or not re.fullmatch(r"[A-Za-z0-9_-]{43}", q.get("code_challenge", "")):
                return self.reply(400, {"error": "The app must use PKCE with S256."})
            if q.get("resource") not in (None, f"{BASE}/mcp"):
                return self.reply(400, {"error": "unknown resource"})
            state = q.get("state", "")
            if "--deny" in FLAGS:
                return self.redirect(f"{ru}?{urlencode({'error': 'access_denied', 'state': state})}")
            code = secrets.token_urlsafe(24)
            codes[code] = {"client_id": q["client_id"], "redirect_uri": ru, "challenge": q["code_challenge"],
                           "expires": time.time() + 300}
            return self.redirect(f"{ru}?{urlencode({'code': code, 'state': state})}")
        return self.reply(404, {"error": "not found"})

    # ---- register, token, mcp ----------------------------------------------------------------
    def do_POST(self):
        u = urlparse(self.path)
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.off():
            return self.reply(404, {"error": {"code": "not_found"}})

        if u.path == "/mcp/oauth/register":
            b = json.loads(raw or b"{}")
            uris = b.get("redirect_uris")
            if not isinstance(uris, list) or not uris or not all(valid_redirect(x) for x in uris):
                return self.reply(400, {"error": "invalid_redirect_uri"})
            if b.get("token_endpoint_auth_method", "client_secret_basic") != "none":
                return self.reply(400, {"error": "invalid_client_metadata", "error_description": "test expects a public client"})
            cid = "ezc_app_" + secrets.token_hex(8)
            clients[cid] = {"redirect_uris": uris, "name": b.get("client_name")}
            return self.reply(201, {"client_id": cid, "client_name": b.get("client_name"), "redirect_uris": uris,
                                    "token_endpoint_auth_method": "none", "grant_types": ["authorization_code"]})

        if u.path == "/mcp/oauth/token":
            f = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
            if f.get("grant_type") != "authorization_code":
                return self.reply(400, {"error": "unsupported_grant_type"})
            p = codes.pop(f.get("code", ""), None)          # one-time use
            if not p or p["expires"] < time.time() or p["client_id"] != f.get("client_id"):
                return self.reply(400, {"error": "invalid_grant"})
            if f.get("redirect_uri") not in (None, p["redirect_uri"]):
                return self.reply(400, {"error": "invalid_grant", "error_description": "redirect_uri does not match"})
            if b64url(hashlib.sha256(f.get("code_verifier", "").encode()).digest()) != p["challenge"]:
                return self.reply(400, {"error": "invalid_grant", "error_description": "PKCE verification failed"})
            if f.get("resource") not in (None, f"{BASE}/mcp"):
                return self.reply(400, {"error": "invalid_target"})
            tok = "ezc_pat_" + secrets.token_urlsafe(24)
            tokens[tok] = {"send"} if "--grant-send" in FLAGS else set()
            return self.reply(200, {"access_token": tok, "token_type": "Bearer"})   # no refresh_token, like EzyChat

        if u.path != "/mcp":
            return self.reply(404, {"error": "not found"})
        auth = self.headers.get("Authorization", "")
        scopes = tokens.get(auth[7:]) if auth.startswith("Bearer ") else None
        if scopes is None:
            return self.reply(401, {"error": "invalid_token"}, {
                "WWW-Authenticate": f'Bearer realm="ezychat", error="invalid_token", resource_metadata="{BASE}/.well-known/oauth-protected-resource/mcp"'})
        acc = self.headers.get("Accept", "")
        if "application/json" not in acc or "text/event-stream" not in acc:
            return self.reply(406, {"error": "bad accept"})
        body = json.loads(raw)
        rid = body.get("id")
        tools = ["get_stats", "list_chats"] + (["send_message"] if "send" in scopes else [])
        if body.get("method") == "tools/list":
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"tools": [{"name": t} for t in tools]}})
        p = body.get("params", {})
        a = p.get("arguments", {})
        if body.get("method") != "tools/call":
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}})
        if p.get("name") not in tools:   # how the MCP SDK answers a tool the token can't see
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"isError": True, "content": [
                {"type": "text", "text": f"MCP error -32602: Tool {p.get('name')} not found"}]}})
        ok = re.fullmatch(r"[A-Za-z0-9_-]{8,64}", a.get("requestId", "")) and a.get("jid") and 1 <= len(a.get("text", "")) <= 4096
        if not ok:
            return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"isError": True, "content": [{"type": "text", "text": "invalid_arguments"}]}})
        with open(LOG, "a") as f:
            f.write(json.dumps({"jid": a["jid"], "requestId": a["requestId"], "text": a["text"]}) + "\n")
        return self.reply(200, {"jsonrpc": "2.0", "id": rid, "result": {"content": [
            {"type": "text", "text": json.dumps({"messageId": "tmp-1", "queued": False})}]}})


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
