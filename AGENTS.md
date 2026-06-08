# AGENTS.md - VoidLink Retouch

This repository is the default workspace for the VoidLink Retouch Discord project/channel and its threads.

## Default Workflow

- Work from this repository unless the user explicitly names another project.
- After every meaningful code or project-file change, run a relevant build/check, inspect `git status`, and commit the change locally with a clear message.
- Do not push unless the user explicitly asks.

## Sideload IPA Packaging

Wei tests production feel through sideloaded IPA builds. After each successful change commit in this repository, automatically package a fresh debug iOS IPA.

Run:

```sh
BuildScripts/package-debug-ipa.sh
```

The script must:

1. Build `VoidLink.xcodeproj` scheme `VoidLink` for `generic/platform=iOS`.
2. Use `Build/Products/Debug-iphoneos/` as the product directory.
3. Copy and overwrite `VoidLink.app` and `VoidLink.app.dSYM` into `Build/Products/Debug-iphoneos/Payload/`.
4. Zip `Payload/` as `Payload.zip`, rename it to `Payload.ipa`, and copy the IPA to `/Users/liuwei/Dropbox/Personal/Dev/builds/VoidLink IPA/`.

Report the final IPA path, file size, and SHA256. Keep build artifacts uncommitted.
