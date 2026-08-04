# Kontinuity

An iPad client for [Komga](https://komga.org/), focused on reading manga and comics
(CBZ) and on getting read-position sync right.

No paywalls, no feature gates, no analytics, no tracking, no obfuscation. Built for
one person's actual reading habits; shared because there's no reason not to.

> **Status: early.** Connects to a Komga server and browses it. Enter an address plus
> either your Komga login (which mints a device API key and discards the password) or
> an existing API key, then browse libraries, series and books with covers, metadata
> and read state — including Keep Reading and On Deck. Reading, sync and downloads
> are not built yet.

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
make test-unit         # the CI gate — hermetic, no server needed
make test-ui           # XCUITest — boots a simulator, drives the app
make test-all          # both suites
make format            # rewrite sources
make lint              # strict — warnings fail
```

### UI tests

`make test-ui` needs no server. The app serves itself a canned library when
launched with `-UITestMode connected`: an in-memory store, a stub Komga service,
and a throwaway Keychain, all compiled out of Release builds. `-UITestMode fresh`
starts with no server, for the connect screen.

Accessibility identifiers and the fixture ids live in `KontinuityCore`, because a
UI test bundle doesn't link the app it drives — sharing them makes a rename a
compile error instead of a CI timeout.

### Testing against a real Komga

`make test-unit` never touches the network. To also run the tests that talk to a
live server, point `Makefile.local` at one (copy `Makefile.local.example`) and:

```sh
make komga-up          # start a local Komga in docker
make komga-check       # verify it's reachable and the credentials work
make komga-address     # what to type on the connect screen
make test-integration  # unit tests + the live-server suite
make komga-stop
```

The live suite skips itself when `KOMGA_URL`/`KOMGA_API_KEY` are unset, so CI and a
fresh clone stay green without Docker. Credentials live only in `Makefile.local`,
which is gitignored.

A disposable instance to point this at:
[komga-docker](https://github.com/gotson/komga#docker) — a single container bind-mounting
a config and a library directory does the job.

Deploying to a real iPad (paid Apple Developer Program membership — profiles last a year):

```sh
cp Makefile.local.example Makefile.local   # set DEVICE_ID
make deploy
```

Or `make ipa` for an unsigned build to import into SideStore/AltStore, which refresh
themselves.

## Layout

| Path | What |
|---|---|
| `Kontinuity/` | App target — SwiftUI views, iPad-first |
| `KontinuityCore/` | Local SPM package: Komga client, models, sync engine, page-layout math. No UIKit, fully unit-testable. |
| `KontinuityTests/` | Swift Testing suite — unit tests plus an opt-in live-server suite |
| `KontinuityUITests/` | XCUITest suite, driven against the built-in stub server |
| `Config/Info.plist` | Only the keys that can't be build settings — ATS local networking, local network usage string |

The hard parts (sync conflict resolution, band layout) live in `KontinuityCore` on
purpose: they're testable without a simulator or a live server.

iPhone is a supported device family so the app installs there, but the UI is designed
for iPad. Compact-width adaptation comes later.

## License

MIT. See [LICENSE](LICENSE).
