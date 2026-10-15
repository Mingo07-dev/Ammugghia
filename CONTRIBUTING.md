# Contributing to Ammugghia

Thanks for helping! Issues and pull requests are welcome, in English or Italian.
Questions and ideas are best in [Discussions](https://github.com/Mingo07-dev/Ammugghia/discussions).

Ammugghia deletes files, so every change is judged first by one question: *could this delete
something it shouldn't?* When in doubt, the code refuses.

## Build and test

```bash
swift build -c release                     # must stay at zero warnings
"$(swift build -c release --show-bin-path)/Ammugghia" --selftest   # must pass
Tools/check-localization.sh                # every string must have an English translation
./build.sh --install                       # try the app
```

There is no XCTest suite: `--selftest` *is* the test suite (`Sources/Ammugghia/Core/SelfTest.swift`).
CI runs all three checks on every push and pull request.

## Suggesting a cleanup target

Open an issue with the *Feature request* template and include:
1. the exact path and the program that owns it;
2. what happens after it is deleted: rebuilt automatically, downloaded again, or lost;
3. whether an official command should be used instead of deleting files
   (`simctl`, `brew cleanup`, `docker … prune`, `ollama rm`…).

An item that can't explain its consequence won't be added.

## Rules for code changes

- **Every deletion goes through `PathGuard`.** A path must be in `allowedPrefixes` *and*
  outside the protected lists. Adding a scanner never widens permissions; touching a new
  area needs new cases in `SelfTest.swift` (both "must refuse" and "must allow").
- **Never** add Documents, Desktop, Downloads, Movies or `/Library/Preferences` to the
  allowlist; **never** implement `docker volume prune` or `--volumes`.
- Nothing risky is preselected, and an item with a warning is never preselected.
- Prefer the official tool to deleting files.
- No network access and no third-party dependencies.
- User-facing text: Italian is the source language. Use `String(localized:)` or a SwiftUI
  literal, add the English translation to `Resources/Localization/en.lproj/Localizable.strings`,
  write whole sentences (no fragments glued together) and never base logic on displayed text.
- Comments explain *why*, not *what*.

## Commits and pull requests

- [Conventional Commits](https://www.conventionalcommits.org/) in English
  (`feat(scan): …`, `fix(i18n): …`, `docs: …`).
- One logical change per pull request, with a short description of what it deletes or
  touches and how you tested it.

By contributing you agree that your work is released under the [MIT License](LICENSE).
