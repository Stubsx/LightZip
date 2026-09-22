# Bundled runtime

Run `python3 scripts/bootstrap.py` from the repository root to download the
versioned Apple Silicon runtime asset and verify its SHA-256 before extraction.
`runtime.json` pins the asset; binaries and source archives are kept out of Git.

The asset includes 7-Zip, archive password recovery helpers, their licenses,
the complete corresponding John source, and 7-Zip source. Recovery build
instructions and the local Hashcat patch are in `recovery/README.md`.
Sparkle is resolved separately by SwiftPM using `Package.resolved`.

Use `python3 scripts/package-runtime.py VERSION` to prepare a replacement
runtime asset after rebuilding dependencies, then upload that asset to the
matching GitHub Release before publishing the changed manifest.
