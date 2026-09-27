# Roll Slash

Roll Slash is a privacy-focused iOS 26+ Camera Roll cleaner. Decisions and cache metadata stay local; Apple Photos may retrieve iCloud media and MapKit may reverse-geocode coordinates. The app groups the personal Photos library by month or location, records keep/delete-review decisions with undo and redo, and asks PhotoKit to delete only after a final review.

## Requirements

- Xcode 27
- iOS 26 or later
- XcodeGen 2.46 or later to regenerate the checked-in project

## Build

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project RollSlash.xcodeproj \
  -scheme RollSlash \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/RollSlashDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

The checked-in `RollSlash.xcodeproj` is generated from `project.yml`. Change the YAML first, then regenerate the project.

## Test

List destinations with `xcodebuild -showdestinations`, then run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project RollSlash.xcodeproj \
  -scheme RollSlash \
  -destination 'platform=iOS Simulator,id=<SIMULATOR-UDID>' \
  -derivedDataPath /tmp/RollSlashDerivedData \
  CODE_SIGNING_ALLOWED=NO
```

UI tests launch with `--ui-testing`, which selects an in-memory store and deterministic demo library. Normal launches always use PhotoKit and persistent SwiftData storage.

## Device validation

Before release, validate Full and Limited Photos access, iCloud-only media, Live Photos, video playback, external library changes, and Apple’s deletion confirmation on a disposable iOS 26+ device library. Verify that `com.rollslash.app` is available in the release Apple Developer account.
