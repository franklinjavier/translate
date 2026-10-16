"""Loopback-only fake model endpoints for the opt-in installed-CLI contract tests."""
import http.server
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"models":[],"data":[]}')

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.headers.get("Content-Encoding") == "gzip":
            import gzip
            body = gzip.decompress(body)
        if not (self.path.endswith("/responses") or "/messages" in self.path):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{}")
            return
        (directory / "request.json").write_bytes(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if self.path.endswith("/responses"):
            message = {"id": "msg_contract", "type": "message", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": "Hi."}]}
            response = {"id": "resp_contract", "object": "response", "created_at": 1, "status": "completed", "model": "gpt-6-sol", "output": [message], "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
            events = [
                {"type": "response.created", "response": dict(response, status="in_progress", output=[])},
                {"type": "response.output_item.added", "output_index": 0, "item": dict(message, status="in_progress", content=[])},
                {"type": "response.output_text.delta", "item_id": "msg_contract", "output_index": 0, "content_index": 0, "delta": "Hi."},
                {"type": "response.output_item.done", "output_index": 0, "item": message},
                {"type": "response.completed", "response": response},
            ]
        else:
            events = [
                {"type": "message_start", "message": {"id": "msg_contract", "type": "message", "role": "assistant", "model": "claude-haiku-5-5", "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 0}}},
                {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hi."}},
                {"type": "content_block_stop", "index": 0},
                {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}},
                {"type": "message_stop"},
            ]
        for event in events:
            self.wfile.write(("event: " + event["type"] + "\ndata: " + json.dumps(event) + "\n\n").encode())
        self.wfile.flush()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(directory / "port.txt").write_text(str(server.server_port))
server.serve_forever()
