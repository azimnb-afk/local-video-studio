# OpenClaw / Local Agent Integration (optional)

LTX Video Generator is a **GUI-first macOS app**. This directory documents the
optional localhost REST API (v1) that lets OpenClaw — or any local agent or
script — drive the same generation core the GUI uses. The app is 100% usable
without OpenClaw; this API is an additional entry point, not a runtime.

## Enabling

1. Open the app → Preferences → Models & Features → enable **Local REST API v1**.
2. Restart the app (the server starts at launch when the flag is on).
3. The server binds **127.0.0.1:8421 only** (loopback; never LAN).

## Authentication

A random installation token is generated on first start:

```
~/Library/Application Support/LTXVideoGenerator/api_token
```

Send it on every request:

```
Authorization: Bearer <token>
```

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| POST | /v1/assets | Upload a PNG/JPEG (base64 JSON) → assetID |
| POST | /v1/jobs | Create a generation job (1–20 variations) |
| GET | /v1/jobs/{id} | Job status + results |
| DELETE | /v1/jobs/{id} | Cancel pending variations |
| GET | /v1/models | Selectable models + capabilities |
| GET | /v1/system | Hardware / memory / generator state |
| GET | /v1/history | Recent generation results |

Notes:
- Clients never pass filesystem paths. Upload an image → use `input.assetID`.
- `variations` is capped at 20; generation is always sequential (one at a time).
- `quality` maps to the GUI presets (`compact` Quick, `auto` Standard, `high`
  High, `advanced` Custom). A supplied `duration` is a final constraint: the
  app resolves the profile first, then computes compatible 8n+1 frames.
- Adult-classified models are rejected unless Adult Content Mode is ON **in the
  app**; the API cannot override the app's setting.
- Video generation is local-only. The API never triggers cloud generation.

## curl examples

```bash
TOKEN=$(cat ~/Library/Application\ Support/LTXVideoGenerator/api_token)
BASE=http://127.0.0.1:8421

# System info
curl -s -H "Authorization: Bearer $TOKEN" $BASE/v1/system | jq

# Models
curl -s -H "Authorization: Bearer $TOKEN" $BASE/v1/models | jq

# Text-to-video job (3 variations, ~4 seconds each)
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "task": "text_to_video",
    "prompt": "A red fox trots through fresh snow at dawn, cinematic, soft light.",
    "duration": 4,
    "quality": "auto",
    "audio": true,
    "model": "auto",
    "variations": 3,
    "seed": 12345
  }' $BASE/v1/jobs | jq

# Upload an image, then image-to-video
ASSET=$(base64 -i input.png | tr -d '\n')
ASSET_ID=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"dataBase64\": \"$ASSET\"}" $BASE/v1/assets | jq -r .assetID)

curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{
    \"task\": \"image_to_video\",
    \"prompt\": \"cinematic slow push-in, gentle natural motion\",
    \"input\": {\"assetID\": \"$ASSET_ID\"},
    \"duration\": 4,
    \"quality\": \"auto\",
    \"variations\": 1
  }" $BASE/v1/jobs | jq

# Poll a job
curl -s -H "Authorization: Bearer $TOKEN" $BASE/v1/jobs/<jobID> | jq
```

## Job JSON schema

See [`job.schema.json`](job.schema.json).

## OpenClaw skill example

See [`skill-example.md`](skill-example.md) for a minimal OpenClaw skill that
wraps these endpoints. Keep the OpenClaw side thin: the app owns generation,
queueing, model policy and quality decisions.
