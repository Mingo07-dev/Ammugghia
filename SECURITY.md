# Security policy

Ammugghia deletes files. A bug that makes it delete, move or change something it shouldn't is
a security issue, even if no attacker is involved.

## Reporting a vulnerability

Please report privately through GitHub:
**[Report a vulnerability](https://github.com/Mingo07-dev/Ammugghia/security/advisories/new)**
(Security tab → *Report a vulnerability*). Do not open a public issue for it.

Include, if you can:
- the Ammugghia version (*About* or `Ammugghia.app/Contents/Info.plist`) and macOS version;
- the exact path or item involved and what happened;
- the output of `Ammugghia --selftest`;
- the relevant lines from `~/Library/Logs/Ammugghia` (remove anything you consider private).

You'll get an answer within a few days. Fixes are released as a new signed and notarized
version, and the advisory credits you unless you prefer otherwise. Reports in Italian are
welcome.

## In scope

- Deleting or moving a path outside the documented areas, or inside a protected one (Photos
  library, iCloud Drive, Keychains, Mail, Messages, your documents…).
- Bypassing a safety check: allowlist and protected list, file identity (device + inode),
  build-artifact manifest check, the `/var/folders` age rule, exclusions, running-app check.
- A startup-item change that affects a service other than the one shown, or a `com.apple.*`
  service.
- Command injection through a path, label or file name passed to an external tool or to the
  administrator prompt.
- Any network connection made by the app.

## Supported versions

Only the latest release receives fixes. Update with `brew upgrade --cask ammugghia` or from
the [Releases page](https://github.com/Mingo07-dev/Ammugghia/releases/latest).
