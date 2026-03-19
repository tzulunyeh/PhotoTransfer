# PhotoTransfer

Transfer photos and videos from iPhone to Mac over USB at full speed.

## Why

Existing options all have drawbacks:

| Method | Problem |
|--------|---------|
| Image Capture (PTP) | Painfully slow for large video files |
| AirDrop | Unreliable, even over wired connection |
| iMazing / similar | Uses AFC protocol, speed is bottlenecked |

PhotoTransfer bypasses these by streaming raw files over a **usbmux TCP tunnel** — the same mechanism Xcode uses to install apps. On USB 3.2 Gen 2 hardware, transfers run at wire speed.

## How it works

```
iPhone (iOS app)          Mac (macOS app)
─────────────────         ───────────────────────
TCP listener         ←──  usbmux tunnel via /var/run/usbmuxd
PHAssetResourceManager    FileReceiver
  → chunk stream    ───►  → write to disk
```

- **iOS app**: TCP server that reads raw asset data via `PHAssetResourceManager` and streams it in chunks
- **macOS app**: connects through usbmuxd (no network required), receives and saves files
- **Protocol**: custom binary header (filename, file size, creation date) followed by raw data

## Tested on

- MacBook Air M2 (16 GB RAM)
- iPhone 16 Pro (USB 3.2 Gen 2, 10 Gbps)
- USB 3.2 Gen 2 cable

## Getting started

### Requirements

- Xcode 16+
- iOS 17+ device
- macOS 14+
- USB cable (USB 3.x recommended for full speed)

### Build & run

1. Clone the repo:
   ```
   git clone https://github.com/tzulunyeh/PhotoTransfer.git
   ```
2. Open `PhotoTransfer.xcworkspace` in Xcode
3. Connect iPhone via USB
4. Build and run the **PhotoTransfer-iOS** target on the iPhone
5. Build and run the **PhotoTransfer-macOS** target on the Mac
6. On iPhone: tap **Select Photos**, choose files, tap **Send**
7. Files are saved to `~/Desktop/PhotoTransfer/` (configurable in the Mac app)

## Limitations

- Requires Xcode to build — not available on the App Store (uses usbmux private interface)
- USB connection only (no WiFi mode)
- macOS app must be running before starting a transfer
