# Murmur

Murmur is a native macOS MQTT explorer. It is a pure SwiftUI re-implementation of
[MQTT Explorer](https://github.com/thomasnordquist/MQTT-Explorer) and has **no third-party dependencies**.
The MQTT protocol is implemented from scratch on Network.framework.

## Build, run, test

```sh
swift build                                   # build everything
swift test                                    # unit + end-to-end tests (in-process fake broker, no network needed)
swift run Murmur                              # run the app without a bundle
Scripts/build-app.sh [debug|release]          # produce build/Murmur.app, signed (see below)
swift run DemoBroker --port 1883 --simulate   # local broker that publishes demo data
open build/Murmur.app --args --connect mqtt://localhost:1883   # auto-connect on launch
```

`build-app.sh` signs with `$MURMUR_SIGN_IDENTITY` if set (`-` means ad-hoc). Otherwise it uses the first "Developer ID Application" identity, then "Apple Development", then ad-hoc. Builds signed with a certificate keep a stable designated requirement, so Keychain access granted to Murmur survives rebuilds. Ad-hoc builds re-prompt every time.

You can also open `Package.swift` in Xcode. The project requires macOS 14 or later and Swift tools 6.0, compiled in Swift 5 language mode.

## Versioning

Versions are derived from git by `Scripts/version.sh`; never hard-code a version number.
- Marketing version: the latest `vX.Y.Z` tag. Build number: `git rev-list --count HEAD`. Full version: `X.Y.Z[+N.g<sha>][.dirty]`.
- `build-app.sh` writes these into Info.plist (`CFBundleShortVersionString`, `CFBundleVersion`, plus the custom keys `MurmurFullVersion` and `MurmurCommit`). The app reads them through `App/AppVersion.swift`, which falls back to "dev" when there is no bundle (`swift run`).
- `Scripts/release.sh patch|minor|major|X.Y.Z` requires a clean tree and passing tests, then creates an annotated tag. It doesn't push.

## Layout

- `Sources/MurmurKit/`: the UI-free core. All protocol and model logic lives here and is covered by tests.
  - `MQTT/MQTTPacket.swift`: packet codec for MQTT 3.1.1 and 5.0, including v5 properties. `PacketCodec.extractPacket` parses a stream buffer incrementally.
  - `MQTT/MQTTClient.swift`: the client state machine. It runs on a private serial queue and calls back on the main queue. It handles QoS 0/1/2 in both directions, keep-alive, auto-reconnect with backoff, and v5 topic aliases. Incoming messages are delivered in **batches** every 50 ms.
  - `MQTT/MQTTTransport.swift`: NWConnection setup for TCP/TLS/WebSocket (`mqtt` subprotocol), custom CA anchors, PKCS#12 client identity, ALPN, and a "validate certificate" switch.
  - `Model/TopicTree.swift`: `TopicTree` / `TopicNode` (reference types for speed), per-topic history, counters, and `visibleRows(options:)`. That function flattens the tree into `[TopicRow]` and applies expansion, auto-expand, sort order and search.
  - `Model/ConnectionProfile.swift`: saved connections, stored as JSON at `~/Library/Application Support/Murmur/connections.json` with mode 0600. Decoding is tolerant, so new fields need a default. A new field must also be added to the hand-written `encode(to:)`.
  - `Model/CredentialStore.swift`: the broker password and .p12 passphrase are stored in the Keychain (generic passwords, service `app.murmur.Murmur`, account `<profile-uuid>.password` / `.certificatePassword`). They are **never** encoded to JSON. `ProfileStore` loads and saves them, migrates plaintext passwords from older files, and deletes the secrets of removed profiles. Tests use `InMemoryCredentialStore`.
  - `Decoding/`: order-preserving `JSONValue` parser, `PayloadDecoder` (auto/string/JSON/hex/base64/Sparkplug B/binary ints and floats), a schema-less protobuf reader, a Sparkplug B decoder, and the LCS line diff `TextDiff`.
- `Sources/Murmur/`: the SwiftUI app.
  - `App/Session.swift`: `MQTTSession` (`@Observable`, `@MainActor`), with one per window. It owns the client and tree, the paused buffer, charts, the publish draft and history, and selection.
  - `Views/`: `ContentView` (connection screen or explorer), `Connection/`, `Tree/`, `Inspector/` (Topic, Value, History, Publish, Stats), `Charts/`, `SettingsView`.
- `Sources/DemoBroker/`: a minimal broker used for manual testing.
- `Tests/MurmurKitTests/`: codec, decoding, tree and client integration tests. `FakeBroker.swift` is a tiny broker on an ephemeral localhost port.

## Conventions and gotchas

- `TopicTree` is not observable. The UI re-renders through `MQTTSession.revision` (bumped when rows rebuild, throttled to about 150 ms) and `selectionRevision` (bumped when the selected node changes). A view that reads `session.tree` or `TopicNode` properties must also read one of these counters, or it will not update.
- An empty payload removes a topic's value and prunes empty ancestors, the same way MQTT Explorer treats deleted retained messages. "Delete" publishes an empty retained message.
- The root node has id `""`. A topic beginning with `/` creates a first-level node whose name is the empty string; its id is also `""`, and `node(for: "")` returns that node.
- Settings use `@AppStorage`. The keys are in `App/AppSettings.swift` (`SettingsKey`).
- Debug-only development aids (`#if DEBUG`): `MURMUR_SNAPSHOT=/path/prefix` writes PNGs of the app's own windows every 4 s, and `MURMUR_DEBUG_SELECT=<topic>` / `MURMUR_DEBUG_CHART=<json.path>` select a topic and open a chart after `--connect`. Use these to verify UI changes when screen capture isn't available.
- Client certificates are supported only as PKCS#12 (`.p12`/`.pfx`). PEM cert+key pairs would require writing to the keychain.
- Keep `MurmurKit` free of SwiftUI/AppKit so it stays testable with `swift test`.
- Run `swift test` after changing protocol, tree or decoding code. The integration tests exercise real sockets.
