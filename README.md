# yt-dlp UI

A minimal Flutter desktop app for downloading audio via yt-dlp.

## Prerequisites

### 1. Flutter (Linux desktop)
```bash
# Install Flutter via snap (easiest on Ubuntu/Debian)
sudo snap install flutter --classic
flutter channel stable
flutter upgrade

# Enable Linux desktop support
flutter config --enable-linux-desktop
```

### 2. Linux build dependencies
```bash
sudo apt install -y \
  clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev
```

### 3. yt-dlp (in your Distrobox or host)
Make sure `yt-dlp` is on your `$PATH` when launching the app.
If installed via Distrobox export, it should already be at `~/.local/bin/yt-dlp`.

Check:
```bash
which yt-dlp
yt-dlp --version
```

---

## Run (development)

```bash
cd ytdlp_ui
flutter pub get
flutter run -d linux
```

## Build (release binary)

```bash
flutter build linux --release
```

The binary lands at:
```
build/linux/x64/release/bundle/ytdlp_ui
```

You can copy the entire `bundle/` folder anywhere, or symlink the binary:
```bash
ln -s $(pwd)/build/linux/x64/release/bundle/ytdlp_ui ~/.local/bin/ytdlp-ui
```

---

## Features

- **Browse** to choose your save folder (defaults to `$HOME`)
- **Paste** one or more URLs, one per line
- Downloads as **MP3 at best quality** with embedded thumbnail & metadata
- **Progress bar** per download (indeterminate while fetching metadata, then % fill)
- **Error panel** shown inline on failure, with the yt-dlp exit code
- **Log viewer** per job — expand/collapse, copy to clipboard
- Sequential downloads — queued jobs run one after another

## Notes

- The app calls `yt-dlp` directly via `Process.start`, so it inherits your shell PATH.
- If `yt-dlp` isn't found, the error tile will tell you explicitly.
- Logs include both stdout and stderr from yt-dlp (stderr lines are prefixed with ⚠).
- "Clear finished" removes done/errored jobs from the list without affecting files.
