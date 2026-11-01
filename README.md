<p align="center"><img src="Resources/AppIcon.png" width="160" alt="Murmur icon: a murmuration of starlings at dusk"></p>

# Murmur

> **Murmur**: from *murmuration*, a flock of starlings moving as one.

Murmur is a macOS MQTT explorer. It shows everything published on a broker as a live topic tree, so you can watch thousands of topics at once, inspect any message, and publish your own.

Written in pure SwiftUI, it is an independent native alternative to [MQTT Explorer](https://github.com/thomasnordquist/MQTT-Explorer) and has no third-party dependencies. The MQTT 3.1.1 and 5.0 protocol is implemented from scratch on Apple's Network framework.

## Features

### Connections
- Saved connection profiles, one connection per window
- MQTT over TCP or WebSocket, with or without TLS
- Custom CA certificate, client certificate (`.p12` / `.pfx`), ALPN, and an option to skip certificate validation
- Username and password, stored in the macOS Keychain
- MQTT 3.1.1 or 5.0, client ID, keep-alive, clean session / clean start, session expiry, last will
- Your own list of subscriptions with QoS (defaults: `#` and `$SYS/#`)
- Automatic reconnect with backoff

### Topic tree
- Hierarchical view with per-branch topic and message counts and a value preview
- Rows flash when they update
- Search across topic names and values
- Sort by arrival, name, message count or subtopic count
- Auto-expand levels from Off to All
- Keyboard navigation: arrow keys move and expand, space toggles, Delete deletes the topic
- Pause updates (incoming messages are buffered) and clear the tree

### Inspecting values
- Formatted, raw and diff views
- JSON shown as a collapsible tree that keeps key order
- Decoders: text, JSON, hex, Base64, Sparkplug B, and big- or little-endian integers and floats
- MQTT 5 properties: content type, response topic, correlation data, user properties and more
- Per-topic message history, with a small chart for numeric values
- Compare any two messages from the history
- Copy a value or save the payload to a file

### Topics
- Delete a retained message, or a whole branch (with confirmation)
- Copy the topic path; click any part of the path to jump to it

### Publishing
- Text, JSON, XML, hex or Base64 payloads, with validation and pretty-printing
- QoS 0/1/2, retain, MQTT 5 properties and user properties
- Load a payload from a file
- History of recently published messages; ⌘↩ publishes

### Charts
- Plot any numeric value, including fields inside JSON payloads
- Several charts side by side, each with its own time range, line style and colour
- Copy chart data as CSV

### Stats
- Message rate, topic count, bytes and packets in and out
- What the broker granted for each subscription
- Broker information from `$SYS`
- Connection log

### Settings
- Light, dark or system theme
- Relative or absolute timestamps
- How many messages to keep per topic and points per chart
- Update highlighting and delete confirmation

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (Swift 6 toolchain) to build

## Building

```sh
# Build an app bundle into build/Murmur.app
Scripts/build-app.sh release
open build/Murmur.app

# Or run straight from source
swift run Murmur
```

You can also open `Package.swift` in Xcode and run the `Murmur` scheme.

### Code signing

`Scripts/build-app.sh` picks a signing identity from your keychain automatically. It prefers **Developer ID Application**, then **Apple Development**, and falls back to ad-hoc signing. To choose one yourself:

```sh
MURMUR_SIGN_IDENTITY="Apple Development: you@example.com (ABCDE12345)" Scripts/build-app.sh
MURMUR_SIGN_IDENTITY=- Scripts/build-app.sh        # force ad-hoc signing
```

Signing with a certificate keeps the app's identity the same across rebuilds, so macOS remembers that Murmur may read its saved passwords. Ad-hoc builds get a new identity each time and trigger a Keychain prompt after every rebuild.

An **Apple Development** signature is for running Murmur on your own Mac. To give the app to other people, sign it with a **Developer ID Application** certificate (the script then also enables the hardened runtime and a secure timestamp) and notarize it with `xcrun notarytool`.

## Versioning

Versions come from git; there is no version number to edit by hand.

| | Source | Example |
| --- | --- | --- |
| Version | Latest tag `vX.Y.Z` | `1.0.0` |
| Build number | Number of commits | `42` |
| Full version | `git describe` | `1.0.0+3.g1a2b3c4.dirty` |

A build made exactly at a release tag is plain `1.0.0`. Later commits add how far past the tag you are and which commit it is (`+3.g1a2b3c4`), and uncommitted changes add `.dirty`. The version appears in **Murmur › About Murmur** and in the Stats panel. `Scripts/version.sh` prints the current values.

To release, run the release script from a clean working tree:

```sh
Scripts/release.sh patch    # 1.0.0 → 1.0.1
Scripts/release.sh minor    # 1.0.0 → 1.1.0
Scripts/release.sh major    # 1.0.0 → 2.0.0
Scripts/release.sh 1.4.0    # explicit version
```

It runs the tests, creates an annotated tag, and prints the command to push it. It never pushes anything itself.

## Trying it out without a broker

The package includes `DemoBroker`, a small local MQTT broker. With `--simulate` it publishes fake smart-home sensors, JSON payloads, binary floats and `$SYS` statistics:

```sh
swift run DemoBroker --port 1883 --simulate
open build/Murmur.app --args --connect mqtt://localhost:1883
```

`--connect` accepts `mqtt://`, `mqtts://`, `ws://` and `wss://` URLs and connects the first window when the app launches.

## Tests

```sh
swift test
```

The tests cover the packet codec, payload decoders, Sparkplug B, the diff, the topic tree, profile storage and Keychain handling. They also run the client end to end, over real sockets, against an in-process broker: QoS 0/1/2 in both directions, retained messages, MQTT 3.1.1 and 5.0, refused connections and reconnects. No network access is needed.

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/MurmurKit` | UI-free core: MQTT protocol and client, topic tree, decoders, connection profiles, Keychain storage |
| `Sources/Murmur` | The SwiftUI app |
| `Sources/DemoBroker` | Local test broker |
| `Tests/MurmurKitTests` | Unit and integration tests |
| `Scripts/build-app.sh` | Builds and signs `Murmur.app` |
| `Scripts/version.sh` | Derives the version from git |
| `Scripts/release.sh` | Tags a new release |
| `Scripts/make-icon.sh` | Regenerates the app icon from `Scripts/make-icon.swift` |
| `Resources/` | App icon (`.icns` and a 1024 px PNG) |

## Known limitations

- Client certificates must be PKCS#12 (`.p12` / `.pfx`). Separate PEM certificate and key files are not supported.
- WebSocket and TLS connections have not yet been tested against a public broker.

## Acknowledgements

Murmur's feature set and workflow follow [MQTT Explorer](https://github.com/thomasnordquist/MQTT-Explorer) by Thomas Nordquist. Murmur is an independent native alternative and shares no code with it.

## License

Murmur is released under the [MIT License](LICENSE).
