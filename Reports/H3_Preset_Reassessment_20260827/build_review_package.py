#!/usr/bin/env python3
import os
import json

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
FRAMES_DIR = os.path.join(BASE_DIR, "representative_frames")
SHEETS_DIR = os.path.join(BASE_DIR, "contact_sheets")
RAW_DIR = os.path.join(BASE_DIR, "raw_results")
HTML_FILE = os.path.join(BASE_DIR, "FINAL_REVIEW.html")

# Load results
with open(os.path.join(BASE_DIR, "benchmark_results.json")) as f:
    r1 = json.load(f)
with open(os.path.join(BASE_DIR, "final_validation_results.json")) as f:
    r2 = json.load(f)

all_runs = {r["run_id"]: r for r in r1 + r2 if r.get("success")}

# Generate Upgraded Self-Contained FINAL_REVIEW.html with Inline Video Players
html_content = """<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>MiniMax H3 Preset Reassessment — Final Visual Review</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #121214; color: #e0e0e0; margin: 0; padding: 24px; }
  h1, h2, h3 { color: #ffffff; }
  h1 { border-bottom: 2px solid #333; padding-bottom: 12px; }
  .section { background: #1c1c20; border-radius: 8px; padding: 20px; margin-bottom: 30px; border: 1px solid #2e2e36; }
  .grid { display: flex; flex-direction: column; gap: 20px; margin-top: 16px; }
  .row { display: flex; align-items: flex-start; background: #26262c; border-radius: 8px; padding: 16px; gap: 16px; border: 1px solid #33333d; }
  .meta { width: 280px; flex-shrink: 0; font-size: 13px; line-height: 1.5; }
  .meta strong { color: #4dabf7; font-size: 15px; }
  .video-container { width: 240px; flex-shrink: 0; }
  .video-container video { width: 100%; border-radius: 6px; background: #000; border: 1px solid #444; }
  .frames { display: flex; gap: 8px; overflow-x: auto; flex-grow: 1; align-items: center; }
  .frame-card { display: flex; flex-direction: column; align-items: center; }
  .frame-card img { width: 150px; height: auto; border-radius: 4px; border: 1px solid #444; }
  .frame-label { font-size: 11px; color: #888; margin-top: 4px; }
  .tag { display: inline-block; padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: bold; margin-left: 6px; }
  .tag-good { background: #2b8a3e; color: #fff; }
  .tag-bad { background: #c92a2a; color: #fff; }
  .tag-warn { background: #e67700; color: #fff; }
  .tag-info { background: #1971c2; color: #fff; }
  a { color: #4dabf7; text-decoration: none; }
  a:hover { text-decoration: underline; }
</style>
</head>
<body>

<h1>MiniMax H3 Preset Reassessment — Final Visual Review</h1>
<p>各生成結果の動画（MP4・音声付）および代表 5 フレーム（0%, 25%, 50%, 75%, 100%）を直接ブラウザ上で比較・再生できます。</p>

<div class="section">
  <h2>1. 現行 High (12st) vs 提案 16st vs 20st（Steps & Fast ON/OFF 比較）</h2>
  <p><strong>結論:</strong> 12 steps（現行High）は終盤に微細ジッターが残りますが、16 steps でデノイズが完全収束。Fast ON は Fast OFF と画質差が全くなく、時間を約 40% 短縮できます。</p>
  <div class="grid">
"""

def render_run_html(run_id, badge=""):
    r = all_runs.get(run_id)
    if not r: return ""
    fast_str = "Fast ON" if r.get("fast", True) else "Fast OFF"
    rel_mp4 = os.path.relpath(r["mp4_path"], BASE_DIR)
    frames_html = ""
    flabels = ["0% (First)", "25%", "50%", "75%", "100% (Final)"]
    for i, fpath in enumerate(r["extracted_frames"]):
        rel_f = os.path.relpath(fpath, BASE_DIR)
        frames_html += f"""
        <div class="frame-card">
          <a href="{rel_f}" target="_blank"><img src="{rel_f}" loading="lazy"></a>
          <span class="frame-label">{flabels[i]}</span>
        </div>
        """
    return f"""
    <div class="row">
      <div class="meta">
        <strong>{r['run_id']}</strong> {badge}<br>
        <code>{r['name']}</code><br><br>
        • 解像度: <strong>{r['width']}×{r['height']}</strong><br>
        • Steps: <strong>{r['steps']} steps</strong> ({fast_str})<br>
        • Seed: <strong>{r['seed']}</strong> | Frames: <strong>{r['frames']}f</strong> ({r['duration_seconds']}s)<br>
        • 生成時間: <strong>{r['elapsed_seconds']}s ({r['elapsed_seconds']/60:.1f}分)</strong><br><br>
        <a href="{rel_mp4}" target="_blank">📥 MP4 ファイルを開く</a>
      </div>
      <div class="video-container">
        <video controls loop preload="metadata" src="{rel_mp4}"></video>
      </div>
      <div class="frames">
        {frames_html}
      </div>
    </div>
    """

for rid in ["FINAL_RUN_01", "RUN_07", "FINAL_RUN_02", "RUN_08", "FINAL_RUN_03"]:
    badge = ""
    if rid == "FINAL_RUN_01": badge = '<span class="tag tag-warn">現行 High (12st)</span>'
    elif rid == "RUN_07": badge = '<span class="tag tag-good">🏆 提案 Standard (16st)</span>'
    elif rid == "RUN_08": badge = '<span class="tag tag-good">💎 提案 High (20st)</span>'
    html_content += render_run_html(rid, badge)

html_content += """
  </div>
</div>

<div class="section">
  <h2>2. 第 2 シード再現性検証 (Seed 42 vs Seed 31415)</h2>
  <p><strong>結論:</strong> 独立したシード（Seed 31415）でも、16 steps でのデノイズ収束と 20 steps での最高峰の質感が完全に再現されました。</p>
  <div class="grid">
"""

for rid in ["RUN_07", "FINAL_RUN_04", "RUN_08", "FINAL_RUN_05"]:
    badge = '<span class="tag tag-info">Seed 再現</span>'
    html_content += render_run_html(rid, badge)

html_content += """
  </div>
</div>

<div class="section">
  <h2>3. Quick プリセット: 時間 vs 品質のトレードオフ</h2>
  <p><strong>結論:</strong> 640×384 / 16st は高画質ですが約 9.9 分かかり、Standard（約 11.8 分）と大差がなく「Quick」の体験を損ないます。Quick は 512×288 / 73f / 8st（約 5.2 分）で真の高速ドラフトとして維持すべきです。</p>
  <div class="grid">
"""

for rid in ["FINAL_RUN_06", "RUN_02", "RUN_09", "RUN_07"]:
    badge = ""
    if rid == "FINAL_RUN_06": badge = '<span class="tag tag-good">⚡ 真の高速ドラフト (Quick)</span>'
    elif rid == "RUN_09": badge = '<span class="tag tag-warn">準本番 (9.9分)</span>'
    html_content += render_run_html(rid, badge)

html_content += """
  </div>
</div>

<div class="section">
  <h2>4. 実際の LTX 2.5 監査結果</h2>
  <p><strong>監査ステータス:</strong> <code>LTX25_AVAILABLE: NO</code></p>
  <p>ローカルディスク上に存在する公式 LTX-2.5 モデルは非量子化 BF16（66.2GB）のみであり、実行には 86GB 以上の RAM を要求するため 48GB Mac 上ではメモリ不足で実行できません。48GB 向け量子化 MLX パックが未構成のため、比較ルールに従い除外しています（LTX 2.3 蒸留版を LTX 2.5 と誤認・偽装せず正確に報告）。</p>
</div>

</body>
</html>
"""

with open(HTML_FILE, "w") as f:
    f.write(html_content)

print(f"Upgraded {HTML_FILE} with inline video players.")
