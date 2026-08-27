#!/usr/bin/env python3
import os
import json

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(BASE_DIR, "benchmark_results.json")) as f:
    r1 = json.load(f)
with open(os.path.join(BASE_DIR, "final_validation_results.json")) as f:
    r2 = json.load(f)

csv_path = os.path.join(BASE_DIR, "final_summary_table.csv")
with open(csv_path, "w") as f:
    f.write("run_id,name,category,mode,width,height,frames,duration_s,steps,fast,seed,elapsed_s,elapsed_m,size_kb,desc\n")
    for r in r1 + r2:
        if r.get("success"):
            fast_val = r.get("fast", True)
            elapsed_m = round(r["elapsed_seconds"] / 60, 2)
            size_kb = round(r["mp4_size_bytes"] / 1024, 1)
            f.write(f"{r['run_id']},{r['name']},{r['category']},{r['mode']},{r['width']},{r['height']},{r['frames']},{r['duration_seconds']},{r['steps']},{fast_val},{r['seed']},{r['elapsed_seconds']},{elapsed_m},{size_kb},\"{r['desc']}\"\n")

print(f"Updated {csv_path}")
