#!/bin/sh
# Auto-download and install RustDesk Server official binaries

LOG_TAG="rustdeskd-update"
BIN_DIR="/usr/bin"
TMP_ZIP="/tmp/rustdesk-server.zip"
TMP_DIR="/tmp/rustdesk-server-extract"
RELEASE_API="https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest"

log() {
	logger -t "$LOG_TAG" "$1"
	echo "$1"
}

# 1. Detect Architecture
ARCH=$(uname -m)
case "$ARCH" in
	x86_64)
		TARGET_ARCH="amd64"
		;;
	aarch64)
		TARGET_ARCH="arm64v8"
		;;
	armv7l|armv8l)
		TARGET_ARCH="armv7"
		;;
	i386|i686)
		TARGET_ARCH="i386"
		;;
	*)
		log "Error: Architecture $ARCH is not supported by official RustDesk binary releases."
		exit 1
		;;
esac

log "Detected architecture: $ARCH -> $TARGET_ARCH"

# 2. Get download URL
log "Fetching latest release info from GitHub..."
DOWNLOAD_URL=$(curl -s "$RELEASE_API" | grep "browser_download_url.*linux-${TARGET_ARCH}\.zip" | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
	log "Error: Could not find download URL for $TARGET_ARCH."
	exit 1
fi

log "Download URL: $DOWNLOAD_URL"

# 3. Download
log "Downloading..."
curl -sL "$DOWNLOAD_URL" -o "$TMP_ZIP"
if [ $? -ne 0 ] || [ ! -s "$TMP_ZIP" ]; then
	log "Error: Failed to download zip file."
	rm -f "$TMP_ZIP"
	exit 1
fi

# 4. Extract
log "Extracting..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
unzip -q -o "$TMP_ZIP" -d "$TMP_DIR"
if [ $? -ne 0 ]; then
	log "Error: Failed to extract zip file."
	rm -rf "$TMP_DIR" "$TMP_ZIP"
	exit 1
fi

# The zip contains a folder named something like amd64/, arm64v8/, so we find hbbs and hbbr inside it
HBBS_FILE=$(find "$TMP_DIR" -name "hbbs" -type f | head -n 1)
HBBR_FILE=$(find "$TMP_DIR" -name "hbbr" -type f | head -n 1)

if [ -z "$HBBS_FILE" ] || [ -z "$HBBR_FILE" ]; then
	log "Error: Could not find hbbs or hbbr inside the extracted archive."
	rm -rf "$TMP_DIR" "$TMP_ZIP"
	exit 1
fi

# 5. Stop service if running
/etc/init.d/rustdeskd stop 2>/dev/null

# 6. Install
log "Installing binaries to $BIN_DIR..."
mv -f "$HBBS_FILE" "$BIN_DIR/hbbs"
mv -f "$HBBR_FILE" "$BIN_DIR/hbbr"
chmod +x "$BIN_DIR/hbbs"
chmod +x "$BIN_DIR/hbbr"

# Clean up
rm -rf "$TMP_DIR" "$TMP_ZIP"

# 7. Start service
/etc/init.d/rustdeskd start 2>/dev/null

log "Update completed successfully!"
exit 0
