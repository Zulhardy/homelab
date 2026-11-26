"""Talks to OpenBao's root-only admin socket (/run/openbao/admin.sock). Used only by scripts/bootstrap-automation.sh.

Keys are read as JSON from stdin, never from arguments (arguments are visible to other processes).

usage: sudo python3 -I bao-admin-socket.py SOCKET migrate        stdin: {"keys": ["key1", "key2"]}
       sudo python3 -I bao-admin-socket.py SOCKET generate-root  stdin: {"keys": ["key1", "key2"]}

migrate        switch from Shamir unseal keys to the static auto-unseal key (no-op if already done)
generate-root  create a new root token from 2 recovery keys and print it (the caller must revoke it)
"""
import base64, http.client, json, socket, sys
class U(http.client.HTTPConnection):
    def __init__(s, p): super().__init__("localhost"); s.p = p
    def connect(s): x = socket.socket(socket.AF_UNIX); x.connect(s.p); s.sock = x
def call(sock, m, p, b=None):
    c = U(sock); c.request(m, "/v1/" + p, body=None if b is None else json.dumps(b), headers={"Content-Type": "application/json"})
    r = c.getresponse(); d = r.read()
    if r.status >= 300: sys.exit(f"{m} {p}: HTTP {r.status}: {d[:300].decode(errors='replace')}")
    return json.loads(d) if d else {}
sock, action = sys.argv[1], sys.argv[2]
keys = json.load(sys.stdin)["keys"]
if action == "migrate":
    st = call(sock, "GET", "sys/seal-status")
    if not st.get("migration"):
        sys.exit(0 if not st["sealed"] else "OpenBao is sealed but no migration is pending")
    for k in keys:
        st = call(sock, "PUT", "sys/unseal", {"key": k, "migrate": True})
    if st["sealed"]: sys.exit("migration did not complete (wrong keys?)")
    print("migrated", file=sys.stderr)
elif action == "generate-root":
    call(sock, "DELETE", "sys/generate-root/attempt")
    a = call(sock, "PUT", "sys/generate-root/attempt", {})
    for k in keys:
        u = call(sock, "PUT", "sys/generate-root/update", {"key": k, "nonce": a["nonce"]})
    if not u.get("complete"): sys.exit("root token generation did not complete (wrong keys?)")
    e = u["encoded_token"]; raw = base64.b64decode(e + "=" * (-len(e) % 4))
    print(bytes(x ^ y for x, y in zip(raw, a["otp"].encode())).decode())
else:
    sys.exit("unknown action")
