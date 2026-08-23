# Project Status — Keyline

**As of:** 2026-08-23  
**GitHub:** https://github.com/nightmoose/Keyline (private) — **created this day**  
**Local:** `~/Projects/Keyline`  
**Branch:** `main`

## What this is

Native macOS **viewer** (not editor) for Illustrator and Photoshop files.
Shows them as those apps would, then print / export to open formats (PDF,
PNG/JPEG/TIFF, OpenRaster). macOS 14+, XcodeGen.

## Current state

Built locally 2026-08-19 (xcodeproj, tests, sample generators). Never had a
GitHub remote until this pass. `build/` is derived data — gitignored.

## Open / next

- Older `.ai` without PDF compatibility cannot be reconstructed (no PS
  interpreter on modern macOS) — document, don’t fake it
- Adjustment layers / smart objects: appearance is the composite

## Notes for humans and AIs

Do not commit `build/` or xcuserdata. Tests write in-memory PSD/AI fixtures.
