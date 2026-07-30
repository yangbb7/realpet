# Legacy Cubism Compatibility

Cubism is no longer RealPet's import or runtime default. New pets replay
owner-supplied alpha-matted source frames through `FrameSequencePetRuntime` and
can attach captured or quality-gated generated action clips. This document only
applies when a release maintainer needs to keep an existing compiled Cubism pet
working during migration.

## Optional Packaging

Set `REALPET_INCLUDE_LEGACY_CUBISM=1` before running `build_app.sh`. The build
then requires a complete, licensed Cubism Web distribution under
`REALPET_CUBISM_WEB_RUNTIME` (or `web/cubism-runtime/dist`) containing:

- `live2dcubismcore.min.js`
- `realpet-cubism.bundle.js`
- `CUBISM_SDK_LICENSE.md`
- `LIVE2D_OPEN_SOFTWARE_LICENSE.md`
- `shaders/`

Without that explicit flag, the app intentionally omits Cubism assets and still
builds and runs source-frame pets. Do not add Cubism as a dependency for new
imports.

## Migration Boundary

Existing `.model3.json` packages may continue to use the legacy renderer. New
imports must set `rendererKind: sourceFrames`, preserve the processed source
frames, and write `actions.json` plus `pet-features.json`. Generated texture
atlases and fixed templates are not a substitute for owner footage and should
not be offered as the default product path.
