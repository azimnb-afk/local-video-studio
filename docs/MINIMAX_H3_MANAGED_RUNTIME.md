# MiniMax H3 Managed Runtime Packaging

MiniMax H3 is an experimental, opt-in local renderer. The shipping app carries
only the approximately 194 MiB `mlx-serve` execution payload. It does not carry
or automatically download the approximately 32 GB H3 model.

## Shipping source

`scripts/embed-minimax-h3-runtime.sh` is the single packaging boundary used by
Dev, Personal-install, and release builds. It accepts the audited local runtime
bundle through `MINIMAX_H3_RUNTIME_PAYLOAD_SOURCE`; local developer builds fall
back to the current Dev profile's managed runtime. Distribution mode requires
the environment variable explicitly and fails before producing an artifact if
it is absent.

The accepted source contract is:

- mlx-serve version `26.8.9`, native arm64
- executable source SHA-256
  `f1cbcdf9ee4c54a23da0a3f0f9c91e5a4d1691beb366bae9eaaa9c5c8523e60a`
- complete `LICENSE`, `NOTICE`, and `LICENSE-APACHE-2.0`
- executable, six dylibs, and `mlx.metallib`, with no symbolic links or
  non-system external dynamic dependencies

The local license-file engineering classification is `BUNDLE_ALLOWED` (not
legal advice). The H3 model has a separate license and is excluded.

## Signing and bundle layout

The source artifact's old signature is not trusted. Packaging verifies the
source checksum, copies it into:

```text
Local Video Studio.app/
  Contents/Resources/MiniMaxH3Runtime/
    payload_manifest.json
    mlx-serve/
```

Every copied Mach-O is signed inside-out, followed by the outer app. Local-test
artifacts use non-hardened ad-hoc signatures for the app, child executable, and
dylibs so their lack of a Team ID does not trigger hardened library validation.
Distribution mode requires a Developer ID
Application identity and applies hardened runtime plus timestamp consistently
to the child executable, dylibs, and app before notarization. All modes run
strict code-sign verification. Local-test DMGs remain explicitly not for public
distribution.

## First run and managed install

Settings presents two independent states:

- **Runtime** — Install/Repair copies the app resource into the active
  profile's managed runtime directory, then verifies version, arm64 format,
  license files, executable SHA, and every required component SHA.
- **Model** — the user chooses an existing local H3 model folder. There is no
  implicit download or copy.

Managed roots remain isolated:

```text
Personal: ~/Library/Application Support/LocalVideoStudio/Runtimes/mlx-serve/
Dev:      ~/Library/Application Support/LocalVideoStudioDev/Runtimes/mlx-serve/
```

Fresh managed endpoints are also isolated:

- Personal: `http://127.0.0.1:11237`
- Dev: `http://127.0.0.1:11236`
- legacy/advanced external reuse: commonly `http://127.0.0.1:11235`

Explicit existing endpoint preferences are preserved. Servers started by the
app bind loopback only and are app-owned; only those processes are stopped on
quit. A compatible server already listening at an explicitly configured
endpoint is external and is never stopped by the app.

## Acceptance boundary

The packaging acceptance harness installs from a built Personal app into a
temporary Personal-shaped Application Support tree, launches on port 11237,
checks health and exact-model readiness, and runs one 512×288, 56-frame,
single-window, 8-step I2V through the production GenerationService path. It does
not read or write the real Personal project/history/queue data and does not use
the external 11235 server.
