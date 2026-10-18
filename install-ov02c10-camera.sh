#!/usr/bin/env bash
#
# install-ov02c10-camera.sh
#
# Fix the OmniVision OV02C10 camera (Intel IPU6) on Samsung Galaxy Book4
# (Meteor Lake) under Ubuntu 26.04 / kernel 7.x.
#
# Two layers are handled:
#   1. Kernel : DKMS patch so the ov02c10 driver accepts the 26 MHz clock.
#   2. Userspace : Intel icamerasrc HAL -> v4l2-relayd -> /dev/video0,
#                  which is what browsers (Chromium/Brave/Firefox) can open.
#
# The libcamera Software ISP path (libcamerasrc / cam) is intentionally NOT
# used: on this hardware it enumerates the camera but produces black frames
# (bytesused: 0).
#
# Re-runnable. Tested on: Samsung Galaxy Book4, Ubuntu 26.04, kernel 7.0.0-38.
#
set -euo pipefail

REPO_URL="https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes.git"
REPO_DIR="${HOME}/samsung-galaxy-book-linux-fixes"
DKMS_NAME="ov02c10"
DKMS_VER="26mhz-1.0"
DKMS_SRC="/usr/src/${DKMS_NAME}-${DKMS_VER}"
RELAY_INSTANCE="intel-ipu"

log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] || die "run as your normal user, not root (the script uses sudo)."

log "Checking prerequisites..."
need_cmd sudo
need_cmd git
need_cmd dkms
need_cmd make
need_cmd gst-launch-1.0 || warn "gstreamer tools not found; install gstreamer1.0-tools if needed"

if ! lspci -nn | grep -qi "8086:7d19"; then
    warn "Intel IPU6 (8086:7d19) not found in lspci — continuing anyway."
fi

# ---------------------------------------------------------------------------
# Part 1 — Kernel: patched ov02c10 driver (26 MHz clock) via DKMS
# ---------------------------------------------------------------------------
log "Part 1: ov02c10 26 MHz DKMS patch"

if dkms status | grep -q "^${DKMS_NAME}/${DKMS_VER}.*installed"; then
    log "DKMS module ${DKMS_NAME}/${DKMS_VER} already installed — skipping build."
else
    if [[ ! -d "${REPO_DIR}/ov02c10-26mhz-fix" ]]; then
        log "Cloning fix repository into ${REPO_DIR}"
        git clone "${REPO_URL}" "${REPO_DIR}"
    fi

    SRC_FILE="${REPO_DIR}/ov02c10-26mhz-fix/ov02c10.c"
    [[ -f "${SRC_FILE}" ]] || die "expected source not found: ${SRC_FILE}"

    log "Preparing DKMS tree at ${DKMS_SRC}"
    sudo rm -rf "${DKMS_SRC}"
    sudo mkdir -p "${DKMS_SRC}"
    sudo cp "${SRC_FILE}" "${DKMS_SRC}/"

    # dkms.conf
    sudo tee "${DKMS_SRC}/dkms.conf" >/dev/null <<EOF
PACKAGE_NAME="${DKMS_NAME}"
PACKAGE_VERSION="${DKMS_VER}"
BUILT_MODULE_NAME[0]="${DKMS_NAME}"
DEST_MODULE_LOCATION[0]="/updates/dkms"
AUTOINSTALL="yes"
MAKE[0]="make all"
CLEAN="make clean"
EOF

    # Makefile — note: the make lines MUST be Tab-indented. The here-doc below
    # uses literal tabs (heredoc without <<- so tabs are preserved).
    sudo tee "${DKMS_SRC}/Makefile" >/dev/null <<'EOF'
obj-m += ov02c10.o

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
EOF

    # Sanity check: make sure Tab survived (spaces => missing separator).
    if grep -q '^    make' "${DKMS_SRC}/Makefile"; then
        die "Makefile has spaces instead of tabs; refusing to continue."
    fi

    log "Building and installing DKMS module"
    sudo dkms add     "${DKMS_NAME}/${DKMS_VER}" || true
    sudo dkms build   "${DKMS_NAME}/${DKMS_VER}"
    sudo dkms install "${DKMS_NAME}/${DKMS_VER}"
fi

# ---------------------------------------------------------------------------
# Part 2 — Userspace: icamerasrc HAL + v4l2-relayd
# ---------------------------------------------------------------------------
log "Part 2: icamerasrc + v4l2-relayd"

log "Installing packages (icamerasrc, v4l2-relayd)"
sudo apt-get update -qq
sudo apt-get install -y icamerasrc v4l2-relayd

# The "default" relay instance is broken on Ubuntu 26.04; make sure it is off.
if systemctl list-unit-files | grep -q "v4l2-relayd@default.service"; then
    sudo systemctl disable --now v4l2-relayd@default.service 2>/dev/null || true
fi

log "Writing relay configuration"
sudo tee /etc/default/v4l2-relayd >/dev/null <<'EOF'
VIDEOSRC="icamerasrc"
FORMAT=NV12
WIDTH=1280
HEIGHT=720
FRAMERATE=30/1
CARD_LABEL="Intel IPU Camera"
SPLASHSRC=""
EOF

sudo mkdir -p /etc/v4l2-relayd.d
sudo tee "/etc/v4l2-relayd.d/${RELAY_INSTANCE}.conf" >/dev/null <<'EOF'
VIDEOSRC="icamerasrc"
FORMAT=NV12
WIDTH=1280
HEIGHT=720
FRAMERATE=30/1
CARD_LABEL="Intel IPU Camera"
SPLASHSRC=""
EOF

# Ensure the relay starts after the graphical session settles (GDM SHM race).
sudo mkdir -p "/etc/systemd/system/v4l2-relayd@${RELAY_INSTANCE}.service.d"
sudo tee "/etc/systemd/system/v4l2-relayd@${RELAY_INSTANCE}.service.d/session-order.conf" >/dev/null <<'EOF'
[Unit]
After=graphical-session.target
Wants=graphical-session.target

[Install]
WantedBy=graphical-session.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "v4l2-relayd@${RELAY_INSTANCE}.service"

# udev rule so /dev/ipu-psys* is accessible to the video group.
log "Installing udev rule for ipu-psys"
sudo tee /etc/udev/rules.d/99-ipu6-camera.rules >/dev/null <<'EOF'
KERNEL=="ipu-psys*", GROUP="video", MODE="0660"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger || true

# Make sure the user is in the video group (harmless if already a member).
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx video; then
    log "Adding ${USER} to the 'video' group (log out / reboot required)"
    sudo usermod -aG video "$USER"
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
log "Verifying..."

if ! modinfo "${DKMS_NAME}" 2>/dev/null | grep -q "updates/dkms"; then
    warn "DKMS module does not appear to be the loaded one yet — reboot required."
else
    log "DKMS ov02c10 module is in place."
fi

if systemctl is-active --quiet "v4l2-relayd@${RELAY_INSTANCE}.service"; then
    log "v4l2-relayd@${RELAY_INSTANCE} is running."
else
    warn "v4l2-relayd@${RELAY_INSTANCE} is not running — check: journalctl -u v4l2-relayd@${RELAY_INSTANCE}.service -b"
fi

# Try to confirm the virtual camera device exists.
if command -v v4l2-ctl >/dev/null 2>&1; then
    if v4l2-ctl --list-devices 2>/dev/null | grep -q "Intel IPU Camera"; then
        NODE=$(v4l2-ctl --list-devices 2>/dev/null | awk '/Intel IPU Camera/{f=1;next} f&&/\/dev\/video/{print $1; exit}')
        log "Virtual camera device: ${NODE:-/dev/video0}"
    else
        warn "Virtual camera not listed yet — a reboot may be needed."
    fi
fi

cat <<'EOF'

------------------------------------------------------------------------
Done.

Next steps:
  1. Reboot (required for the DKMS module and for the 'video' group change).
  2. After reboot, confirm:
        systemctl status v4l2-relayd@intel-ipu.service --no-pager
        v4l2-ctl --list-devices | grep -A1 "Intel IPU Camera"
  3. Grab a test frame:
        gst-launch-1.0 v4l2src device=/dev/video0 num-buffers=1 \
          ! jpegenc ! filesink location=/tmp/relay-test.jpg
        xdg-open /tmp/relay-test.jpg
  4. Enable the PipeWire camera flag in Chromium / Brave / Edge:
        chrome://flags/#enable-webrtc-pipewire-camera  -> Enabled -> restart
     Firefox (Snap):
        sudo snap connect firefox:camera
     Then test at https://webcamtests.com/

If icamerasrc as a normal user still reports
  "No attached camera shared memory!"
that is the known libcamhal SHM race; the relay (running as root) is the
intended workaround and is what makes the browser see /dev/video0.

Not used on purpose: the libcamera Software ISP path (libcamerasrc / cam).
It enumerates the camera but produces black frames on this hardware.
------------------------------------------------------------------------
EOF