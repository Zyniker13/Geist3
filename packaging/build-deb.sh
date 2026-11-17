#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Build .deb packages for zTop (amd64 and arm64).
#
# Usage:
#     ./build-deb.sh [version]
#
# The script builds the ztop binary for the target architecture and
# packages it into a .deb file with a systemd user service.

set -euo pipefail

VERSION="${1:-0.1.0}"
ARCH="${2:-amd64}"
BUILD_DIR="$(mktemp -d)"
PACKAGE_NAME="ztop"
MAINTAINER="zTop Maintainers <maintainers@ztop.dev>"
DESCRIPTION="A lightweight system monitor for macOS and Linux"

echo "Building zTop ${VERSION} for ${ARCH}..."

# Determine the Rust target triple
case "$ARCH" in
    amd64)
        TARGET="x86_64-unknown-linux-gnu"
        ;;
    arm64)
        TARGET="aarch64-unknown-linux-gnu"
        ;;
    *)
        echo "Unknown architecture: $ARCH"
        exit 1
        ;;
esac

# Build the binary
cd "$(dirname "$0")/../.."
cargo build --release --target "$TARGET"

# Create the package structure
PKG_DIR="$BUILD_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/local/bin"
mkdir -p "$PKG_DIR/usr/local/lib/ztop"
mkdir -p "$PKG_DIR/lib/systemd/user"

# Copy the binary
cp "target/${TARGET}/release/ztop" "$PKG_DIR/usr/local/bin/ztop"
chmod 755 "$PKG_DIR/usr/local/bin/ztop"

# Copy the systemd service
cp "packaging/systemd/ztop-agent.service" "$PKG_DIR/lib/systemd/user/ztop-agent.service"
chmod 644 "$PKG_DIR/lib/systemd/user/ztop-agent.service"

# Create the control file
cat > "$PKG_DIR/DEBIAN/control" << EOF
Package: ${PACKAGE_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Description: ${DESCRIPTION}
Section: utils
Priority: optional
Depends: libc6
EOF

# Create the postinst script
cat > "$PKG_DIR/DEBIAN/postinst" << 'EOF'
#!/bin/bash
# Create the dedicated ztop user if it doesn't exist
if ! id ztop &> /dev/null; then
    useradd --system --create-home --shell /usr/sbin/nologin ztop
fi

# Enable the systemd user service
if command -v systemctl &> /dev/null; then
    systemctl --user daemon-reload
    systemctl --user enable ztop-agent.service
fi
EOF
chmod 755 "$PKG_DIR/DEBIAN/postinst"

# Create the postrm script
cat > "$PKG_DIR/DEBIAN/postrm" << 'EOF'
#!/bin/bash
# Remove the dedicated ztop user if it exists
if [ "$1" = "purge" ] && id ztop &> /dev/null; then
    userdel ztop 2>/dev/null || true
    rm -rf /home/ztop 2>/dev/null || true
fi
EOF
chmod 755 "$PKG_DIR/DEBIAN/postrm"

# Create the prerm script
cat > "$PKG_DIR/DEBIAN/prerm" << 'EOF'
#!/bin/bash
# Stop the systemd user service
if command -v systemctl &> /dev/null; then
    systemctl --user stop ztop-agent.service 2>/dev/null || true
    systemctl --user disable ztop-agent.service 2>/dev/null || true
fi
EOF
chmod 755 "$PKG_DIR/DEBIAN/prerm"

# Build the .deb package
dpkg-deb --build "$PKG_DIR"

echo "Built: ${BUILD_DIR}/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"

# Clean up
rm -rf "$BUILD_DIR"
