"""Minimal stand-in for the EzyChat MCP endpoint, used by `PulseBar --alerttest`.
Usage: python3 scripts/mock_ezychat_mcp.py 8765 /tmp/sent.jsonl   (token: ezc_pat_testtoken123)"""
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
LOG = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path != "/mcp": return self.reply(404, {"error": "not found"})
        if self.headers.get("Authorization") != "Bearer ezc_pat_testtoken123": return self.reply(401, {"error": "invalid_token"})
        acc = self.headers.get("Accept", "")
        if "application/json" not in acc or "text/event-stream" not in acc: return self.reply(406, {"error": "bad accept"})
        p = body.get("params", {}); a = p.get("arguments", {})
        ok = body.get("method") == "tools/call" and p.get("name") == "send_message" \
             and re.fullmatch(r"[A-Za-z0-9_-]{8,64}", a.get("requestId", "")) and a.get("jid") and 1 <= len(a.get("text", "")) <= 4096
        if not ok: return self.reply(200, {"jsonrpc": "2.0", "id": body.get("id"), "result": {"isError": True, "content": [{"type": "text", "text": "invalid_arguments"}]}})
        with open(LOG, "a") as f: f.write(json.dumps({"jid": a["jid"], "requestId": a["requestId"], "text": a["text"]}) + "\n")
        self.reply(200, {"jsonrpc": "2.0", "id": body["id"], "result": {"content": [{"type": "text", "text": json.dumps({"messageId": "tmp-1", "queued": False})}]}})
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
