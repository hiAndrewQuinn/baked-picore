#!/bin/bash
set -e          # Exit immediately if a command exits with a non-zero status.
set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that failed.

echo "Automated piCore RootFS No-Modification Repacker"
echo "------------------------------------------------------------------------------------"
echo "This script will extract and re-archive rootfs.gz without changes,"
echo "using --reproducible for cpio CREATION, then repack the main .img file."
echo "Hard links are preserved by default by cpio."
echo "------------------------------------------------------------------------------------"

# --- Configuration ---
ORIGINAL_IMAGE_FILE="default-piCore.img"
BOOT_MOUNT_POINT="./mnt_boot"
ROOT_MOUNT_POINT="./mnt_root"
ROOTFS_GZ_FILENAME="rootfs-piCore-15.0.gz" # Adjust if your version differs
TEMP_ROOTFS_DIR="./temp_rootfs_noop_work"  # Temporary directory for rootfs manipulation
OUTPUT_IMAGE_BASENAME="repacked-noop-piCore"

# Variables for loop device and partition paths
LOOP_DEV=""
BOOT_PART_DEV=""
ROOT_PART_DEV=""

# --- Helper: Cleanup function ---
cleanup_mounts_loop() {
  echo "INFO: Initiating cleanup..."
  sync || echo "WARN: sync failed during cleanup"

  # Attempt to cd out of any potentially problematic directories as a precaution
  cd / || echo "WARN: cd / failed during cleanup"

  if [ -n "$ROOT_MOUNT_POINT" ] && mountpoint -q "$ROOT_MOUNT_POINT"; then
    echo "INFO: Unmounting $ROOT_MOUNT_POINT..."
    if ! sudo umount "$ROOT_MOUNT_POINT"; then
      echo "WARN: Failed to unmount $ROOT_MOUNT_POINT, attempting lazy unmount..."
      sudo umount -l "$ROOT_MOUNT_POINT" || echo "WARN: Lazy unmount of $ROOT_MOUNT_POINT also failed"
    fi
  fi
  if [ -n "$BOOT_MOUNT_POINT" ] && mountpoint -q "$BOOT_MOUNT_POINT"; then
    echo "INFO: Unmounting $BOOT_MOUNT_POINT..."
    if ! sudo umount "$BOOT_MOUNT_POINT"; then
      echo "WARN: Failed to unmount $BOOT_MOUNT_POINT, attempting lazy unmount..."
      sudo umount -l "$BOOT_MOUNT_POINT" || echo "WARN: Lazy unmount of $BOOT_MOUNT_POINT also failed"
    fi
  fi

  if [ -n "$LOOP_DEV" ] && losetup "$LOOP_DEV" &>/dev/null; then
    if sudo dmsetup ls --target loop --tree 2>/dev/null | grep -q "$(basename "$LOOP_DEV")"; then
      echo "INFO: Removing partition mappings from $LOOP_DEV..."
      sudo kpartx -d "$LOOP_DEV" || echo "WARN: kpartx -d $LOOP_DEV failed"
    else
      echo "INFO: No active kpartx mappings found for $LOOP_DEV to remove (checked via dmsetup)."
    fi
    echo "INFO: Detaching loop device $LOOP_DEV..."
    sudo losetup -d "$LOOP_DEV" || echo "WARN: losetup -d $LOOP_DEV failed"
  elif [ -n "$LOOP_DEV" ]; then
    echo "INFO: Loop device $LOOP_DEV already detached or not active."
  fi

  if [ -n "$TEMP_ROOTFS_DIR_CLEANUP" ] && [ -d "$TEMP_ROOTFS_DIR_CLEANUP" ]; then
    echo "INFO: Removing temporary rootfs working directory: $TEMP_ROOTFS_DIR_CLEANUP"
    sudo rm -rf "$TEMP_ROOTFS_DIR_CLEANUP"
  fi
  echo "INFO: Cleanup finished."
}

# Store the initial value of TEMP_ROOTFS_DIR for the trap,
# as its value might be cleared before the trap runs on a normal exit.
TEMP_ROOTFS_DIR_CLEANUP="$TEMP_ROOTFS_DIR"
trap cleanup_mounts_loop EXIT SIGINT SIGTERM

# --- Sanity Checks and Setup ---
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root or with sudo."
  exit 1
fi

for cmd in losetup kpartx mount umount findmnt lsblk dd sync gunzip gzip cpio find mkdir rm basename sed tee dmsetup; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Command '$cmd' not found. Please install it."
    exit 1
  fi
done

if [ ! -f "$ORIGINAL_IMAGE_FILE" ]; then
  echo "ERROR: Original image file '$ORIGINAL_IMAGE_FILE' not found in current directory."
  exit 1
fi

sudo mkdir -p "$BOOT_MOUNT_POINT" "$ROOT_MOUNT_POINT"
sudo mkdir -p "$TEMP_ROOTFS_DIR"

# === PHASE 1: Mount the original image ===
echo ""
echo "=== PHASE 1: Mounting '$ORIGINAL_IMAGE_FILE' ==="
echo "INFO: Setting up loop device for $ORIGINAL_IMAGE_FILE..."
LOOP_DEV=$(sudo losetup -fP --show "$ORIGINAL_IMAGE_FILE")
if [ -z "$LOOP_DEV" ]; then
  echo "ERROR: Failed to set up loop device for $ORIGINAL_IMAGE_FILE."
  exit 1
fi
echo "INFO: Image '$ORIGINAL_IMAGE_FILE' on loop device $LOOP_DEV"

echo "INFO: Mapping partitions from $LOOP_DEV..."
sudo kpartx -v -a -s "$LOOP_DEV"

MAX_WAIT_KPARTX=10 # seconds
WAIT_COUNT=0
EXPECTED_P1="/dev/mapper/$(basename "$LOOP_DEV")p1"
EXPECTED_P2="/dev/mapper/$(basename "$LOOP_DEV")p2"

while ! ([ -b "$EXPECTED_P1" ] && [ -b "$EXPECTED_P2" ]) && [ "$WAIT_COUNT" -lt "$MAX_WAIT_KPARTX" ]; do
  echo "INFO: Waiting for partition devices ($EXPECTED_P1, $EXPECTED_P2) to appear... ($WAIT_COUNT/$MAX_WAIT_KPARTX)"
  sleep 1
  sudo udevadm settle || true
  sudo partprobe "$LOOP_DEV" || true
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

BOOT_PART_DEV="$EXPECTED_P1"
ROOT_PART_DEV="$EXPECTED_P2"

if [ ! -b "$BOOT_PART_DEV" ] || [ ! -b "$ROOT_PART_DEV" ]; then
  echo "ERROR: Partition devices not found after kpartx and waiting."
  echo "Expected: $BOOT_PART_DEV and $ROOT_PART_DEV"
  echo "Found in /dev/mapper:"
  ls -l /dev/mapper/
  exit 1
fi

echo "INFO: Mounting boot partition ($BOOT_PART_DEV) to $BOOT_MOUNT_POINT..."
sudo mount "$BOOT_PART_DEV" "$BOOT_MOUNT_POINT"
echo "INFO: Mounting root partition ($ROOT_PART_DEV) to $ROOT_MOUNT_POINT..."
sudo mount "$ROOT_PART_DEV" "$ROOT_MOUNT_POINT"
echo "INFO: Original image mounted successfully."

# === PHASE 2: Extract and Re-archive/Re-compress rootfs-piCore-XX.gz (No Modification) ===
echo ""
echo "=== PHASE 2: Processing '$ROOTFS_GZ_FILENAME' (No Mod) ==="
ROOTFS_GZ_ON_BOOT_PARTITION_PATH="${BOOT_MOUNT_POINT}/${ROOTFS_GZ_FILENAME}"
NEW_ROOTFS_GZ_TEMP_PATH="${BOOT_MOUNT_POINT}/${ROOTFS_GZ_FILENAME}.noop.new"

if [ ! -f "$ROOTFS_GZ_ON_BOOT_PARTITION_PATH" ]; then
  echo "ERROR: '$ROOTFS_GZ_ON_BOOT_PARTITION_PATH' not found on the mounted boot partition!"
  exit 1
fi

echo "INFO: Extracting '$ROOTFS_GZ_ON_BOOT_PARTITION_PATH' to '$TEMP_ROOTFS_DIR'..."
# CORRECTED: Removed --reproducible from cpio EXTRACT command.
# Hard links are preserved by default. Inode numbers are not preserved across filesystems.
# The subshell ( ... ) ensures 'cd' only affects commands within it.
# 'set -o pipefail' ensures that if gunzip fails, the whole pipeline fails.
sudo gunzip -c "$ROOTFS_GZ_ON_BOOT_PARTITION_PATH" | (cd "$TEMP_ROOTFS_DIR" && sudo cpio -i -d -H newc --no-absolute-filenames)
echo "INFO: Extraction complete."

# NO MODIFICATION STEP HERE

echo "INFO: Re-creating and compressing the (unmodified) rootfs to '$NEW_ROOTFS_GZ_TEMP_PATH' with --reproducible (for archive creation)..."
# The -o (create) mode of GNU cpio should detect and preserve hard links from $TEMP_ROOTFS_DIR by default.
# --reproducible normalizes metadata FOR THE ARCHIVE.
(cd "$TEMP_ROOTFS_DIR" && sudo find . -depth | sudo cpio --reproducible -o -H newc) | sudo gzip -9 >"$NEW_ROOTFS_GZ_TEMP_PATH"
echo "INFO: (Unmodified) rootfs re-created and compressed."

if [ ! -s "$NEW_ROOTFS_GZ_TEMP_PATH" ]; then
  echo "ERROR: New rootfs '$NEW_ROOTFS_GZ_TEMP_PATH' was not created or is empty."
  exit 1
fi

echo "INFO: Replacing original '$ROOTFS_GZ_ON_BOOT_PARTITION_PATH' with the re-archived version..."
sudo mv "$NEW_ROOTFS_GZ_TEMP_PATH" "$ROOTFS_GZ_ON_BOOT_PARTITION_PATH"
echo "INFO: '$ROOTFS_GZ_FILENAME' successfully replaced on the mounted boot partition."

echo "INFO: Cleaning up temporary rootfs extraction directory '$TEMP_ROOTFS_DIR'..."
sudo rm -rf "$TEMP_ROOTFS_DIR"
# Clear TEMP_ROOTFS_DIR_CLEANUP so the trap doesn't try to remove it again on a normal exit.
# If script exited due to an error before this, TEMP_ROOTFS_DIR_CLEANUP would still have its original value.
TEMP_ROOTFS_DIR_CLEANUP=""

# === PHASE 3: Repack the modified image ===
echo ""
echo "=== PHASE 3: Repacking the image (with re-archived rootfs.gz) ==="
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
FINAL_OUTPUT_IMAGE_FILENAME="${OUTPUT_IMAGE_BASENAME}-${TIMESTAMP}.img"

echo "INFO: The new image will be saved as: ${FINAL_OUTPUT_IMAGE_FILENAME}"
echo "INFO: Underlying loop device for repacking is '${LOOP_DEV}'."

echo "INFO: Flushing filesystem buffers (sync)..."
sudo sync
sudo sync
echo "INFO: Sync complete."

echo "INFO: Starting block-level copy (dd) from '${LOOP_DEV}' to '${FINAL_OUTPUT_IMAGE_FILENAME}'..."
if sudo dd if="${LOOP_DEV}" of="${FINAL_OUTPUT_IMAGE_FILENAME}" bs=4M status=progress conv=fsync; then
  echo "SUCCESS: Image (with re-archived rootfs.gz) repacked successfully!"
  echo "Output image: ${FINAL_OUTPUT_IMAGE_FILENAME}"
  SUDO_USER_REAL=${SUDO_USER:-$(whoami)}
  if id -u "$SUDO_USER_REAL" &>/dev/null; then
    sudo chown "${SUDO_USER_REAL}:${SUDO_USER_REAL}" "${FINAL_OUTPUT_IMAGE_FILENAME}" || sudo chmod a+r "${FINAL_OUTPUT_IMAGE_FILENAME}"
    echo "INFO: Ownership of '${FINAL_OUTPUT_IMAGE_FILENAME}' set to '${SUDO_USER_REAL}' or made world-readable."
  else
    sudo chmod a+r "${FINAL_OUTPUT_IMAGE_FILENAME}"
    echo "INFO: '${FINAL_OUTPUT_IMAGE_FILENAME}' made world-readable."
  fi
else
  echo "ERROR: dd command failed during repacking. The output image might be incomplete or corrupted."
  if [ -f "${FINAL_OUTPUT_IMAGE_FILENAME}" ]; then
    sudo rm -f "${FINAL_OUTPUT_IMAGE_FILENAME}"
    echo "INFO: Removed potentially corrupted output file: ${FINAL_OUTPUT_IMAGE_FILENAME}"
  fi
  exit 1
fi

# === PHASE 4: Unmount and Final Cleanup (done by trap) ===
echo ""
echo "=== PHASE 4: Unmounting and Cleanup ==="
echo "INFO: Unmounting and cleanup will be handled automatically by script exit."

echo ""
echo "Script finished. Your image is: ${FINAL_OUTPUT_IMAGE_FILENAME}"
exit 0
