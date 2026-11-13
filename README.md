# Volume Mixer for macOS

A small menu bar app that brings a Windows-style volume mixer to macOS: one volume slider per app that is playing sound.

No audio driver or kernel extension is installed. The app relies on the Core Audio process taps that Apple introduced in macOS 14.2.

## Features

- One slider and one mute button for each app currently playing audio
- Master volume slider for the current output device
- Helper processes (browser renderers, WebKit, etc.) are grouped under the app they belong to
- Volumes are remembered per app and re-applied the next time the app plays sound
- Optional launch at login
- Lives in the menu bar only (no Dock icon)
- Interface in English, or in French on French systems

## Requirements

- macOS 14.2 or later
- Apple silicon or Intel Mac (universal binary)

## Install

1. Download `VolumeMixer.dmg` from the [latest release](../../releases/latest).
2. Open it and drag **VolumeMixer** onto the **Applications** shortcut.
3. Launch **VolumeMixer** from Applications. A sliders icon appears in the menu bar.

### First launch

The app is not signed with an Apple developer certificate and is not notarized, so macOS blocks it the first time:

1. Try to open the app once, and dismiss the warning.
2. Open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway**.

Alternatively, remove the quarantine flag from a terminal:

```bash
xattr -dr com.apple.quarantine /Applications/VolumeMixer.app
```

### Audio permission

The first time you move a slider away from 100%, macOS asks for permission to record system audio. This permission is required: the app has to capture an app's audio in order to play it back at a different volume. Audio is processed in memory only; nothing is recorded, stored, or sent anywhere.

## How it works

For each app whose volume is not 100%, Volume Mixer:

1. creates a Core Audio process tap on the app's audio processes, which mutes them at the source;
2. creates a private aggregate device combining that tap with the current output device;
3. copies the tapped audio to the output device, multiplied by the gain you chose.

Apps left at 100% are not touched at all, and taps only exist while the app is actually playing.

## Build from source

Requires Xcode or the Xcode command line tools (Swift 5.9 or later).

```bash
./build.sh
```

This produces `build/VolumeMixer.app` and the `build/VolumeMixer.dmg` installer.

## Limitations

- Sliders go from 0 to 100%; there is no boost above an app's original volume.
- Audio that goes through a tap is played back with a small added latency.
- macOS system sounds (alerts, UI sounds) are not listed and always follow the master volume.
- Because the build is ad-hoc signed, macOS may ask for the audio permission again after an update.
- Developed and tested on a single Mac so far. Bug reports are welcome.

## Uninstall

Untick **Launch at login** in the app, quit it, then delete `VolumeMixer.app` from Applications. Optionally remove the saved volumes:

```bash
defaults delete local.volumemixer
```

## License

[MIT](LICENSE)
