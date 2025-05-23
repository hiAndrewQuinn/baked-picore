#!/bin/bash
set -e
IMAGE_FILE="${1:-customized-piCore.img}"
if [ ! -f "$IMAGE_FILE" ]; then
  echo "Error: Image file '$IMAGE_FILE' not found."
  exit 1
fi

echo "Setting up loop device for $IMAGE_FILE..."
LOOP_DEV=$(sudo losetup -fP --show "$IMAGE_FILE")
if [ -z "$LOOP_DEV" ]; then
  echo "Failed to set up loop device."
  exit 1
fi
echo "$LOOP_DEV" >.current_loop_dev # Save for unmounting
echo "Image '$IMAGE_FILE' on $LOOP_DEV"

echo "Mapping partitions..."
sudo kpartx -v -a "$LOOP_DEV"
sleep 1

BOOT_PART_DEV="/dev/mapper/$(basename "$LOOP_DEV")p1"
ROOT_PART_DEV="/dev/mapper/$(basename "$LOOP_DEV")p2"

echo "Creating mount points mnt_boot and mnt_root..."
sudo mkdir -p mnt_boot mnt_root

echo "Mounting $BOOT_PART_DEV (boot) to ./mnt_boot..."
sudo mount "$BOOT_PART_DEV" ./mnt_boot
echo "Mounting $ROOT_PART_DEV (root) to ./mnt_root..."
sudo mount "$ROOT_PART_DEV" ./mnt_root

echo "Image mounted. Boot partition at ./mnt_boot, Root partition at ./mnt_root"
echo "To unmount, run: ./umount_image.sh"
