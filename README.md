# AVP Play Remote

A visionOS window app that remote-controls [AVP Play](https://github.com/myMartek/avp-play) on your Mac while you
wear the Apple Vision Pro: browse your games, see what is installed and what can be updated, install, update or
download games, and follow, cancel or resume jobs. The Mac still does all the work (download, build, sign, install);
the headset only needs to be in the same network.

For Half-Life: Alyx it also browses the Steam Workshop: open an item and *Load into AVP Play* sends it to the Mac,
which fetches it with its Steam sign-in and copies it to the game on the Vision Pro (Remote 1.1 with AVP Play 1.10.10
or newer).

## Install

The app is not in the App Store. AVP Play installs it for you (any version after 1.5.3): open *Remote Control* in its
sidebar, or the *AVP Play Remote* tile under *Games*, and click *Install*. AVP Play downloads the source code of the
newest release from this repository, builds it with your own Apple team (like the games) and installs it on the Vision
Pro. With a free Apple team the app counts towards the three apps such a team may have on the device, and it has to
be installed again every seven days, like the games.

## Installing games without a Mac (experimental)

**Experimental:** this is new. Not every game has been tried this way, and something may not work; installing from
the Mac stays the tested way, and a game installed on the headset can be installed again from the Mac at any time.

Since version 1.2 the app can also do the work itself: with *This Headset (without a Mac)* in the Mac menu it
downloads a game from Meta, builds its app, signs it and installs it – on the Vision Pro, while the Mac is off. The
pages are the same as with a Mac.

What you need:

- **A paid Apple Developer Program membership.** The app reaches the headset's own installation service through a
  small loopback VPN of its own (a Network Extension), which a free team cannot have.
- **AVP Play 1.10.16 or newer on a Mac, once.** On the page *AVP Play Remote*, switch on *Installing Games Without a
  Mac (Experimental)* and install the app again. AVP Play then builds this part into it and hands over what only a Mac can provide:
  the runtime of the toolchain, the recipes of the games, your Meta library and – each only if you say so – your
  Apple team key and your Meta sign-in.
- **A team key for the App Store Connect API** (role *App Manager*). Enter it in AVP Play, or in the app under
  *Setup*, where a short guide says how to create one. With it the headset gets a certificate, an app identifier
  and a profile per game from Apple itself.
- **Pairing with the headset**, in the app under *Setup*: open Settings › General › Remote Devices on the headset,
  tap *Pair* and enter the code the headset shows.

What goes where:

- The Meta sign-in stays in the app's keychain on your headset and is sent to Meta only, with the same rules as on
  the Mac: ownership is checked before anything is downloaded.
- The team key stays in the app and is sent to Apple only. New app identifiers are created through the interface
  Xcode itself uses for that (not a documented one), because only there a game gets the memory entitlements it needs;
  everything else uses the App Store Connect API.
- Nothing goes to anyone else. Ratings and notes come from AVP Play's catalogue as before; only game IDs are sent
  there.

Limits: games from Steam and games that are not an Android app are installed from the Mac only; saved games are
copied to the Mac by AVP Play, not by the app; and after a new toolchain AVP Play has to build the app again (it
says so), because the translator in it belongs to one toolchain.

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

### The headset part

`project-standalone.yml` adds the part that installs games on the headset to `project.yml`: the sources under
`Standalone/`, a packet tunnel extension and three libraries under `Standalone/Vendor/lib/xros`, which are built, not
checked in:

```sh
tools/build-engine.sh                       # the device library (jkcoxson/idevice) and the signer
tools/build-engine.sh translator <folder>   # the translator, from a Klepton toolchain
xcodebuild -project AVPPlayRemoteStandalone.xcodeproj -scheme AVPPlayRemote -destination 'generic/platform=visionOS' \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=<team> AVPPLAY_REMOTE_BUNDLE_ID=<bundle id> build
```

The first two are the same for every user and hang on each release as `avp-play-remote-headset-libs-<version>.zip`
(`Standalone/Vendor/libs.json` names its checksum; AVP Play checks it). The translator belongs to exactly one
toolchain, so AVP Play builds it on your Mac from the toolchain installed there and passes its name as
`AVPPLAY_TRANSLATOR_TOOLCHAIN`. `Standalone/Shared/` holds files of AVP Play unchanged (`tools/sync-meta.sh` copies
and checks them). Licences of what the libraries contain: [THIRD-PARTY.md](THIRD-PARTY.md).

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
