import hashlib
import importlib.util
import json
import tempfile
import threading
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hirestore_server", ROOT / "tools" / "report_server_hirestore.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
AUTH = {
    "X-HiRestore-Token": module.TOKEN,
    "X-HiRestore-Protocol": "1",
}

with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    module.OUT = base / "reports.txt"
    module.UPLOAD_DIR = base / "uploads"
    server = module.Receiver(("127.0.0.1", 0), module.Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    root = f"http://127.0.0.1:{server.server_port}"

    def request(path, data=None, headers=None):
        merged = dict(AUTH)
        merged.update(headers or {})
        req = urllib.request.Request(root + path, data=data, headers=merged)
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    try:
        code, payload = request("/ping")
        assert code == 200 and payload["status"] == "live"

        code, payload = request("/ping", headers={"X-HiRestore-Token": "wrong"})
        assert code == 401 and payload["status"] == "error"

        code, payload = request("/report", data=b"", headers={"X-HiRestore-Protocol": "2"})
        assert code == 400 and "Protocol" in payload["message"]

        code, payload = request("/report", data="HiRestore 自测日志".encode(), headers={"Content-Type": "text/plain"})
        assert code == 200 and payload["bytes"] == len("HiRestore 自测日志".encode())
        assert "HiRestore 自测日志" in module.OUT.read_text(encoding="utf-8")

        content = b"restored-media\x00\xff"
        digest = hashlib.sha256(content).hexdigest()
        headers = {
            "Content-Type": "application/octet-stream",
            "X-HiRestore-Filename": "..%2F..%2Frestore%20test.mov",
            "X-HiRestore-Size": str(len(content)),
            "X-HiRestore-SHA256": digest,
        }
        invalid_headers = dict(headers)
        invalid_headers["X-HiRestore-Size"] = str(len(content) + 1)
        code, payload = request("/upload", data=content, headers=invalid_headers)
        assert code == 400 and "Content-Length" in payload["message"]

        invalid_headers = dict(headers)
        invalid_headers["X-HiRestore-SHA256"] = "invalid"
        code, payload = request("/upload", data=content, headers=invalid_headers)
        assert code == 400 and "SHA256" in payload["message"]

        code, payload = request("/upload", data=content, headers=headers)
        assert code == 200 and payload["bytes"] == len(content)
        saved = module.UPLOAD_DIR / payload["filename"]
        assert saved.read_bytes() == content
        assert saved.parent == module.UPLOAD_DIR

        headers["X-HiRestore-SHA256"] = "0" * 64
        code, payload = request("/upload", data=content, headers=headers)
        assert code == 400 and "checksum" in payload["message"]
        assert len(list(module.UPLOAD_DIR.iterdir())) == 1

        module.MAX_RETAINED_UPLOAD_BYTES = len(content)
        headers["X-HiRestore-SHA256"] = digest
        code, payload = request("/upload", data=content, headers=headers)
        assert code == 507 and "storage limit" in payload["message"]
        assert len(list(module.UPLOAD_DIR.iterdir())) == 1

        code, payload = request("/missing")
        assert code == 404
        print("HIRESTORE-PC-VERDICT PASS")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
