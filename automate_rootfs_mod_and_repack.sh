#!/bin/bash
set -e          # Exit immediately if a command exits with a non-zero status.
set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that failed.

echo "Automated piCore RootFS Modifier and Repacker"
echo "------------------------------------------------"

# --- Configuration ---
ORIGINAL_IMAGE_FILE="default-piCore.img"
BOOT_MOUNT_POINT="./mnt_boot"
ROOT_MOUNT_POINT="./mnt_root"
ROOTFS_GZ_FILENAME="rootfs-piCore-15.0.gz" # Adjust if your version differs
TEMP_ROOTFS_DIR="./temp_rootfs_work"       # Temporary directory for rootfs manipulation
OUTPUT_IMAGE_BASENAME="modified-piCore"

# Variables for loop device and partition paths
LOOP_DEV=""
BOOT_PART_DEV=""
ROOT_PART_DEV=""

# --- Helper: Cleanup function ---
cleanup_mounts_loop() {
  echo "INFO: Initiating cleanup..."
  sync || echo "WARN: sync failed during cleanup"

  if [ -n "$ROOT_MOUNT_POINT" ] && mountpoint -q "$ROOT_MOUNT_POINT"; then
    echo "INFO: Unmounting $ROOT_MOUNT_POINT..."
    sudo umount "$ROOT_MOUNT_POINT" || echo "WARN: Failed to unmount $ROOT_MOUNT_POINT"
  fi
  if [ -n "$BOOT_MOUNT_POINT" ] && mountpoint -q "$BOOT_MOUNT_POINT"; then
    echo "INFO: Unmounting $BOOT_MOUNT_POINT..."
    sudo umount "$BOOT_MOUNT_POINT" || echo "WARN: Failed to unmount $BOOT_MOUNT_POINT"
  fi

  if [ -n "$LOOP_DEV" ] && losetup "$LOOP_DEV" &>/dev/null; then
    if sudo kpartx -l "$LOOP_DEV" 2>/dev/null | grep -q "$(basename "$LOOP_DEV")p"; then
      echo "INFO: Removing partition mappings from $LOOP_DEV..."
      sudo kpartx -d "$LOOP_DEV" || echo "WARN: kpartx -d $LOOP_DEV failed"
    else
      echo "INFO: No kpartx mappings found for $LOOP_DEV to remove."
    fi
    echo "INFO: Detaching loop device $LOOP_DEV..."
    sudo losetup -d "$LOOP_DEV" || echo "WARN: losetup -d $LOOP_DEV failed"
  elif [ -n "$LOOP_DEV" ]; then
    echo "INFO: Loop device $LOOP_DEV already detached or not active."
  fi

  if [ -d "$TEMP_ROOTFS_DIR" ]; then
    echo "INFO: Removing temporary rootfs working directory: $TEMP_ROOTFS_DIR"
    sudo rm -rf "$TEMP_ROOTFS_DIR"
  fi
  echo "INFO: Cleanup finished."
}

# Trap exit signals for cleanup
trap cleanup_mounts_loop EXIT SIGINT SIGTERM

# --- Sanity Checks and Setup ---
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root or with sudo."
  exit 1
fi

for cmd in losetup kpartx mount umount findmnt lsblk dd sync gunzip gzip cpio find mkdir rm basename sed tee; do
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
sudo mkdir -p "$TEMP_ROOTFS_DIR" # Create temp working dir for rootfs contents

# === PHASE 1: Mount the original image ===
echo ""
echo "=== PHASE 1: Mounting '$ORIGINAL_IMAGE_FILE' ==="
echo "INFO: Setting up loop device for $ORIGINAL_IMAGE_FILE..."
LOOP_DEV=$(sudo losetup -fP --show "$ORIGINAL_IMAGE_FILE")
if [ -z "$LOOP_DEV" ]; then
  echo "ERROR: Failed to set up loop device for $ORIGINAL_IMAGE_FILE."
  exit 1 # Trap will call cleanup
fi
echo "INFO: Image '$ORIGINAL_IMAGE_FILE' on loop device $LOOP_DEV"

echo "INFO: Mapping partitions from $LOOP_DEV..."
sudo kpartx -v -a -s "$LOOP_DEV"
sleep 1 # Give udev time

BOOT_PART_DEV="/dev/mapper/$(basename "$LOOP_DEV")p1"
ROOT_PART_DEV="/dev/mapper/$(basename "$LOOP_DEV")p2"

if [ ! -b "$BOOT_PART_DEV" ] || [ ! -b "$ROOT_PART_DEV" ]; then
  echo "ERROR: Partition devices not found after kpartx. Expected $BOOT_PART_DEV and $ROOT_PART_DEV."
  exit 1
fi

echo "INFO: Mounting boot partition ($BOOT_PART_DEV) to $BOOT_MOUNT_POINT..."
sudo mount "$BOOT_PART_DEV" "$BOOT_MOUNT_POINT"
echo "INFO: Mounting root partition ($ROOT_PART_DEV) to $ROOT_MOUNT_POINT..."
sudo mount "$ROOT_PART_DEV" "$ROOT_MOUNT_POINT"
echo "INFO: Original image mounted successfully."

# === PHASE 2: Modify rootfs-piCore-XX.gz ===
echo ""
echo "=== PHASE 2: Modifying '$ROOTFS_GZ_FILENAME' ==="
ROOTFS_GZ_ON_BOOT_PARTITION_PATH="${BOOT_MOUNT_POINT}/${ROOTFS_GZ_FILENAME}"
NEW_ROOTFS_GZ_TEMP_PATH="${BOOT_MOUNT_POINT}/${ROOTFS_GZ_FILENAME}.new" # On the boot partition

if [ ! -f "$ROOTFS_GZ_ON_BOOT_PARTITION_PATH" ]; then
  echo "ERROR: '$ROOTFS_GZ_ON_BOOT_PARTITION_PATH' not found on the mounted boot partition!"
  exit 1
fi

echo "INFO: Extracting '$ROOTFS_GZ_ON_BOOT_PARTITION_PATH' to '$TEMP_ROOTFS_DIR'..."
# Use subshell for cd to keep main script's CWD, pipe to cpio
sudo gunzip -c "$ROOTFS_GZ_ON_BOOT_PARTITION_PATH" | (cd "$TEMP_ROOTFS_DIR" && sudo cpio -i -d -H newc --no-absolute-filenames)
echo "INFO: Extraction complete."

echo "INFO: Adding 'hello.txt' to the root of the extracted filesystem..."
echo "Hello from the modified piCore rootfs!" | sudo tee "${TEMP_ROOTFS_DIR}/hello.txt" >/dev/null
if [ ! -f "${TEMP_ROOTFS_DIR}/hello.txt" ]; then
  echo "ERROR: Failed to create hello.txt in ${TEMP_ROOTFS_DIR}"
  exit 1
fi
echo "INFO: 'hello.txt' added."

echo "INFO: Re-creating and compressing the modified rootfs to '$NEW_ROOTFS_GZ_TEMP_PATH'..."
# Use subshell for cd, pipe cpio output to gzip
(cd "$TEMP_ROOTFS_DIR" && sudo find . -depth | sudo cpio -o -H newc) | sudo gzip -9 >"$NEW_ROOTFS_GZ_TEMP_PATH"
echo "INFO: Modified rootfs re-created and compressed."

if [ ! -s "$NEW_ROOTFS_GZ_TEMP_PATH" ]; then # -s checks if file exists and is not empty
  echo "ERROR: New rootfs '$NEW_ROOTFS_GZ_TEMP_PATH' was not created or is empty."
  exit 1
fi

echo "INFO: Replacing original '$ROOTFS_GZ_ON_BOOT_PARTITION_PATH' with the modified version..."
sudo mv "$NEW_ROOTFS_GZ_TEMP_PATH" "$ROOTFS_GZ_ON_BOOT_PARTITION_PATH"
echo "INFO: '$ROOTFS_GZ_FILENAME' successfully modified and replaced on the mounted boot partition."

echo "INFO: Cleaning up temporary rootfs extraction directory '$TEMP_ROOTFS_DIR'..."
sudo rm -rf "$TEMP_ROOTFS_DIR"
TEMP_ROOTFS_DIR="" # Clear variable so cleanup trap doesn't try to remove it again

# === PHASE 3: Repack the modified image ===
echo ""
echo "=== PHASE 3: Repacking the modified image ==="
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
FINAL_OUTPUT_IMAGE_FILENAME="${OUTPUT_IMAGE_BASENAME}-${TIMESTAMP}.img"

echo "INFO: The new image will be saved as: ${FINAL_OUTPUT_IMAGE_FILENAME}"
echo "INFO: Underlying loop device for repacking is '${LOOP_DEV}'." # LOOP_DEV is already /dev/loopX

echo "INFO: Flushing filesystem buffers (sync)..."
sudo sync
sudo sync
echo "INFO: Sync complete."

echo "INFO: Starting block-level copy (dd) from '${LOOP_DEV}' to '${FINAL_OUTPUT_IMAGE_FILENAME}'..."
if sudo dd if="${LOOP_DEV}" of="${FINAL_OUTPUT_IMAGE_FILENAME}" bs=4M status=progress conv=fsync; then
  echo "SUCCESS: Modified image repacked successfully!"
  echo "Output image: ${FINAL_OUTPUT_IMAGE_FILENAME}"
  SUDO_USER_REAL=${SUDO_USER:-$(whoami)}
  if id -u "$SUDO_USER_REAL" >/dev/null 2>&1; then
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
# The EXIT trap will handle unmounting and final cleanup.
echo ""
echo "=== PHASE 4: Unmounting and Cleanup ==="
echo "INFO: Unmounting and cleanup will be handled automatically."

echo ""
echo "Script finished. Your modified image is: ${FINAL_OUTPUT_IMAGE_FILENAME}"
exit 0 # Explicitly exit with success, trap will still run for cleanup
