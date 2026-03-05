import json
import mimetypes
import os
import re
from pathlib import Path

from mitmproxy import http


class LocalOverrides:
    def __init__(self):
        self.rules = []
        self.rules_path = None
        self.rules_mtime_ns = None
        self._load_rules()

    def _resolve_rules_path(self):
        rules_path = os.environ.get("SILMARIL_MITM_RULES", "")
        if not rules_path:
            default_path = Path(__file__).resolve().parent / "rules.json"
            rules_path = str(default_path)

        return Path(rules_path)

    def _load_rules(self):
        path = self._resolve_rules_path()
        self.rules_path = path
        if not path.exists():
            self.rules = []
            self.rules_mtime_ns = None
            return

        data = json.loads(path.read_text(encoding="utf-8-sig"))
        loaded = []
        for rule in data.get("rules", []):
            match = str(rule.get("match", "")).strip()
            file_path = str(rule.get("file", "")).strip()
            if not match or not file_path:
                continue

            loaded.append(
                {
                    "regex": re.compile(match),
                    "file": Path(file_path),
                    "status": int(rule.get("status", 200)),
                    "content_type": str(rule.get("contentType", "")).strip(),
                }
            )

        self.rules = loaded
        self.rules_mtime_ns = path.stat().st_mtime_ns

    def _reload_rules_if_needed(self):
        path = self._resolve_rules_path()
        if self.rules_path is None or path != self.rules_path:
            self._load_rules()
            return

        if not path.exists():
            if self.rules_mtime_ns is not None:
                self.rules = []
                self.rules_mtime_ns = None
            return

        current_mtime_ns = path.stat().st_mtime_ns
        if self.rules_mtime_ns != current_mtime_ns:
            self._load_rules()

    def response(self, flow: http.HTTPFlow):
        try:
            self._reload_rules_if_needed()
        except Exception:
            # Keep previous in-memory rules if reload fails.
            pass

        url = flow.request.pretty_url
        for rule in self.rules:
            if not rule["regex"].search(url):
                continue

            file_path = rule["file"]
            if not file_path.exists():
                return

            body = file_path.read_bytes()
            content_type = rule["content_type"]
            if not content_type:
                guessed, _ = mimetypes.guess_type(str(file_path))
                content_type = guessed or "application/octet-stream"

            flow.response = http.Response.make(
                rule["status"],
                body,
                {
                    "Content-Type": content_type,
                    "Cache-Control": "no-store",
                },
            )
            return


addons = [LocalOverrides()]


