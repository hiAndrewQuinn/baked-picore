#!/bin/bash
set -e          # Exit immediately if a command exits with a non-zero status.
set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that failed.

echo "Image Repacker Script"
echo "This script will create a new .img file from the currently mounted ./mnt_boot and ./mnt_root."
echo "The new image will be a block-for-block copy of the underlying loop device."
echo "--------------------------------------------------------------------------------"

# --- Configuration ---
TARGET_MOUNT_POINT="./mnt_boot" # We'll use this to find the source device
OUTPUT_DIR="."                  # Save the new image in the current directory

# --- Check for root/sudo ---
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root or with sudo because it uses dd on block devices and sync."
  exit 1
fi

# --- Check Dependencies ---
check_dep() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: Command '$1' not found. Please install it."
    exit 1
  fi
}
check_dep "findmnt"
check_dep "lsblk"
check_dep "dd"
check_dep "date"
check_dep "sync"
check_dep "basename"
check_dep "sed"

# --- Generate Timestamped Output Filename ---
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
OUTPUT_IMAGE_FILENAME="repacked-piCore-${TIMESTAMP}.img"
OUTPUT_IMAGE_FILE="${OUTPUT_DIR}/${OUTPUT_IMAGE_FILENAME}"

echo "INFO: The new image will be saved as: ${OUTPUT_IMAGE_FILE}"

# --- Verify Target Mount Point ---
echo "INFO: Verifying mount point '${TARGET_MOUNT_POINT}'..."
if ! mountpoint -q "$TARGET_MOUNT_POINT"; then
  echo "ERROR: '${TARGET_MOUNT_POINT}' is not a mount point or is not accessible."
  echo "Please ensure the image is mounted correctly using a script like mount_image.sh."
  exit 1
fi
echo "INFO: '${TARGET_MOUNT_POINT}' is a valid mount point."

# --- Find the Mapped Partition Device ---
MAPPED_PARTITION=$(findmnt -n -o SOURCE --target "$TARGET_MOUNT_POINT")
if [ -z "$MAPPED_PARTITION" ]; then
  echo "ERROR: Could not determine the source device for '${TARGET_MOUNT_POINT}'."
  exit 1
fi
echo "INFO: '${TARGET_MOUNT_POINT}' is mounted from '${MAPPED_PARTITION}'."

# --- Find the Parent Loop Device ---
PARTITION_BASENAME=$(basename "$MAPPED_PARTITION") # e.g., loop46p1 from /dev/mapper/loop46p1

# Attempt 1: Use lsblk (usually reliable)
echo "INFO: Attempting to find parent loop device for ${MAPPED_PARTITION} using lsblk..."
LOOP_DEVICE_NAME=$(lsblk -no PKNAME "$MAPPED_PARTITION")

# Attempt 2: Parse from device mapper name (if lsblk failed or returned nothing)
if [ -z "$LOOP_DEVICE_NAME" ]; then
  echo "INFO: lsblk -no PKNAME did not return a parent for $MAPPED_PARTITION. Attempting to parse from partition name '${PARTITION_BASENAME}'..."
  # This sed command extracts 'loopX' from 'loopXpY' (e.g. loop46 from loop46p1)
  LOOP_DEVICE_NAME=$(echo "$PARTITION_BASENAME" | sed -n 's/^\(loop[0-9]\+\)p[0-9]\+$/\1/p')
  if [ -n "$LOOP_DEVICE_NAME" ]; then
    echo "INFO: Successfully parsed loop device name as '${LOOP_DEVICE_NAME}' from partition name."
  fi
fi

if [ -z "$LOOP_DEVICE_NAME" ]; then
  echo "ERROR: Could not determine the parent kernel name for '${MAPPED_PARTITION}' using lsblk or by parsing the name '${PARTITION_BASENAME}'."
  exit 1
fi

FULL_LOOP_DEVICE_PATH="/dev/${LOOP_DEVICE_NAME}"
if [ ! -b "$FULL_LOOP_DEVICE_PATH" ]; then
  echo "ERROR: Derived loop device path '${FULL_LOOP_DEVICE_PATH}' is not a block device or does not exist."
  echo "Ensure that '${LOOP_DEVICE_NAME}' is correct and '/dev/${LOOP_DEVICE_NAME}' is the actual loop device."
  exit 1
fi
echo "INFO: The underlying loop device is '${FULL_LOOP_DEVICE_PATH}'."

# --- Get Confirmation from User ---
echo ""
echo "IMPORTANT:"
echo "The script will now perform a block-level copy using 'dd' from:"
echo "  Source: ${FULL_LOOP_DEVICE_PATH}"
echo "  Destination: ${OUTPUT_IMAGE_FILE}"
echo "This will create an image of the same size as the original mounted image."
echo ""
read -r -p "Do you want to proceed? (yes/no): " confirmation
if [[ "$confirmation" != "yes" ]]; then
  echo "Aborted by user."
  exit 0
fi

# --- Flush Filesystem Buffers ---
echo "INFO: Flushing filesystem buffers (sync)..."
sync
sync # Just to be safe
echo "INFO: Sync complete."

# --- Perform the Block-Level Copy ---
echo "INFO: Starting block-level copy with dd. This may take some time..."
echo "Command: sudo dd if=\"${FULL_LOOP_DEVICE_PATH}\" of=\"${OUTPUT_IMAGE_FILE}\" bs=4M status=progress conv=fsync"

if sudo dd if="${FULL_LOOP_DEVICE_PATH}" of="${OUTPUT_IMAGE_FILE}" bs=4M status=progress conv=fsync; then
  echo ""
  echo "SUCCESS: Image repacked successfully!"
  echo "Output image: ${OUTPUT_IMAGE_FILE}"
  # Change ownership to the user who invoked sudo, if possible, or just make readable.
  SUDO_USER_REAL=${SUDO_USER:-$(whoami)}
  if id -u "$SUDO_USER_REAL" >/dev/null 2>&1; then
    sudo chown "${SUDO_USER_REAL}:${SUDO_USER_REAL}" "${OUTPUT_IMAGE_FILE}" || sudo chmod a+r "${OUTPUT_IMAGE_FILE}"
    echo "INFO: Ownership of '${OUTPUT_IMAGE_FILE}' set to '${SUDO_USER_REAL}' or made world-readable."
  else
    sudo chmod a+r "${OUTPUT_IMAGE_FILE}"
    echo "INFO: '${OUTPUT_IMAGE_FILE}' made world-readable."
  fi
else
  echo ""
  echo "ERROR: dd command failed. The output image might be incomplete or corrupted."
  # Attempt to remove potentially corrupted output file
  if [ -f "${OUTPUT_IMAGE_FILE}" ]; then
    sudo rm -f "${OUTPUT_IMAGE_FILE}"
    echo "INFO: Removed potentially corrupted output file: ${OUTPUT_IMAGE_FILE}"
  fi
  exit 1
fi

echo "--------------------------------------------------------------------------------"
echo "Repacking complete."
