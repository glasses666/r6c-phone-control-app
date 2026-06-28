# R6C Phone Control

<img src="docs/media/r6c-phone-control-icon.png" alt="R6C Phone Control icon" width="128">

A small macOS app for controlling an Android phone that is attached to a remote
Linux host over SSH.

It wraps the pieces I kept using by hand: device status, embedded scrcpy H.264
video, tap/swipe input, text input, display controls, and EasyEUICC profile
switching.

![R6C Phone Control screenshot](docs/media/r6c-phone-control-screenshot.png)

![R6C Phone Control demo](docs/media/r6c-phone-control-demo.gif)

## What Works

- Add an SSH remote and pick a connected Android device.
- View the phone through an embedded scrcpy H.264 stream.
- Tap, drag, and use bounded two-finger horizontal trackpad swipes on the phone view.
- Send Android key events, text input, wake/sleep commands, and display reset/fast-mode commands.
- List and switch EasyEUICC profiles through the remote helper script.

## Setup

This repo does not include a server, private key, Android PIN, or web-control
token. Bring your own remote host with `adb`, SSH access, and the helper scripts
you want to call.

The app passes connection settings to the bundled scripts through environment
variables:

```sh
export R6C_SSH_HOST="user@example.com"
export R6C_SSH_PORT="22"
export R6C_SSH_KEY="$HOME/.ssh/id_ed25519"
export R6C_ANDROID_SERIAL="your-device-serial"
```

You can also add the remote from the app UI. The scripts fail closed if no
remote host is configured.

CLI profile readout:

```sh
Scripts/r6c-phone-control.sh profiles-json
```

## Build

```sh
Scripts/build-app.sh
open "dist/R6C Phone Control.app"
```

The package is SwiftPM-first and targets macOS 14 or newer.

## Notes

This is still a personal utility, not a polished general-purpose Android
management product. The code is public mostly so the workflow is easier to
inspect and reuse.
