# macOS Startup Service Guide (launchd)

macOS uses **launchd** instead of systemd. Services are defined in `.plist` (XML property list) files and placed in `~/Library/LaunchAgents/`.

---

## 1. Create a launchd plist file

Create a plist at `~/Library/LaunchAgents/com.gads.hub.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gads.hub</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/itelasoft/Documents/GADS/GADS</string>
        <string>hub</string>
        <string>--host-address=0.0.0.0</string>
        <string>--port=10000</string>
        <string>--auth=true</string>
        <string>--mongo-db=localhost:27017</string>
    </array>

    <key>WorkingDirectory</key>
    <string>/Users/itelasoft/Documents/GADS</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/Users/itelasoft/Library/Logs/gads-hub.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/itelasoft/Library/Logs/gads-hub.err</string>
</dict>
</plist>
```

And another at `~/Library/LaunchAgents/com.gads.provider.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gads.provider</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/itelasoft/Documents/GADS/GADS</string>
        <string>provider</string>
        <string>--nickname=mac-provider</string>
        <string>--hub=http://127.0.0.1:10000</string>
        <string>--mongo-db=localhost:27017</string>
    </array>

    <key>WorkingDirectory</key>
    <string>/Users/itelasoft/Documents/GADS</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/Users/itelasoft/Library/Logs/gads-provider.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/itelasoft/Library/Logs/gads-provider.err</string>
</dict>
</plist>
```

---

## 2. Key mappings: systemd → launchd

| systemd | launchd | Notes |
|---|---|---|
| `[Service] ExecStart=` | `ProgramArguments` | Array of path + args |
| `WorkingDirectory=` | `WorkingDirectory` | Same |
| `Restart=on-failure` | `KeepAlive` | `true` = restart if it dies |
| `RestartSec=5` | `ThrottleInterval` | Seconds between restarts (default 10) |
| `WantedBy=multi-user.target` | `RunAtLoad` | Start on login |
| `After=` / `Requires=` | Not needed | launchd handles this differently |
| `User=` | `UserName` | Only for system-wide agents in `/Library/LaunchDaemons/` |

---

## 3. Load, start, and manage the service

```bash
# Load the plist (tells launchd about it)
launchctl load ~/Library/LaunchAgents/com.gads.hub.plist
launchctl load ~/Library/LaunchAgents/com.gads.provider.plist

# Start immediately (RunAtLoad handles this automatically on next login)
launchctl start com.gads.hub
launchctl start com.gads.provider

# Check if running
launchctl list | grep com.gads

# Stop a service
launchctl stop com.gads.hub

# Unload (remove from launchd)
launchctl unload ~/Library/LaunchAgents/com.gads.hub.plist
launchctl unload ~/Library/LaunchAgents/com.gads.provider.plist
```

---

## 4. Useful commands

```bash
# View service logs
tail -f ~/Library/Logs/gads-hub.log
tail -f ~/Library/Logs/gads-hub.err

# Check service status/details
launchctl print gui/$(id -u)/com.gads.hub

# List all user agents
launchctl list
```

---

## 5. Run MongoDB on macOS

```bash
# Install via Homebrew
brew tap mongodb/brew
brew install mongodb-community@7.0

# Start MongoDB as a launchd service
brew services start mongodb-community@7.0

# Or run in Docker (same as the Linux setup)
docker run -d \
  --name gads-mongodb \
  --restart always \
  -p 127.0.0.1:27017:27017 \
  -v gads-mongo-data:/data/db \
  mongo:7.0
```

---

## 6. Full install script for macOS

```bash
#!/usr/bin/env bash
set -euo pipefail

GADS_USER="$USER"
GADS_DIR="/Users/$GADS_USER/Documents/GADS"
ZIP_FILE="$(cd "$(dirname "$0")" && pwd)/GADS.zip"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"

# Create dirs
mkdir -p "$LAUNCH_DIR" "$LOG_DIR"

# Extract GADS
unzip -o "$ZIP_FILE" -d "$GADS_DIR"
chmod +x "$GADS_DIR/GADS"

# Hub plist
cat > "$LAUNCH_DIR/com.gads.hub.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gads.hub</string>
    <key>ProgramArguments</key>
    <array>
        <string>$GADS_DIR/GADS</string>
        <string>hub</string>
        <string>--host-address=0.0.0.0</string>
        <string>--port=10000</string>
        <string>--auth=true</string>
        <string>--mongo-db=localhost:27017</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$GADS_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/gads-hub.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/gads-hub.err</string>
</dict>
</plist>
PLIST

# Provider plist
cat > "$LAUNCH_DIR/com.gads.provider.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gads.provider</string>
    <key>ProgramArguments</key>
    <array>
        <string>$GADS_DIR/GADS</string>
        <string>provider</string>
        <string>--nickname=mac-provider</string>
        <string>--hub=http://127.0.0.1:10000</string>
        <string>--mongo-db=localhost:27017</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$GADS_DIR</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/gads-provider.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/gads-provider.err</string>
</dict>
</plist>
PLIST

# Load services
launchctl load "$LAUNCH_DIR/com.gads.hub.plist"
launchctl load "$LAUNCH_DIR/com.gads.provider.plist"

echo "Services loaded and running:"
launchctl list | grep com.gads
```

---

## Places where plist files can live

| Path | Scope | Runs as |
|---|---|---|
| `~/Library/LaunchAgents/` | Current user | Runs at login |
| `/Library/LaunchAgents/` | All users | Runs at login |
| `/Library/LaunchDaemons/` | System-wide | Runs at boot (as root) |
