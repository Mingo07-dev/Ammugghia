## What this changes

<!-- One logical change. What does it scan, delete, change or fix? -->

## What it can delete or modify

<!-- Paths, commands or settings this change can touch. "Nothing" is a fine answer. -->

## Checklist

- [ ] `swift build -c release` has zero warnings
- [ ] `Ammugghia --selftest` passes (new area touched → new cases in `SelfTest.swift`)
- [ ] `Tools/check-localization.sh` passes (new user-facing text → English translation)
- [ ] New cleanup items explain their `consequence` and show their exact paths
- [ ] No network access, no new dependencies, nothing risky preselected
- [ ] Tried in the app (`./build.sh --install`)

## How I tested it

<!-- macOS version, what you ran, what you saw. -->
