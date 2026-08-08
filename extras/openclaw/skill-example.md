# Example OpenClaw skill: ltx-video

A minimal skill wrapping the localhost API. Place in your OpenClaw skills
directory and adjust to your skill format version.

```markdown
---
name: ltx-video
description: Generate short videos locally with the LTX Video Generator Mac app (localhost API). Use for "generate a video of ...", "animate this image ...".
---

# ltx-video

Base URL: http://127.0.0.1:8421
Token: read from ~/Library/Application Support/LTXVideoGenerator/api_token
Header: Authorization: Bearer <token>

## Generate from text
POST /v1/jobs with JSON:
{"task":"text_to_video","prompt":"<user's description, chronological, present tense>","duration":4,"quality":"auto","variations":1}

## Animate an image
1. POST /v1/assets {"dataBase64":"<base64 of PNG/JPEG>"} → assetID
2. POST /v1/jobs {"task":"image_to_video","prompt":"<motion description>","input":{"assetID":"<assetID>"},"duration":4,"quality":"auto"}

## Rules
- Poll GET /v1/jobs/{jobID} every 15s until state=completed; report outputPath.
- Never send more than variations=20; prefer 1-3.
- If the API returns 403 (policy) or 401 (token), tell the user to check the
  app's Preferences; do not retry.
- The app generates locally and sequentially — long waits are normal.
```
