# ArchiveBurner

A native macOS app for burning long-term archive discs. It turns a folder into a verified **UDF 2.50 Blu-ray disc**: it checks the size, cleans macOS metadata, writes a SHA-256 checksum file, builds the image, burns it and verifies the result.

## Features

- **Full pipeline:** size check → optional metadata cleanup → checksums → UDF 2.50 image → burn → verify. Any step can be switched off (for example, to burn an existing image).
- **Size check:** compares the source with the free space on the inserted blank disc, or with the selected disc type's limit (BD-R DL: 46.0 GiB). It warns before going over.
- **Disc detection:** when you insert a blank disc, the Media setting switches to match it: BD-R 25, BD-R DL 50 or BD-XL 100 (told apart by capacity), or BD-RE. You can still change it by hand.
- **Metadata cleanup (optional, on by default):** `dot_clean -m` and removal of `.DS_Store` files. This modifies the source folder.
- **Portable checksums:** `checksums.sha256` is written in `shasum` format and ends up on the disc. Any machine can check it with `shasum -a 256 -c checksums.sha256`, without this app.
- **Burning:** uses Apple's DiscRecording framework (the engine behind `drutil`) and shows drive and disc status. Default speed is 4x. The Mac is kept awake during the burn (like `caffeinate -i`).
- **Verification modes:** each check reads the whole disc once, so you choose:
  - **Checksums only** (default): re-hashes every file on the mounted disc. This is the end-to-end check: it reads through the file system, the same way a restore would.
  - **Drive verify only:** the drive compares the disc with the image, like `drutil`'s default.
  - **Both** or **None**.
- **Verify a Disc…:** check any mounted disc or folder against its `checksums.sha256` at any time.
- Live progress with time remaining, a log window, and log files in `~/Library/Logs/ArchiveBurner/`. Sends a notification when a run finishes.

## Requirements

- macOS 14 or later
- An internal or USB Blu-ray burner. Many slim USB drives need both USB plugs connected to burn reliably.
- Building from source needs Xcode 16+ or a Swift 6 toolchain.

## Install

1. Download `ArchiveBurner-<version>.zip` from [Releases](https://github.com/zori7/burncraft-mac/releases).
2. Unzip it. Double-click the zip in Finder; Safari usually unzips downloads automatically.
3. Drag **ArchiveBurner.app** into your **Applications** folder.
4. Open it. The app isn't notarized by Apple, so the first launch is blocked with a warning. To allow it:
   - **macOS 15 and later:** try to open the app once, then go to **System Settings → Privacy & Security**, scroll down to the message about ArchiveBurner, click **Open Anyway** and confirm.
   - **macOS 14:** right-click (or Control-click) the app, choose **Open**, then click **Open** in the dialog.
   - **If macOS says the app "is damaged"**, or neither option works, remove the download quarantine in Terminal:
     ```sh
     xattr -dr com.apple.quarantine /Applications/ArchiveBurner.app
     ```

   You only need to do this once. After that the app opens normally.

The app is a universal build that runs on both Apple Silicon and Intel Macs.

## Build from source

```sh
git clone https://github.com/zori7/burncraft-mac.git
cd burncraft-mac
./scripts/build-app.sh        # → build/ArchiveBurner.app + build/ArchiveBurner-<version>.zip
open build/ArchiveBurner.app
```

The script builds a universal binary (arm64 + x86_64), signs it ad hoc, and packages it with `ditto` into the zip used for GitHub releases.

For development:

```sh
swift build
swift test
```

## Usage

1. Choose (or drop) the **source folder**.
2. Check the **volume name** (default `MEDIA_ARCHIVE_YYYYMMDD`) and choose where the **image is saved**. For a 50 GB disc you need about 50 GB free there.
3. Choose the **media**, **speed** and **verification mode**.
4. Press **Start**. The app asks only when something needs a decision: the source is over the size limit, an image with that name already exists (use it or replace it), or the inserted disc doesn't match the Media setting. Otherwise the run continues unattended through the burn.
5. Insert a blank disc when asked. After the burn, the disc mounts and is verified (if the mode includes checksums).
6. When it's done, keep or delete the image.

## Simulated drive (development)

To try the whole flow without a burner or blank discs, turn on the hidden simulated drive:

```sh
defaults write com.tapsiom.archiveburner SimulatedDrive -bool YES   # stays on
open build/ArchiveBurner.app --args -SimulatedDrive YES              # this launch only
defaults delete com.tapsiom.archiveburner SimulatedDrive            # turn off
```

The drive shows up as **Simulated BD Burner** with an orange **SIMULATED** badge, and the log of each run says so. It starts with a blank BD-R DL. A "burn" shows progress for about 10 seconds (plus 5 seconds when drive verify is on), then mounts the ISO read-only, so the Verify step checks it the same way it would check a burned disc. After that the disc counts as burned: press **Eject / New Disc** to unmount it and insert a new blank one. Cancelling during the burn leaves the disc unusable, as with a real drive.

Nothing is written to a real disc in this mode.

## Project layout

```
app.config              App name, organization and bundle id (single source of truth)
Package.swift           Targets: BurnCore (library), App (SwiftUI), BurnCoreTests
Sources/BurnCore/
  Job/                  ArchiveJob, VerificationMode
  Media/                MediaType: disc types and their limits
  Imaging/              ImageFormat protocol, UDFImageFormat (hdiutil)
  Checksums/            Generator and verifier (shasum-compatible)
  Steps/                PipelineStep protocol, one file per step, PipelineRunner
  Burning/              DiscBurning protocol, DiscRecordingBurner, SimulatedBurner
  System/               Process runner, mount watcher, sleep prevention, logging
Sources/App/            SwiftUI shell (AppModel and views)
Tests/BurnCoreTests/    Each file starts with a comment describing what it covers
scripts/                gen-config.sh, build-app.sh
```

## Extending

The app is built around small registries and protocols, so new features are additions rather than rewrites:

- **New disc type** (DVD, CD, …): add an entry to `MediaType.all` in `Sources/BurnCore/Media/MediaType.swift`. Each entry has its capacity, recommended limit, DiscRecording media types, allowed image formats, 1x speed and speed choices.
- **New image format:** write a type that conforms to `ImageFormat` and add it to `ImageFormats.all`. Then list its `id` in the media types that support it.
- **New checksum algorithm:** add a case to `ChecksumAlgorithm`.
- **New pipeline step:** conform to `PipelineStep` and add it to `PipelineRunner.standardSteps()`.
- **Different burn engine:** conform to `DiscBurning`.

## Renaming / forking

All naming is in `app.config`:

```sh
APP_NAME="ArchiveBurner"
ORG_ID="tapsiom"
BUNDLE_ID="com.${ORG_ID}.archiveburner"   # derived from the two above
```

Edit it and run `./scripts/build-app.sh`. This regenerates `Sources/BurnCore/AppConfig.swift` and the app's `Info.plist`. The code reads names only through `AppInfo`.

## Tests

```sh
swift test                                   # everything (about 1 s)
swift test --skip ImageIntegrationTests      # skip the test that uses hdiutil/diskutil
```

The tests cover checksum output against `shasum` byte for byte, detection of changed and missing files, size limits, cleanup, `hdiutil` arguments, a real UDF image that is built, mounted and verified, and the whole pipeline with a fake burner: verification modes, skipped steps, failures, cancelling and confirmations. Burning a physical disc is tested by hand.

## Contributing

Issues and pull requests are welcome. Please run `swift test` before you submit. Reports of burns with specific drives and media (successful or not) are especially useful.

## License

[MIT](LICENSE)
