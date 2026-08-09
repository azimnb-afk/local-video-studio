#!/usr/bin/env python3
"""End-to-end Auto Movie run that mirrors the app's actual pipeline.

Unlike the earlier shell harness, the shot prompts are NOT hand written: this
calls the same Local AI Director with the same system prompt the app sends,
compiles each shot the way PromptCompiler does, and honours the Director's own
continuity decision — inheriting the previous shot's final frame at the
calibrated strength only where the plan says "continue".

Nothing is downloaded (HF_HUB_OFFLINE=1) and generation stays sequential.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/ltx_progression_e2e")
OUT.mkdir(parents=True, exist_ok=True)

PYTHON = os.environ.get("LTX_PYTHON", str(pathlib.Path.home() / "ltx-venv/bin/python3"))
MODEL_REPO = os.environ.get("LTX_MODEL_REPO", "notapalindrome/ltx23-mlx-av-q4")
ENCODER = os.environ.get("LTX_ENCODER_REPO", "mlx-community/gemma-3-12b-it-4bit")
OLLAMA_MODEL = os.environ.get("LTX_DIRECTOR_MODEL", "qwen3.6-claw-fast:latest")
# AutoMovieRunCoordinator.continuityImageStrength
CONTINUITY_STRENGTH = 0.8
W, H, FRAMES, STEPS, FPS, CFG, SEED = 512, 320, 25, 15, 24, 3.0, 42
BRIEF = ("A young woman walks toward an old stone library, reaches the entrance, "
         "opens the door, and steps inside.")

log_lines = []
def log(msg):
    print(msg, flush=True)
    log_lines.append(msg)
    (OUT / "summary.txt").write_text("\n".join(log_lines))


def director_system_prompt() -> str:
    src = (REPO / "LTXVideoGenerator/Sources/Services/StoryboardDirector.swift").read_text()
    return re.search(r'static let storyboardSystemPrompt = """\n(.*?)\n\s*"""', src, re.S).group(1)


def plan_shots() -> list:
    body = json.dumps({
        "model": OLLAMA_MODEL, "system": director_system_prompt(),
        "prompt": f"BRIEF: {BRIEF}", "stream": False, "think": False,
        "format": "json", "options": {"num_predict": 4096},
    }).encode()
    req = urllib.request.Request("http://127.0.0.1:11434/api/generate", data=body,
                                 headers={"Content-Type": "application/json"})
    raw = json.load(urllib.request.urlopen(req, timeout=900)).get("response", "") or ""
    (OUT / "director_plan.json").write_text(raw)
    plan = json.loads(raw)
    return plan.get("shots", [])[:4]


def compile_prompt(shot: dict) -> str:
    """Mirrors PromptCompiler: camera sentence, then the action."""
    camera = (f"{shot.get('shotScale', 'medium')} shot, "
              f"{shot.get('angle', 'eye-level')} angle, "
              f"{shot.get('movement', 'static')} camera")
    parts = [f"The camera {camera}.", shot.get("summary", "").strip()]
    if shot.get("lighting"):
        parts.append(f"Lighting: {shot['lighting']}.")
    return " ".join(p if p.endswith((".", "!", "?")) else p + "." for p in parts if p)


def extract_last_frame(video: pathlib.Path, out: pathlib.Path) -> bool:
    dur = float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(video)],
        capture_output=True, text=True).stdout.strip())
    tail = min(0.2, max(dur / 4, 0.04))
    for args in ([["-sseof", f"-{tail:.3f}"]], [["-ss", f"{max(0, dur - tail):.3f}"]]):
        out.unlink(missing_ok=True)
        subprocess.run(["ffmpeg", "-y", *args[0], "-i", str(video), "-frames:v", "1",
                        "-q:v", "2", "-update", "1", str(out)],
                       capture_output=True)
        if out.exists() and out.stat().st_size > 0:
            return True
    return False


def generate(label: str, prompt: str, image: pathlib.Path | None) -> pathlib.Path:
    out = OUT / f"{label}.mp4"
    cmd = [PYTHON, "-m", "mlx_video.generate_av", "--prompt", prompt,
           "--height", str(H), "--width", str(W), "--num-frames", str(FRAMES),
           "--seed", str(SEED), "--fps", str(FPS), "--steps", str(STEPS),
           "--cfg-scale", str(CFG), "--output-path", str(out),
           "--model-repo", MODEL_REPO, "--text-encoder-repo", ENCODER,
           "--tiling", "auto", "--no-audio"]
    if image is not None:
        cmd += ["--image", str(image), "--image-strength", str(CONTINUITY_STRENGTH)]
    env = dict(os.environ, HF_HUB_OFFLINE="1")
    import time
    start = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    (OUT / f"{label}.log").write_text(r.stdout + r.stderr)
    if r.returncode != 0:
        raise RuntimeError(f"{label} generation failed; see {label}.log")
    log(f"[{label}] rendered in {int(time.time() - start)}s"
        + (f" (continuing from {image.name} @ {CONTINUITY_STRENGTH})" if image else " (text-to-video)"))
    return out


def main():
    log("=== Auto Movie cinematic progression E2E ===")
    shots = plan_shots()
    log(f"Director planned {len(shots)} shots\n")
    for i, s in enumerate(shots, 1):
        log(f"Shot {i} [{s.get('shotScale','?')} · {s.get('angle','?')} · {s.get('movement','?')}]"
            f" continuity={s.get('continuity','?')}")
        log(f"   {s.get('summary','')}")
    log("")

    previous_video = None
    videos = []
    for i, shot in enumerate(shots):
        label = f"shot{i+1}"
        prompt = compile_prompt(shot)
        (OUT / f"{label}_prompt.txt").write_text(prompt)
        image = None
        # The first shot never inherits; otherwise honour the Director's decision.
        if i > 0 and shot.get("continuity") == "continue" and previous_video is not None:
            frame = OUT / f"{label}_inherited.png"
            if extract_last_frame(previous_video, frame):
                image = frame
            else:
                raise RuntimeError(f"{label}: continuity frame extraction failed")
        video = generate(label, prompt, image)
        videos.append(video)
        previous_video = video

    listing = OUT / "concat.txt"
    listing.write_text("\n".join(f"file '{v}'" for v in videos))
    final = OUT / "auto_movie_final.mp4"
    subprocess.run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(listing),
                    "-c", "copy", str(final)], capture_output=True)
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                            "stream=width,height,codec_name", "-show_entries",
                            "format=duration", "-of", "csv=p=0", str(final)],
                           capture_output=True, text=True).stdout.split()
    log("")
    log(f"[assembly] {len(videos)} shots -> {final.name}: {' '.join(probe)}")
    log("=== done ===")


if __name__ == "__main__":
    main()
