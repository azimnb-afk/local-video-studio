#!/usr/bin/env python3
"""Samples real Director plans and shows what capability-aware planning does.

The plans come from the same local Ollama Director the app uses, with the app's
own system prompt. The capability policy is NOT reimplemented here: each plan is
handed to the shipping Swift implementation via

    swift run LTXTests --capability-plan <plan.json> "<brief>"

so what this prints is what Auto Movie would actually generate from.

Several unrelated briefs are used on purpose — a rule that only helps the
library/door case would show up here as "no change" everywhere else.

Usage: ./scripts/capability_plan_sampling.py [outdir]
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OLLAMA_MODEL = os.environ.get("LTX_DIRECTOR_MODEL", "qwen3.6-claw-fast:latest")
OUTDIR = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ltx_capability_plans"

BRIEFS = [
    "A young woman walks toward an old stone library, reaches the entrance, "
    "unlocks the door, and steps inside.",
    "A woman walks through a forest and discovers a glowing shrine.",
    "A person approaches a parked car, opens the door and gets inside.",
    "An engineer crosses a control room and starts a machine.",
]


def director_system_prompt() -> str:
    """Reads the shipping system prompt out of the Swift source."""
    path = os.path.join(REPO, "LTXVideoGenerator/Sources/Services/StoryboardDirector.swift")
    source = open(path, encoding="utf-8").read()
    match = re.search(r'static let storyboardSystemPrompt = """\n(.*?)\n    """',
                      source, re.S)
    if not match:
        sys.exit("could not read the Director system prompt from the Swift source")
    return "\n".join(line[4:] if line.startswith("    ") else line
                     for line in match.group(1).split("\n"))


def plan(brief: str) -> dict:
    body = json.dumps({
        "model": OLLAMA_MODEL,
        "system": director_system_prompt(),
        "prompt": f"BRIEF: {brief}",
        "stream": False,
        "think": False,
        "format": "json",
        "options": {"num_predict": 4096},
    }).encode()
    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate", data=body,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=600) as response:
        payload = json.load(response)
    return json.loads(payload["response"])


def main() -> int:
    os.makedirs(OUTDIR, exist_ok=True)
    summary_path = os.path.join(OUTDIR, "summary.txt")
    lines: list[str] = []

    def log(text: str = "") -> None:
        print(text)
        lines.append(text)

    log(f"=== Capability-aware plan sampling (model {OLLAMA_MODEL}) ===")
    for index, brief in enumerate(BRIEFS, start=1):
        log("")
        log(f"### brief {index}: {brief}")
        try:
            draft = plan(brief)
        except Exception as error:  # noqa: BLE001 - reported, not raised
            log(f"  Director failed: {error}")
            continue
        path = os.path.join(OUTDIR, f"plan{index}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(draft, handle, ensure_ascii=False, indent=2)
        result = subprocess.run(
            ["swift", "run", "LTXTests", "--capability-plan", path, brief],
            cwd=REPO, capture_output=True, text=True)
        if result.returncode != 0:
            log(f"  capability inspection failed: {result.stderr.strip()[:400]}")
            continue
        for line in result.stdout.strip().split("\n"):
            if not line.startswith("brief: "):
                log("  " + line)

    with open(summary_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    print(f"\nwritten: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
