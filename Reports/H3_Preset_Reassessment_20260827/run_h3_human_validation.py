#!/usr/bin/env python3
import os
import sys
import json
import time
import base64
import urllib.request
import subprocess
from PIL import Image, ImageDraw, ImageFont

ENDPOINT = "http://127.0.0.1:11236/v1/video/generations"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INPUTS_DIR = os.path.join(BASE_DIR, "inputs")
RAW_DIR = os.path.join(BASE_DIR, "raw_results")
FRAMES_DIR = os.path.join(BASE_DIR, "representative_frames")
SHEETS_DIR = os.path.join(BASE_DIR, "contact_sheets")
HUMAN_RESULTS_JSON = os.path.join(BASE_DIR, "human_validation_results.json")
HUMAN_RESULTS_CSV = os.path.join(BASE_DIR, "human_summary_table.csv")

REAL_HUMAN_SRC = "/Users/azimnb/Library/Application Support/LocalVideoStudioDev/Projects/C0FE3A50-0FAF-4DC3-9D95-6A75D11A3885/Assets/OpeningReference/opening-reference-78FDA19E-5055-4627-AD8D-6B6D7A11F114.png"
LOCAL_HUMAN_REF = os.path.join(INPUTS_DIR, "real_human_reference.png")

# Ensure reference image copied
if not os.path.exists(LOCAL_HUMAN_REF) and os.path.exists(REAL_HUMAN_SRC):
    subprocess.run(["cp", REAL_HUMAN_SRC, LOCAL_HUMAN_REF], check=True)

PROMPT_HUMAN_I2V = (
    "A cinematic medium shot of the same woman walking slowly forward in warm natural daylight. "
    "Her hair moves gently in the breeze. She keeps a natural calm expression. "
    "The camera performs a subtle smooth tracking movement. "
    "Preserve her facial features, hairstyle, clothing, body proportions and overall appearance from the starting image."
)

HUMAN_RUNS = [
    {
        "id": "HUMAN_RUN_A",
        "name": "Human_512x288_90f_10st_FastON_s42",
        "category": "human_steps_baseline",
        "prompt": PROMPT_HUMAN_I2V,
        "width": 512,
        "height": 288,
        "num_frames": 90,
        "steps": 10,
        "fast": True,
        "seed": 42,
        "desc": "Current Standard-style low-quality baseline (512x288, 10st, Fast ON, s42)"
    },
    {
        "id": "HUMAN_RUN_B",
        "name": "Human_640x384_90f_12st_FastON_s42",
        "category": "human_steps_baseline",
        "prompt": PROMPT_HUMAN_I2V,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 12,
        "fast": True,
        "seed": 42,
        "desc": "Exact Current High baseline (640x384, 12st, Fast ON, s42)"
    },
    {
        "id": "HUMAN_RUN_C",
        "name": "Human_640x384_90f_16st_FastON_s42",
        "category": "human_steps_baseline",
        "prompt": PROMPT_HUMAN_I2V,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 16,
        "fast": True,
        "seed": 42,
        "desc": "Proposed Standard (640x384, 16st, Fast ON, s42)"
    },
    {
        "id": "HUMAN_RUN_D",
        "name": "Human_640x384_90f_20st_FastON_s42",
        "category": "human_steps_baseline",
        "prompt": PROMPT_HUMAN_I2V,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 20,
        "fast": True,
        "seed": 42,
        "desc": "Proposed High (640x384, 20st, Fast ON, s42)"
    },
    {
        "id": "HUMAN_RUN_E",
        "name": "Human_640x384_90f_16st_FastOFF_s42",
        "category": "human_fast_comparison",
        "prompt": PROMPT_HUMAN_I2V,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 16,
        "fast": False,
        "seed": 42,
        "desc": "Fast ON/OFF Human Quality Verification (640x384, 16st, Fast OFF, s42)"
    },
    {
        "id": "HUMAN_RUN_F",
        "name": "Human_640x384_141f_20st_FastON_s42",
        "category": "human_duration",
        "prompt": PROMPT_HUMAN_I2V,
        "width": 640,
        "height": 384,
        "num_frames": 141,
        "steps": 20,
        "fast": True,
        "seed": 42,
        "desc": "5.88-second Human Late-Frame Stability (640x384, 141f, 20st, Fast ON, s42)"
    },
    {
        "id": "HUMAN_RUN_G",
        "name": "Human_384x640_90f_16st_FastON_s42",
        "category": "human_portrait",
        "prompt": PROMPT_HUMAN_I2V,
        "width": 384,
        "height": 640,
        "num_frames": 90,
        "steps": 16,
        "fast": True,
        "seed": 42,
        "desc": "Portrait Preset Validation (384x640, 90f, 16st, Fast ON, s42)"
    },
    {
        "id": "HUMAN_RUN_H",
        "name": "Human_640x384_90f_16st_FastON_s31415",
        "category": "human_seed_replication",
        "prompt": PROMPT_HUMAN_I2V,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 16,
        "fast": True,
        "seed": 31415,
        "desc": "Second-Seed Replication 16st (640x384, 16st, Fast ON, s31415)"
    },
    {
        "id": "HUMAN_RUN_I",
        "name": "Human_640x384_90f_20st_FastON_s31415",
        "category": "human_seed_replication",
        "prompt": PROMPT_HUMAN_I2V,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 20,
        "fast": True,
        "seed": 31415,
        "desc": "Second-Seed Replication 20st (640x384, 20st, Fast ON, s31415)"
    }
]

def prepare_human_image_b64(image_path, target_w, target_h):
    if not image_path or not os.path.exists(image_path):
        raise ValueError(f"Human reference image missing: {image_path}")
    img = Image.open(image_path).convert("RGB")
    src_w, src_h = img.size
    target_aspect = target_w / target_h
    src_aspect = src_w / src_h

    # Focus crop on face / upper torso
    if src_aspect > target_aspect:
        crop_w = int(src_h * target_aspect)
        left = (src_w - crop_w) // 2
        img = img.crop((left, 0, left + crop_w, src_h))
    else:
        crop_h = int(src_w / target_aspect)
        # Anchor near top/upper-third where the face is
        top = int((src_h - crop_h) * 0.15)
        top = max(0, min(top, src_h - crop_h))
        img = img.crop((0, top, src_w, top + crop_h))

    img = img.resize((target_w, target_h), Image.Resampling.LANCZOS)
    temp_path = os.path.join(INPUTS_DIR, f"human_temp_{target_w}x{target_h}.jpg")
    img.save(temp_path, "JPEG", quality=95)
    with open(temp_path, "rb") as f:
        data = f.read()
    return base64.b64encode(data).decode("utf-8")

def execute_run(run):
    run_id = run["id"]
    name = run["name"]
    print(f"\n========================================================")
    print(f"Executing {run_id}: {name}")
    print(f"Resolution: {run['width']}x{run['height']}, Frames: {run['num_frames']}, Steps: {run['steps']}, Fast: {run['fast']}, Seed: {run['seed']}")
    print(f"========================================================")

    img_b64 = prepare_human_image_b64(LOCAL_HUMAN_REF, run["width"], run["height"])

    payload = {
        "prompt": run["prompt"],
        "width": run["width"],
        "height": run["height"],
        "num_frames": run["num_frames"],
        "steps": run["steps"],
        "seed": run["seed"],
        "fast": run["fast"],
        "chain_windows": 1,
        "first_frame_image": img_b64
    }

    req_data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        ENDPOINT,
        data=req_data,
        headers={"Content-Type": "application/json"}
    )

    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=3600) as response:
            resp_bytes = response.read()
    except Exception as e:
        print(f"Error during API call: {e}")
        return {
            "run_id": run_id,
            "name": name,
            "success": False,
            "error": str(e),
            "elapsed_seconds": round(time.time() - t0, 2)
        }

    elapsed = round(time.time() - t0, 2)
    print(f"Generation completed in {elapsed:.2f}s ({elapsed/60:.2f}m)")

    resp_json = json.loads(resp_bytes.decode("utf-8"))
    raw_rgb_b64 = resp_json.get("data")
    pcm_b64 = resp_json.get("audio_data")
    width = resp_json.get("width", run["width"])
    height = resp_json.get("height", run["height"])
    frames = resp_json.get("frames", run["num_frames"])
    fps = resp_json.get("fps", 24.0)

    rgb_data = base64.b64decode(raw_rgb_b64)
    pcm_data = base64.b64decode(pcm_b64) if pcm_b64 else None

    raw_rgb_path = os.path.join(RAW_DIR, f"{run_id}_{name}_raw.rgb")
    with open(raw_rgb_path, "wb") as f:
        f.write(rgb_data)

    pcm_path = None
    if pcm_data:
        pcm_path = os.path.join(RAW_DIR, f"{run_id}_{name}_audio.pcm")
        with open(pcm_path, "wb") as f:
            f.write(pcm_data)

    out_mp4 = os.path.join(RAW_DIR, f"{run_id}_{name}.mp4")

    cmd = [
        "ffmpeg", "-y",
        "-f", "rawvideo",
        "-pixel_format", "rgb24",
        "-video_size", f"{width}x{height}",
        "-framerate", str(int(fps)),
        "-i", raw_rgb_path
    ]
    if pcm_path and os.path.exists(pcm_path):
        sample_rate = resp_json.get("audio_sample_rate", 32000)
        channels = resp_json.get("audio_channels", 2)
        cmd += [
            "-f", "s16le",
            "-ar", str(sample_rate),
            "-ac", str(channels),
            "-i", pcm_path,
            "-af", "apad",
            "-c:a", "aac",
            "-shortest"
        ]
    else:
        cmd += ["-an"]

    cmd += [
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        out_mp4
    ]

    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    print(f"Muxed video saved: {out_mp4}")

    key_indices = [
        0,
        int(frames * 0.25),
        int(frames * 0.50),
        int(frames * 0.75),
        frames - 1
    ]
    frame_names = ["000pct_f0", "025pct_early", "050pct_mid", "075pct_late", "100pct_final"]
    extracted_frames = []

    for idx, fname in zip(key_indices, frame_names):
        frame_png = os.path.join(FRAMES_DIR, f"{run_id}_{fname}.png")
        extract_cmd = [
            "ffmpeg", "-y",
            "-i", out_mp4,
            "-vf", f"select=eq(n\\,{idx})",
            "-vframes", "1",
            frame_png
        ]
        subprocess.run(extract_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        extracted_frames.append(frame_png)

    if os.path.exists(raw_rgb_path):
        os.remove(raw_rgb_path)
    if pcm_path and os.path.exists(pcm_path):
        os.remove(pcm_path)

    return {
        "run_id": run_id,
        "name": name,
        "category": run["category"],
        "success": True,
        "width": width,
        "height": height,
        "frames": frames,
        "fps": fps,
        "duration_seconds": round(frames / fps, 2),
        "steps": run["steps"],
        "fast": run["fast"],
        "seed": run["seed"],
        "mode": "I2V",
        "desc": run["desc"],
        "mp4_path": out_mp4,
        "mp4_size_bytes": os.path.getsize(out_mp4),
        "elapsed_seconds": elapsed,
        "extracted_frames": extracted_frames
    }

def main():
    print(f"Starting Phase 2.5 Real Human Reference Validation ({len(HUMAN_RUNS)} runs)...")
    results = []
    
    for run in HUMAN_RUNS:
        res = execute_run(run)
        results.append(res)
        with open(HUMAN_RESULTS_JSON, "w") as f:
            json.dump(results, f, indent=2)

    with open(HUMAN_RESULTS_CSV, "w") as f:
        f.write("run_id,name,category,mode,width,height,frames,duration_s,steps,fast,seed,elapsed_s,size_kb,desc\n")
        for r in results:
            if r.get("success"):
                size_kb = round(r["mp4_size_bytes"] / 1024, 1)
                f.write(f"{r['run_id']},{r['name']},{r['category']},{r['mode']},{r['width']},{r['height']},{r['frames']},{r['duration_seconds']},{r['steps']},{r['fast']},{r['seed']},{r['elapsed_seconds']},{size_kb},\"{r['desc']}\"\n")

    print("\nPhase 2.5 Real Human Validation completed successfully!")

if __name__ == "__main__":
    main()
