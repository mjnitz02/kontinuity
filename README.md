# Kontinuity

An iPad client for [Komga](https://komga.org/), focused on reading manga and comics
(CBZ) and on getting read-position sync right.

No paywalls, no feature gates, no analytics, no tracking, no obfuscation. Built for
one person's actual reading habits; shared because there's no reason not to.

> **Status: early.** Connects to a Komga server and authenticates — enter an address
> plus either your Komga login (which mints a device API key and discards the password)
> or an existing API key. Browsing, reading, sync and downloads are not built yet.

## What it will do

- Browse a Komga library with a Komga-ish feel on device
- Download the unread volumes of a series in one gesture, for offline reading
- Read CBZ page images well — including on an external display (Viture-class glasses),
  where a portrait manga page is walked down in readable bands rather than shrunk to
  fit a 16:9 panel
- Sync read position back to Komga reliably, including offline catch-up

## What it won't do

EPUB, PDF, multi-server management, admin tooling, metadata editing, tvOS/macOS,
App Store distribution. Scope is deliberately small.

If you want a comprehensive, polished, multi-platform Komga client, use
[KMReader](https://github.com/everpcpc/KMReader) — it's good, and it does all of the
above.

## Requirements

- Komga **1.25.0** or later
- Xcode 26+, iPadOS 26+
- An API key from your Komga account (Account Settings → API Keys)

## Development

```sh
make install-tools     # swiftlint, swiftformat, xcbeautify
make install-hooks     # pre-commit: format-check + lint
make build             # build for the iPad simulator
make test-unit         # the CI gate
make format            # rewrite sources
make lint              # strict — warnings fail
```

Deploying to a real iPad with a free Apple ID:

```sh
cp Makefile.local.example Makefile.local   # set DEVICE_ID
make deploy                                # re-run weekly; free profiles last 7 days
```

Or `make ipa` for an unsigned build to import into SideStore/AltStore, which refresh
themselves.

## Layout

| Path | What |
|---|---|
| `Kontinuity/` | App target — SwiftUI views, iPad-first |
| `KontinuityCore/` | Local SPM package: Komga client, models, sync engine, page-layout math. No UIKit, fully unit-testable. |
| `KontinuityTests/` | Swift Testing suite |
| `Config/Info.plist` | Only the keys that can't be build settings — ATS local networking, local network usage string |

The hard parts (sync conflict resolution, band layout) live in `KontinuityCore` on
purpose: they're testable without a simulator or a live server.

iPhone is a supported device family so the app installs there, but the UI is designed
for iPad. Compact-width adaptation comes later.

## License

MIT. See [LICENSE](LICENSE).
