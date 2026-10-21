# Huebeat

A macOS app that listens to your Mac's audio and pulses Zigbee color bulbs to the beat, through a Sonoff USB Zigbee dongle (EFR32 / Ember). No Wi‑Fi gateway, no cloud.

- **Audio:** ScreenCaptureKit system audio → bass-band beat detection and an energy envelope (`AudioColorMapper.swift`).
- **Lights:** the app launches a small bundled Node helper (`Helper/huebeat-zigbee.cjs`, [zigbee-herdsman](https://github.com/Koenkk/zigbee-herdsman)) and streams colors to it over stdin. The helper sends to one bulb at a time as CIE xy, keeps only the latest color, and restores the bulbs' original state on Stop or Quit.

## Requirements

- macOS 26, Apple silicon
- Node.js (`brew install node`); the app finds Homebrew, `/usr/local`, Volta or your login-shell `node`
- A Sonoff dongle on `/dev/cu.usbserial-*` with the bulbs already paired

## Zigbee network

The network key, device database and coordinator backup live in `~/Library/Application Support/Huebeat/Zigbee` and are never committed. On first launch the app copies them from `~/.local/share/sonoff-zigbee`, where the pairing scripts left them. The helper refuses to start without all three files, so it can't form a new network and orphan the bulbs.

## Build

```sh
scripts/install.sh   # xcodegen + Release build + install to /Applications
```

Every build is signed with the Apple Development certificate (`Config/Signing.xcconfig`, team `W7TT249CUU`). The designated requirement is tied to the bundle ID and certificate, not a per-build hash, so macOS keeps the audio-capture permission across rebuilds. `Local.xcconfig` can override the identity and is gitignored.

## Why the lights update at ~4 Hz

Each bulb takes about 40–50 ms per command, and parallel unicasts overload the coordinator. Group broadcasts are capped by the Zigbee spec at about one per second. With four bulbs, one sweep takes about 200 ms, so the helper drops stale frames instead of queueing them.
