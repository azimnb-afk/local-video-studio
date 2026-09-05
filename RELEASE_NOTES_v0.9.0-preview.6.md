# v0.9.0-preview.6 — Portrait Reference Orientation Fix

Local Video Studio for Mac `v0.9.0-preview.6` fixes portrait reference images producing landscape video. If you build vertical content from a portrait first/reference image, this release is required.

Everything else in `preview.5` is unchanged, including the LTX-2.5 image-conditioning fix it shipped.

---

## What's Fixed

### 📐 Portrait References Now Produce Portrait Video

Starting an **Auto Movie** from a portrait (vertical) **Opening Reference** could produce a landscape (horizontal) movie instead.

The trigger was subtle: turning the **Audio** toggle off — or otherwise switching the project to the **Custom** preset — froze the project at a landscape 768×512 size, discarding the portrait shape your reference image implied. Because Custom is meant to keep exactly the size you chose, that stale landscape default then won for every shot in the movie.

Now the size your preset was actually going to use, already matched to your reference's orientation, is carried across that switch. A portrait reference stays portrait through the whole movie.

**This also means:**
- Turning Audio on or off no longer silently changes your movie's shape.
- Changing the preset on an existing project keeps the orientation it was already using.
- Choosing a reference image after switching to Custom still sets the canvas.

**A size you pick yourself is still always respected.** If you explicitly choose 768×512, you get 768×512 — automatic orientation never overrides an explicit choice.

**Landscape projects are unaffected.**

---

## Upgrading

Download and replace the app. No runtime update is required — `preview.6` uses the same LTX-2.5 runtime as `preview.5`, so **Install LTX-2.5 Runtime** does not need to be run again.

Your existing projects, characters, and Video Archive history are unaffected. Projects already saved with a landscape size keep that size; change the preset (or the width/height) to pick up the portrait canvas.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1 Pro, M2, M3, M4)
- **RAM**: 32 GB minimum (Q4 models); 48 GB+ recommended
- **OS**: macOS 14.0 (Sonoma) or later (Apple On-Device Translation programmatic session requires macOS 26.0+)
- **Tools**: Python 3.11+ and `ffmpeg` (via Homebrew: `brew install ffmpeg`)
- **LTX-2.5 (Experimental)**: an additional ~2 GB for the app-managed runtime, plus your chosen GGUF model file (commonly 12–24 GB depending on quantization)

---

## Known Limitations

Unchanged from `preview.5`:

1. **LTX-2.5 is Experimental**: not the default model, not guaranteed faster than LTX-2.3, and not verified on every Apple Silicon configuration.
2. **No Identity or Length Guarantees**: a reference image genuinely influences the result, but it does not guarantee an identical person across separate shots.
3. **Visual Continuity is Model-Dependent**: strong previous-frame conditioning can make large camera resets or location jumps harder within one Auto Movie sequence.
4. **No-BGM Policy is Best-Effort with Built-in Audio**: for guaranteed music-free output, turn **Built-in Audio OFF** and use **Final Audio** mixing.
5. **Custom Model Profiles Cap at 5**: an intentional limit for this release.

---

## Preview Build Signing

Like `preview.1` through `preview.5`, this is an unsigned, un-notarized preview build. macOS will warn on first launch; right-click the app and choose **Open** to run it. Developer ID signing and notarization remain planned for the stable release.

---

## Technical Notes

The orientation rule itself was correct: a preset resolves its landscape base size against the source image's orientation, so Standard on a portrait Opening Reference already produced 512×768. What was missing was carrying that resolved size across the transition onto the Custom preset.

Custom deliberately preserves whatever dimensions it holds — that is what makes an explicit user size beat automatic orientation — but nothing wrote the oriented size down before that freeze. The New Auto Movie sheet seeded Custom from a hardcoded 768×512, and the Audio toggle switches the project to Custom, so turning Audio off converted "Standard, oriented to my portrait reference" into "explicit landscape 768×512". The project settings editor had the same gap via `markCustom()`.

Both paths now materialize the preset's oriented size at the moment it stops being derived, resolved through the same code path generation itself uses, so the orientation rule keeps exactly one implementation. Orientation matching was introduced after the Auto Movie sheet was written and had never covered this seeding path.
