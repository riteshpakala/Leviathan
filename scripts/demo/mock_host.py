"""A stand-in host for demos and screenshots: OpenRouter's sign-in, key status and model list,
and OpenAI-compatible chat completions whose answers vary with temperature.

    python3 scripts/demo/mock_host.py <port> [<request log>]

Nothing here reaches the network, and every answer is made up. Its key is MOCK_KEY below.
"""
import hashlib
import json
import random
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MOCK_KEY = "sk-or-v1-demo-0000"
MODELS = [
    {"id": "qwen/qwen3-32b", "name": "Qwen: Qwen3 32B", "context_length": 40960, "hugging_face_id": "Qwen/Qwen3-32B",
     "pricing": {"prompt": "0.0000001", "completion": "0.0000003"},
     "supported_parameters": ["max_tokens", "temperature", "top_p", "logprobs", "top_logprobs"]},
    {"id": "mistralai/mistral-small-3.2", "name": "Mistral: Mistral Small 3.2", "context_length": 131072,
     "hugging_face_id": "mistralai/Mistral-Small-3.2-24B-Instruct-2506",
     "pricing": {"prompt": "0.00000005", "completion": "0.0000001"}, "supported_parameters": ["max_tokens", "temperature", "top_p"]},
    {"id": "deepseek/deepseek-chat-v3", "name": "DeepSeek: DeepSeek V3", "context_length": 163840, "hugging_face_id": "deepseek-ai/DeepSeek-V3",
     "pricing": {"prompt": "0.0000003", "completion": "0.00000088"}, "supported_parameters": ["max_tokens", "temperature"]},
    {"id": "meta-llama/llama-3.3-70b-instruct", "name": "Meta: Llama 3.3 70B Instruct", "context_length": 131072,
     "hugging_face_id": "meta-llama/Llama-3.3-70B-Instruct", "pricing": {"prompt": "0.00000013", "completion": "0.0000004"},
     "supported_parameters": ["max_tokens", "temperature", "top_p", "logprobs"]},
    {"id": "anthropic/claude-fable-5.1", "name": "Anthropic: Claude Fable 5.1", "context_length": 1000000, "hugging_face_id": "",
     "pricing": {"prompt": "0.00001", "completion": "0.00005"}, "supported_parameters": ["max_tokens"]},
]

# Words a "model" may swap when it edits, more often as the temperature rises.
SWAPS = {
    "quiet": ["still", "hushed", "silent"], "narrow": ["thin", "slender", "tight"], "old": ["ancient", "worn", "aged"],
    "bright": ["pale", "clear", "sharp"], "slowly": ["gently", "softly", "carefully"], "river": ["stream", "current", "water"],
    "patient": ["steady", "quiet"], "careful": ["slow", "measured"],
}
GENERIC = [
    "The quiet town sits on a narrow bend of the old river. In the morning the bright light moves slowly over the roofs, and the ferry "
    "keeper counts the boats before the market opens. Visitors remember the bells of the old chapel.",
    "Mira sets the lamp on the sill and watches the river. The old boats rock slowly at their moorings, and the bright water carries "
    "the last of the light out past the narrow harbour wall.",
]
# One passage this host has "seen", so a recall study has something to find.
KNOWN = {"The quiet harbour keeps its lamps lit long after the boats come in.":
         "Mira walks the narrow pier each evening, counting the old ropes, and the bright water moves slowly under the boards. "
         "Tonight a bell answers her from the river mouth, though no bell hangs there."}


def answer(messages, temperature, model, counter):
    last = messages[-1]["content"] if messages else ""
    if "REFUSE" in last:
        return "", "content_filter"
    rng = random.Random(int(hashlib.sha256(f"{last}|{model}|{temperature}|{counter}".encode()).hexdigest()[:8], 16))
    if "PASSAGE:" in last:
        base = last.split("PASSAGE:", 1)[1].strip()
    elif "BEGINNING:" in last:
        start = last.split("BEGINNING:", 1)[1].strip()
        base = next((rest for known, rest in KNOWN.items() if start.startswith(known)), GENERIC[0])
    else:
        base = GENERIC[int(hashlib.sha256(last.encode()).hexdigest(), 16) % len(GENERIC)]
    heat = 0.8 if temperature is None else float(temperature)
    out = []
    for word in base.split(" "):
        bare = word.strip(".,;:!?\"").lower()
        if bare in SWAPS and rng.random() < heat * 0.5:
            choice = rng.choice(SWAPS[bare])
            out.append(word.replace(bare, choice) if word[:1].islower() else word.replace(bare.capitalize(), choice.capitalize()))
        else:
            out.append(word)
    return " ".join(out), "stop"


class Handler(BaseHTTPRequestHandler):
    counter = 0

    def log_message(self, *args):
        pass

    def send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        return self.headers.get("Authorization") == f"Bearer {MOCK_KEY}"

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/auth":
            query = dict(urllib.parse.parse_qsl(url.query))
            target = query["callback_url"] + "?" + urllib.parse.urlencode({"code": "democode", "state": query.get("state", "")})
            self.send_response(302)
            self.send_header("Location", target)
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif url.path.endswith("/models"):
            self.send(200, {"data": MODELS})
        elif url.path.endswith("/key"):
            if not self.authorized():
                return self.send(401, {"error": {"message": "No auth credentials found", "code": 401}})
            self.send(200, {"data": {"label": "Leviathan demo", "limit": 10, "limit_remaining": 9.37, "usage": 0.63, "is_free_tier": False}})
        else:
            self.send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        path = urllib.parse.urlparse(self.path).path
        if path.endswith("/auth/keys"):
            if body.get("code") != "democode" or len(body.get("code_verifier", "")) != 43:
                return self.send(400, {"error": {"message": "Invalid code or verifier"}})
            return self.send(200, {"key": MOCK_KEY})
        if not path.endswith("/chat/completions"):
            return self.send(404, {"error": {"message": "not found"}})
        if not self.authorized():
            return self.send(401, {"error": {"message": "No auth credentials found", "code": 401}})
        model = body.get("model", "")
        if "claude-fable" in model and "temperature" in body:
            return self.send(400, {"error": {"message": "temperature is not supported with this model"}})
        Handler.counter += 1
        text, finish = answer(body.get("messages", []), body.get("temperature"), model, Handler.counter)
        if len(sys.argv) > 2:
            with open(sys.argv[2], "a") as log:
                log.write(json.dumps({"model": model, "provider": body.get("provider"), "temperature": body.get("temperature")}) + "\n")
        prompt_tokens = sum(len(m["content"].split()) for m in body.get("messages", []))
        self.send(200, {
            "id": "gen-demo", "model": model, "object": "chat.completion",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": finish}],
            "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": len(text.split()), "total_tokens": prompt_tokens + len(text.split())},
        })


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
