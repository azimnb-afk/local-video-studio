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
FINAL_RESULTS_JSON = os.path.join(BASE_DIR, "final_validation_results.json")
FINAL_RESULTS_CSV = os.path.join(BASE_DIR, "final_summary_table.csv")

LANDSCAPE_REF = os.path.join(INPUTS_DIR, "test_ref_landscape.png")

PROMPT_I2V = (
    "The woman smiles gently and looks slightly to the side as a soft breeze moves her hair, "
    "the camera slowly glides forward, smooth cinematic motion. "
    "The subject's face, clothing, hairstyle, background, and lighting remain consistent throughout the shot."
)

FINAL_RUNS = [
    # 1. Exact Current High Baseline
    {
        "id": "FINAL_RUN_01",
        "name": "CurrentHigh_640x384_90f_12st_FastON_s42",
        "category": "current_high_baseline",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 12,
        "fast": True,
        "seed": 42,
        "desc": "Exact Current High Baseline (640x384, 90f, 12st, Fast ON, s42)"
    },

    # 2. Fast ON vs OFF Matrix
    {
        "id": "FINAL_RUN_02",
        "name": "FastOFF_640x384_90f_16st_FastOFF_s42",
        "category": "fast_mode_comparison",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 16,
        "fast": False,
        "seed": 42,
        "desc": "Fast OFF Comparison @ 16 steps (640x384, 90f, Fast OFF, s42)"
    },
    {
        "id": "FINAL_RUN_03",
        "name": "FastOFF_640x384_90f_20st_FastOFF_s42",
        "category": "fast_mode_comparison",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 20,
        "fast": False,
        "seed": 42,
        "desc": "Fast OFF Comparison @ 20 steps (640x384, 90f, Fast OFF, s42)"
    },

    # 3. Second Seed Replication (s31415)
    {
        "id": "FINAL_RUN_04",
        "name": "SeedReplication_640x384_90f_16st_FastON_s31415",
        "category": "seed_replication",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 16,
        "fast": True,
        "seed": 31415,
        "desc": "Second-Seed Replication (640x384, 90f, 16st, Fast ON, s31415)"
    },
    {
        "id": "FINAL_RUN_05",
        "name": "SeedReplication_640x384_90f_20st_FastON_s31415",
        "category": "seed_replication",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 20,
        "fast": True,
        "seed": 31415,
        "desc": "Second-Seed Replication (640x384, 90f, 20st, Fast ON, s31415)"
    },

    # 4. Exact Current Quick Baseline
    {
        "id": "FINAL_RUN_06",
        "name": "CurrentQuick_512x288_73f_08st_FastON_s42",
        "category": "quick_comparison",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 512,
        "height": 288,
        "num_frames": 73,
        "steps": 8,
        "fast": True,
        "seed": 42,
        "desc": "Exact Current Quick Baseline (512x288, 73f, 8st, Fast ON, s42)"
    }
]

def prepare_image_b64(image_path, target_w, target_h):
    if not image_path or not os.path.exists(image_path):
        return None
    img = Image.open(image_path).convert("RGB")
    src_w, src_h = img.size
    target_aspect = target_w / target_h
    src_aspect = src_w / src_h

    if src_aspect > target_aspect:
        crop_w = int(src_h * target_aspect)
        left = (src_w - crop_w) // 2
        img = img.crop((left, 0, left + crop_w, src_h))
    else:
        crop_h = int(src_w / target_aspect)
        top = (src_h - crop_h) // 2
        img = img.crop((0, top, src_w, top + crop_h))

    img = img.resize((target_w, target_h), Image.Resampling.LANCZOS)
    temp_path = os.path.join(INPUTS_DIR, f"temp_{target_w}x{target_h}.jpg")
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

    img_b64 = prepare_image_b64(run["ref_image"], run["width"], run["height"])

    payload = {
        "prompt": run["prompt"],
        "width": run["width"],
        "height": run["height"],
        "num_frames": run["num_frames"],
        "steps": run["steps"],
        "seed": run["seed"],
        "fast": run["fast"],
        "chain_windows": 1
    }
    if img_b64:
        payload["first_frame_image"] = img_b64

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
        "mode": "I2V" if run["ref_image"] else "T2V",
        "desc": run["desc"],
        "mp4_path": out_mp4,
        "mp4_size_bytes": os.path.getsize(out_mp4),
        "elapsed_seconds": elapsed,
        "extracted_frames": extracted_frames
    }

def main():
    print(f"Starting Phase 2 Final Validation Runs ({len(FINAL_RUNS)} runs)...")
    results = []
    
    for run in FINAL_RUNS:
        res = execute_run(run)
        results.append(res)
        with open(FINAL_RESULTS_JSON, "w") as f:
            json.dump(results, f, indent=2)

    with open(FINAL_RESULTS_CSV, "w") as f:
        f.write("run_id,name,category,mode,width,height,frames,duration_s,steps,fast,seed,elapsed_s,size_kb,desc\n")
        for r in results:
            if r.get("success"):
                size_kb = round(r["mp4_size_bytes"] / 1024, 1)
                f.write(f"{r['run_id']},{r['name']},{r['category']},{r['mode']},{r['width']},{r['height']},{r['frames']},{r['duration_seconds']},{r['steps']},{r['fast']},{r['seed']},{r['elapsed_seconds']},{size_kb},\"{r['desc']}\"\n")

    print("\nPhase 2 Validation Runs completed successfully!")

if __name__ == "__main__":
    main()
