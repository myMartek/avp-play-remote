# AVP Play Remote

A visionOS window app that remote-controls [AVP Play](https://github.com/myMartek/avp-play) on your Mac while you
wear the Apple Vision Pro: browse your games, see what is installed and what can be updated, install, update or
download games, and follow, cancel or resume jobs. The Mac still does all the work (download, build, sign, install);
the headset only needs to be in the same network.

## How it connects

- AVP Play on the Mac (Settings › Remote control) listens on TCP port 47811 and shows itself in the local network
  via Bonjour (`_avpplay._tcp`).
- The app finds Macs by itself. The first time, you pair once with the six-digit code AVP Play shows; after that the
  app connects automatically – to the Mac you used last, or to any other paired Mac that is in the network. With
  several paired Macs you switch in the toolbar menu or on the *Mac* tab.
- If Bonjour does not work in a network, enter the Mac's IP address (shown in AVP Play's settings) on the *Mac* tab.
- Everything is encrypted with TLS 1.2 and a pre-shared key: pairing uses port 47812 and a key derived from the code;
  each paired headset then gets its own random 256-bit key, stored in the keychain on both sides. Removing the headset
  in AVP Play's settings revokes it.

## Build

Requirements: Xcode 26 or newer, visionOS 26 SDK, [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you change
`project.yml`.

```sh
xcodegen generate            # only after editing project.yml
open AVPPlayRemote.xcodeproj  # set your team under Signing & Capabilities, run on the Vision Pro
```

From the command line:

```sh
xcodebuild -project AVPPlayRemote.xcodeproj -scheme AVPPlayRemote \
  -destination 'generic/platform=visionOS' -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAM> build
```

## The shared protocol

`Sources/Shared/RemoteProtocol.swift` is a verbatim copy of `core/Sources/AVPPlayCore/RemoteProtocol.swift` in
AVP Play. Change it there, then copy it over:

```sh
tools/sync-protocol.sh <path-to-avp-play-checkout>          # copy
tools/sync-protocol.sh --check <path-to-avp-play-checkout>  # compare only
```

`RemoteWire.protocolVersion` goes up whenever a change would break an older counterpart; both sides refuse a
different version with a message.

## Testing without a headset

`tools/smoke/main.swift` talks to AVP Play like the app does – Bonjour, a wrong code, pairing, a foreign key, the
initial state, requests and a cover:

```sh
swiftc -O Sources/Shared/RemoteProtocol.swift tools/smoke/main.swift -o build/smoke
build/smoke <code> [host] [game-id]
```

It pairs as its own remote ("Smoke test"), which you can remove in AVP Play afterwards. It only sends *install* for a
game that AVP Play refuses anyway, unless you name a game id.

Debug builds understand a few launch arguments for the simulator, where nothing can be tapped from a script:
`-AVPRemoteTab games|updates|jobs|mac`, `-AVPRemoteGame <id>`, `-AVPRemoteConnect <host>` and
`-AVPRemotePairCode <code>`. A debug build of AVP Play takes a fixed pairing code from `AVPPLAY_REMOTE_CODE`.

## Store screenshots

They come from the demo mode in the simulator (3840×2160): launch a debug build with
`-AVPRemoteDemo YES -AVPRemoteTab games|updates|jobs|settings`, `-AVPRemoteGame neonrhythm`,
`-AVPRemoteJob demo-starfall-job` and `-AppleLanguages "(de)"` or `"(en)"`, then `xcrun simctl io <device> screenshot`.
The App Store texts are in `AppStore/`.

## Licence

MIT, see [LICENSE](LICENSE).
