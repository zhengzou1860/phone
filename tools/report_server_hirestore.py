"""接收 HiRestore 的运行日志和用户主动上传的修复结果。

python tools/report_server_hirestore.py
GET /ping -> 连接测试
POST /report -> tools/phone-reports-hirestore.txt
POST /upload -> tools/hirestore-uploads/（只接收修复结果，不接收原片）
"""
import hashlib
import hmac
import json
import os
import re
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

BASE = Path(__file__).resolve().parent
OUT = BASE / "phone-reports-hirestore.txt"
UPLOAD_DIR = BASE / "hirestore-uploads"
PORT = int(os.environ.get("HIRESTORE_PORT", "8719"))
TOKEN = os.environ.get("HIRESTORE_TOKEN", "hirestore-local").strip() or "hirestore-local"
MAX_REPORT_BYTES = 1024 * 1024
MAX_UPLOAD_BYTES = 2 * 1024 * 1024 * 1024
MAX_RETAINED_UPLOAD_BYTES = int(os.environ.get("HIRESTORE_MAX_UPLOAD_GB", "20")) * 1024 * 1024 * 1024
MAX_CONCURRENT_UPLOADS = 2
WRITE_LOCK = threading.Lock()
STORAGE_LOCK = threading.Lock()
UPLOAD_SLOTS = threading.Semaphore(MAX_CONCURRENT_UPLOADS)
RESERVED_UPLOAD_BYTES = 0


def local_ipv4_addresses():
    try:
        entries = socket.getaddrinfo(socket.gethostname(), PORT, socket.AF_INET, socket.SOCK_STREAM)
    except OSError:
        return []
    addresses = []
    for entry in entries:
        address = entry[4][0]
        if not address.startswith("127.") and address not in addresses:
            addresses.append(address)
    return addresses


class Receiver(ThreadingHTTPServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 60

    def _reply(self, payload, code=200):
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.close_connection = True

    def _authorized(self):
        supplied = self.headers.get("X-HiRestore-Token", "")
        return hmac.compare_digest(supplied.encode("utf-8"), TOKEN.encode("utf-8"))

    def _protocol_valid(self):
        return self.headers.get("X-HiRestore-Protocol") == "1"

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/ping":
            if not self._authorized():
                self._reply({"status": "error", "message": "unauthorized"}, 401)
                return
            self._reply({"status": "live", "app": "HiRestore", "protocol": 1})
            return
        self._reply({"status": "error", "message": "unknown route"}, 404)

    def do_POST(self):
        if not self._authorized():
            self._reply({"status": "error", "message": "unauthorized"}, 401)
            return
        if not self._protocol_valid():
            self._reply({"status": "error", "message": "X-HiRestore-Protocol must be 1"}, 400)
            return
        path = self.path.split("?", 1)[0]
        if path == "/report":
            self._save_report()
        elif path == "/upload":
            self._save_upload()
        else:
            self._reply({"status": "error", "message": "unknown route"}, 404)

    def _content_length(self, limit):
        raw = self.headers.get("Content-Length")
        if not raw:
            self._reply({"status": "error", "message": "Content-Length required"}, 411)
            return None
        try:
            length = int(raw)
        except ValueError:
            self._reply({"status": "error", "message": "invalid Content-Length"}, 400)
            return None
        if length < 0 or length > limit:
            self._reply({"status": "error", "message": "request too large"}, 413)
            return None
        return length

    def _read(self, length):
        chunks = []
        left = length
        while left:
            chunk = self.rfile.read(min(1024 * 1024, left))
            if not chunk:
                raise ConnectionError("client closed before request body was complete")
            chunks.append(chunk)
            left -= len(chunk)
        return b"".join(chunks)

    def _reserve_storage(self, length):
        global RESERVED_UPLOAD_BYTES
        with STORAGE_LOCK:
            # Active .part files are already included in RESERVED_UPLOAD_BYTES.
            used = sum(path.stat().st_size for path in UPLOAD_DIR.iterdir() if path.is_file() and path.suffix != ".part")
            if used + RESERVED_UPLOAD_BYTES + length > MAX_RETAINED_UPLOAD_BYTES:
                return False
            RESERVED_UPLOAD_BYTES += length
            return True

    def _release_storage(self, length):
        global RESERVED_UPLOAD_BYTES
        with STORAGE_LOCK:
            RESERVED_UPLOAD_BYTES -= length

    def _save_report(self):
        length = self._content_length(MAX_REPORT_BYTES)
        if length is None:
            return
        try:
            data = self._read(length)
            stamp = time.strftime("%Y-%m-%d %H:%M:%S")
            with WRITE_LOCK, OUT.open("a", encoding="utf-8") as handle:
                handle.write(f"\n===== {stamp}  {length} bytes  from {self.client_address[0]} =====\n")
                handle.write(data.decode("utf-8", errors="replace"))
                handle.write("\n")
            self._reply({"status": "ok", "bytes": length, "message": f"recv {length}"})
            print(f"HiRestore log: {length} bytes from {self.client_address[0]}", flush=True)
        except (ConnectionError, OSError) as exc:
            self._reply({"status": "error", "message": str(exc)}, 400)

    def _save_upload(self):
        length = self._content_length(MAX_UPLOAD_BYTES)
        if length is None:
            return
        try:
            expected_size = int(self.headers["X-HiRestore-Size"])
        except (KeyError, ValueError):
            self._reply({"status": "error", "message": "valid X-HiRestore-Size required"}, 400)
            return
        if expected_size <= 0 or expected_size != length:
            self._reply({"status": "error", "message": "upload size does not match Content-Length"}, 400)
            return
        expected_hash = (self.headers.get("X-HiRestore-SHA256") or "").lower()
        if not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
            self._reply({"status": "error", "message": "valid X-HiRestore-SHA256 required"}, 400)
            return
        raw_name = unquote(self.headers.get("X-HiRestore-Filename", "restore.bin"))
        name = os.path.basename(raw_name.replace("\\", "/"))
        name = re.sub(r"[^A-Za-z0-9._-]", "_", name)[:180]
        if not name or name in {".", ".."}:
            name = "restore.bin"
        if not UPLOAD_SLOTS.acquire(blocking=False):
            self._reply({"status": "error", "message": "too many concurrent uploads"}, 503)
            return
        partial = None
        reserved = False
        try:
            UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
            if not self._reserve_storage(length):
                self._reply({"status": "error", "message": "upload storage limit reached"}, 507)
                return
            reserved = True
            final_name = f"{time.strftime('%Y%m%d_%H%M%S')}_{time.time_ns()}_{name}"
            destination = UPLOAD_DIR / final_name
            partial = destination.with_suffix(destination.suffix + ".part")
            received = 0
            digest = hashlib.sha256()
            with partial.open("xb") as handle:
                left = length
                while left:
                    chunk = self.rfile.read(min(1024 * 1024, left))
                    if not chunk:
                        raise ConnectionError("client closed before upload was complete")
                    handle.write(chunk)
                    digest.update(chunk)
                    received += len(chunk)
                    left -= len(chunk)
            actual_hash = digest.hexdigest()
            if received != expected_size:
                raise ValueError("upload size does not match X-HiRestore-Size")
            if actual_hash != expected_hash:
                raise ValueError("upload checksum does not match X-HiRestore-SHA256")
            os.replace(partial, destination)
            self._reply({"status": "ok", "filename": final_name, "bytes": received, "sha256": actual_hash})
            print(f"HiRestore upload: {final_name} ({received} bytes)", flush=True)
        except (ConnectionError, OSError, ValueError) as exc:
            if partial is not None:
                try:
                    partial.unlink(missing_ok=True)
                except OSError:
                    pass
            self._reply({"status": "error", "message": str(exc)}, 400)
        finally:
            if partial is not None:
                try:
                    partial.unlink(missing_ok=True)
                except OSError:
                    pass
            if reserved:
                self._release_storage(length)
            UPLOAD_SLOTS.release()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    server = Receiver(("0.0.0.0", PORT), Handler)
    print(f"HiRestore listener on 0.0.0.0:{PORT}", flush=True)
    addresses = local_ipv4_addresses()
    if addresses:
        print("Phone endpoint:", flush=True)
        for address in addresses:
            print(f"  http://{address}:{PORT}/report", flush=True)
    else:
        print("Run ipconfig and use the active Wi-Fi IPv4 address with port 8719.", flush=True)
    print("If Windows Firewall asks, allow Python on private networks.", flush=True)
    print(f"logs -> {OUT}", flush=True)
    print(f"uploads -> {UPLOAD_DIR}", flush=True)
    server.serve_forever()
