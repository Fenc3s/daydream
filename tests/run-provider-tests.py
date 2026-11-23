#!/usr/bin/env python3
"""Compile the production provider code and validate migration and HTTP payloads."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

ROOT = Path(__file__).resolve().parent.parent
requests = []
errors = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        payload = json.dumps({"data": [{"id": "OpenRouter", "reasoning": {"supported_efforts": ["low", "high"]}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if body["model"].startswith("discovery-"):
            model = body["model"]
            effort = body.get("reasoning_effort")
            accepted = effort is None or effort in ["low", "high"] or (model == "discovery-none" and effort == "none") or model == "discovery-ignored"
            status = 403 if model == "discovery-blocked" else 200 if accepted else 400
            self.send_response(status)
            self.send_header("Content-Type", "text/event-stream" if status == 200 else "application/json")
            self.end_headers()
            if status != 200:
                self.wfile.write(b'{"error":{"message":"Rejected"}}')
            else:
                delta = {"content": "323"}
                if model == "discovery-media":
                    delta["images"] = [{"type": "image_url"}]
                event = {"choices": [{"delta": delta, "finish_reason": "stop"}]}
                self.wfile.write(("data: " + json.dumps(event) + "\n\ndata: [DONE]\n\n").encode())
            return
        provider, mode = body["model"], body["messages"][0]["content"]
        try:
            if mode == "modelDefault":
                assert all(key not in body for key in ["reasoning", "reasoning_effort", "thinking", "provider"]), body
            elif provider == "OpenRouter":
                assert body["reasoning"] == {"effort": mode}, body
                assert body["provider"] == {"require_parameters": True}, body
                assert "reasoning_effort" not in body, body
            else:
                assert body["reasoning_effort"] == mode, body
                assert "reasoning" not in body, body
                if provider == "DeepSeek":
                    assert body["thinking"] == {"type": "enabled"}, body
                else:
                    assert "thinking" not in body, body
            requests.append((provider, mode, bool(body.get("stream"))))
        except AssertionError as error:
            errors.append(str(error))
        streaming = body.get("stream")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream" if streaming else "application/json")
        self.end_headers()
        if streaming:
            self.wfile.write(b'data: {"choices":[{"delta":{"content":"OK"}}]}\n\ndata: [DONE]\n\n')
        else:
            self.wfile.write(b'{"choices":[{"message":{"content":"OK"}}]}')


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Thread(target=server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix="daydream-provider-tests-") as directory:
    folder = Path(directory)
    # Replace only unrelated diagnostics dependencies, never provider or storage behavior.
    (folder / "TestSupport.swift").write_text('''import Foundation
enum ICloudPasswordsAutomationStatus {
    case disabled
    var displayText: String { "Disabled" }
}
''')
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    sources = [
        "daydream/Core/Models.swift",
        "daydream/Core/ResultPopupState.swift",
        "daydream/Services/AppLogger.swift",
        "daydream/Services/KeychainStore.swift",
        "daydream/Services/MemoryStore.swift",
        "daydream/Services/ObsidianNoteService.swift",
        "daydream/Services/ClipboardHistoryStore.swift",
        "daydream/Support/PasteboardSnapshot.swift",
        "daydream/Services/AIClient.swift",
        "daydream/Services/ProviderModelCatalog.swift",
        "daydream/Services/InputSourceSwitchingService.swift",
        "daydream/Services/WindowMoverService.swift",
        "daydream/Services/SettingsStore.swift",
        "tests/ProviderModelTests.swift",
    ]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", *[str(ROOT / source) for source in sources], str(folder / "TestSupport.swift"), "-o", str(folder / "tests")], env=env, check=True)
    env["DAYDREAM_TEST_URL"] = f"http://127.0.0.1:{server.server_port}/v1"
    subprocess.run([str(folder / "tests"), "--requests"], env=env, check=True)
server.shutdown()
assert not errors, "\n".join(errors)
assert len(requests) == 16, requests
print("16 production HTTP payload checks passed (2 providers × 4 efforts × streaming/non-streaming)")
