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
RESULTS_JSON = os.path.join(BASE_DIR, "benchmark_results.json")
RESULTS_CSV = os.path.join(BASE_DIR, "summary_table.csv")

LANDSCAPE_REF = os.path.join(INPUTS_DIR, "test_ref_landscape.png")
PORTRAIT_REF = os.path.join(INPUTS_DIR, "test_ref_portrait.png")

PROMPT_I2V = (
    "The woman smiles gently and looks slightly to the side as a soft breeze moves her hair, "
    "the camera slowly glides forward, smooth cinematic motion. "
    "The subject's face, clothing, hairstyle, background, and lighting remain consistent throughout the shot."
)

PROMPT_T2V = (
    "A serene woman with shoulder-length dark hair and a warm smile, standing in a brightly lit modern room near a window, "
    "gentle breeze moving her hair, natural cinematic lighting, smooth slow camera push-in."
)

RUNS = [
    # 1. Step Axis (512x288, 90f)
    {
        "id": "RUN_01",
        "name": "I2V_512x288_90f_08steps",
        "category": "steps_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 512,
        "height": 288,
        "num_frames": 90,
        "steps": 8,
        "seed": 42,
        "desc": "Quick Preset Step Level (8 steps)"
    },
    {
        "id": "RUN_02",
        "name": "I2V_512x288_90f_10steps",
        "category": "steps_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 512,
        "height": 288,
        "num_frames": 90,
        "steps": 10,
        "seed": 42,
        "desc": "Standard Baseline (10 steps)"
    },
    {
        "id": "RUN_03",
        "name": "I2V_512x288_90f_12steps",
        "category": "steps_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 512,
        "height": 288,
        "num_frames": 90,
        "steps": 12,
        "seed": 42,
        "desc": "High Preset Step Level (12 steps)"
    },
    {
        "id": "RUN_04",
        "name": "I2V_512x288_90f_16steps",
        "category": "steps_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 512,
        "height": 288,
        "num_frames": 90,
        "steps": 16,
        "seed": 42,
        "desc": "Proposed Standard Sweet Spot (16 steps)"
    },
    {
        "id": "RUN_05",
        "name": "I2V_512x288_90f_20steps",
        "category": "steps_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 512,
        "height": 288,
        "num_frames": 90,
        "steps": 20,
        "seed": 42,
        "desc": "High Quality Candidate (20 steps)"
    },
    {
        "id": "RUN_06",
        "name": "I2V_512x288_90f_24steps",
        "category": "steps_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 512,
        "height": 288,
        "num_frames": 90,
        "steps": 24,
        "seed": 42,
        "desc": "Quality Ceiling (24 steps)"
    },

    # 2. Resolution Axis (@ 16 & 20 steps)
    {
        "id": "RUN_07",
        "name": "I2V_640x384_90f_16steps",
        "category": "resolution_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 16,
        "seed": 42,
        "desc": "Tier 2 Resolution @ 16 steps"
    },
    {
        "id": "RUN_08",
        "name": "I2V_640x384_90f_20steps",
        "category": "resolution_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 20,
        "seed": 42,
        "desc": "Tier 2 Resolution @ 20 steps"
    },

    # 3. Duration / Frames Axis (@ 640x384, 16-20 steps)
    {
        "id": "RUN_09",
        "name": "I2V_640x384_73f_16steps",
        "category": "duration_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 73,
        "steps": 16,
        "seed": 42,
        "desc": "Short 3.0s (73 frames)"
    },
    {
        "id": "RUN_10",
        "name": "I2V_640x384_107f_16steps",
        "category": "duration_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 107,
        "steps": 16,
        "seed": 42,
        "desc": "Medium 4.5s (107 frames)"
    },
    {
        "id": "RUN_11",
        "name": "I2V_640x384_124f_20steps",
        "category": "duration_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 124,
        "steps": 20,
        "seed": 42,
        "desc": "Long 5.2s (124 frames @ 20 steps)"
    },
    {
        "id": "RUN_12",
        "name": "I2V_640x384_141f_20steps",
        "category": "duration_axis",
        "prompt": PROMPT_I2V,
        "ref_image": LANDSCAPE_REF,
        "width": 640,
        "height": 384,
        "num_frames": 141,
        "steps": 20,
        "seed": 42,
        "desc": "Max Single Window 5.9s (141 frames @ 20 steps)"
    },

    # 4. Conditioning Mode: T2V Axis
    {
        "id": "RUN_13",
        "name": "T2V_512x288_90f_10steps",
        "category": "conditioning_axis",
        "prompt": PROMPT_T2V,
        "ref_image": None,
        "width": 512,
        "height": 288,
        "num_frames": 90,
        "steps": 10,
        "seed": 42,
        "desc": "T2V Current Baseline (10 steps)"
    },
    {
        "id": "RUN_14",
        "name": "T2V_640x384_90f_16steps",
        "category": "conditioning_axis",
        "prompt": PROMPT_T2V,
        "ref_image": None,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 16,
        "seed": 42,
        "desc": "T2V Proposed Standard (16 steps)"
    },
    {
        "id": "RUN_15",
        "name": "T2V_640x384_90f_24steps",
        "category": "conditioning_axis",
        "prompt": PROMPT_T2V,
        "ref_image": None,
        "width": 640,
        "height": 384,
        "num_frames": 90,
        "steps": 24,
        "seed": 42,
        "desc": "T2V High Steps (24 steps)"
    },

    # 5. Portrait Axis
    {
        "id": "RUN_16",
        "name": "I2V_Portrait_288x512_90f_10steps",
        "category": "portrait_axis",
        "prompt": PROMPT_I2V,
        "ref_image": PORTRAIT_REF,
        "width": 288,
        "height": 512,
        "num_frames": 90,
        "steps": 10,
        "seed": 42,
        "desc": "Portrait Current Baseline (288x512, 10 steps)"
    },
    {
        "id": "RUN_17",
        "name": "I2V_Portrait_384x640_90f_16steps",
        "category": "portrait_axis",
        "prompt": PROMPT_I2V,
        "ref_image": PORTRAIT_REF,
        "width": 384,
        "height": 640,
        "num_frames": 90,
        "steps": 16,
        "seed": 42,
        "desc": "Portrait Proposed Standard (384x640, 16 steps)"
    }
]

def prepare_image_b64(image_path, target_w, target_h):
    if not image_path or not os.path.exists(image_path):
        return None
    # Resize and crop to target_w x target_h
    img = Image.open(image_path).convert("RGB")
    src_w, src_h = img.size
    target_aspect = target_w / target_h
    src_aspect = src_w / src_h

    if src_aspect > target_aspect:
        # Crop width
        crop_w = int(src_h * target_aspect)
        left = (src_w - crop_w) // 2
        img = img.crop((left, 0, left + crop_w, src_h))
    else:
        # Crop height
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
    print(f"Resolution: {run['width']}x{run['height']}, Frames: {run['num_frames']}, Steps: {run['steps']}, Mode: {'I2V' if run['ref_image'] else 'T2V'}")
    print(f"========================================================")

    img_b64 = prepare_image_b64(run["ref_image"], run["width"], run["height"])

    payload = {
        "prompt": run["prompt"],
        "width": run["width"],
        "height": run["height"],
        "num_frames": run["num_frames"],
        "steps": run["steps"],
        "seed": run["seed"],
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
        with urllib.request.urlopen(req, timeout=1800) as response:
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

    # Write raw and mux MP4
    raw_rgb_path = os.path.join(RAW_DIR, f"{run_id}_{name}_raw.rgb")
    with open(raw_rgb_path, "wb") as f:
        f.write(rgb_data)

    pcm_path = None
    if pcm_data:
        pcm_path = os.path.join(RAW_DIR, f"{run_id}_{name}_audio.pcm")
        with open(pcm_path, "wb") as f:
            f.write(pcm_data)

    out_mp4 = os.path.join(RAW_DIR, f"{run_id}_{name}.mp4")

    # FFmpeg mux
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

    # Extract key frames (0%, 25%, 50%, 75%, 100%)
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
        # Extract exact frame index using ffmpeg
        extract_cmd = [
            "ffmpeg", "-y",
            "-i", out_mp4,
            "-vf", f"select=eq(n\\,{idx})",
            "-vframes", "1",
            frame_png
        ]
        subprocess.run(extract_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        extracted_frames.append(frame_png)

    # Clean up temp raw files to save disk
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
        "seed": run["seed"],
        "mode": "I2V" if run["ref_image"] else "T2V",
        "desc": run["desc"],
        "mp4_path": out_mp4,
        "mp4_size_bytes": os.path.getsize(out_mp4),
        "elapsed_seconds": elapsed,
        "extracted_frames": extracted_frames
    }

def generate_contact_sheet(category_name, run_results, out_sheet_path):
    # Filter runs for this category
    runs = [r for r in run_results if r.get("success") and (r.get("category") == category_name or category_name == "ALL")]
    if not runs:
        return

    # Dimensions
    cols = 5 # 5 key frames
    rows = len(runs)
    sample_img = Image.open(runs[0]["extracted_frames"][0])
    thumb_w, thumb_h = sample_img.size
    
    # Scale down if very large for contact sheet
    scale = 1.0
    if thumb_w > 480:
        scale = 480 / thumb_w
        thumb_w = int(thumb_w * scale)
        thumb_h = int(thumb_h * scale)

    header_h = 40
    row_label_w = 260
    margin = 8

    sheet_w = row_label_w + cols * (thumb_w + margin) + margin
    sheet_h = header_h + rows * (thumb_h + margin + 20) + margin

    sheet = Image.new("RGB", (sheet_w, sheet_h), (24, 24, 28))
    draw = ImageDraw.Draw(sheet)

    # Draw header
    frame_labels = ["0% (First)", "25% (Early)", "50% (Mid)", "75% (Late)", "100% (Final)"]
    for c, flabel in enumerate(frame_labels):
        x = row_label_w + c * (thumb_w + margin) + 10
        draw.text((x, 12), flabel, fill=(220, 220, 230))

    # Draw rows
    for r, run_info in enumerate(runs):
        y = header_h + r * (thumb_h + margin + 20)
        # Draw label
        info_text = f"{run_info['run_id']}\n{run_info['name']}\n{run_info['width']}x{run_info['height']} | {run_info['steps']}st | {run_info['frames']}f\n{run_info['elapsed_seconds']}s"
        draw.text((margin, y + 10), info_text, fill=(200, 200, 210))

        # Paste frames
        for c, fpath in enumerate(run_info["extracted_frames"]):
            if os.path.exists(fpath):
                img = Image.open(fpath).convert("RGB")
                if scale != 1.0:
                    img = img.resize((thumb_w, thumb_h), Image.Resampling.LANCZOS)
                x = row_label_w + c * (thumb_w + margin)
                sheet.paste(img, (x, y))

    sheet.save(out_sheet_path, "PNG")
    print(f"Contact sheet created: {out_sheet_path}")

def main():
    print(f"Starting MiniMax H3 Comprehensive Preset Benchmark ({len(RUNS)} runs)...")
    results = []
    
    for run in RUNS:
        res = execute_run(run)
        results.append(res)
        # Write intermediate results
        with open(RESULTS_JSON, "w") as f:
            json.dump(results, f, indent=2)

    # Generate Category Contact Sheets
    categories = ["steps_axis", "resolution_axis", "duration_axis", "conditioning_axis", "portrait_axis", "ALL"]
    for cat in categories:
        out_sheet = os.path.join(SHEETS_DIR, f"contact_sheet_{cat}.png")
        generate_contact_sheet(cat, results, out_sheet)

    # Write CSV Summary
    with open(RESULTS_CSV, "w") as f:
        f.write("run_id,name,category,mode,width,height,frames,duration_s,steps,seed,elapsed_s,size_kb,desc\n")
        for r in results:
            if r.get("success"):
                size_kb = round(r["mp4_size_bytes"] / 1024, 1)
                f.write(f"{r['run_id']},{r['name']},{r['category']},{r['mode']},{r['width']},{r['height']},{r['frames']},{r['duration_seconds']},{r['steps']},{r['seed']},{r['elapsed_seconds']},{size_kb},\"{r['desc']}\"\n")

    print("\nBenchmark completed successfully!")

if __name__ == "__main__":
    main()
