#!/bin/bash
set -e

IMAGE_FILE="$1" # Mandatory first parameter

# Check if IMAGE_FILE is provided
if [ -z "$IMAGE_FILE" ]; then
  echo "Error: No image file specified."
  echo "Usage: $0 <path_to_image.img>"
  exit 1
fi

# Check if the image file exists
if [ ! -f "$IMAGE_FILE" ]; then
  echo "Error: Image file '$IMAGE_FILE' not found."
  exit 1
fi

echo "Setting up loop device for $IMAGE_FILE..."
# The -P option with losetup asks the kernel to scan the partition table on the device.
# --show will print the loop device name.
LOOP_DEV=$(sudo losetup -fP --show "$IMAGE_FILE")
if [ -z "$LOOP_DEV" ]; then
  echo "Error: Failed to set up loop device for $IMAGE_FILE."
  exit 1
fi
echo "Image '$IMAGE_FILE' is now on loop device $LOOP_DEV"

echo "Mapping partitions from $LOOP_DEV..."
# -a adds partition mappings, -v is verbose, -s syncs before creating mappings
sudo kpartx -v -a -s "$LOOP_DEV"
sleep 1 # Give udev time to create device nodes

# Construct partition device paths
# Assumes p1 for boot and p2 for root, common for Raspberry Pi images
BOOT_PART_DEV="/dev/mapper/$(basename "$LOOP_DEV")p1"
ROOT_PART_DEV="/dev/mapper/$(basename "$LOOP_DEV")p2"

echo "Creating mount points ./mnt_boot and ./mnt_root (if they don't exist)..."
sudo mkdir -p ./mnt_boot ./mnt_root

echo "Mounting $BOOT_PART_DEV (boot) to ./mnt_boot..."
if ! sudo mount "$BOOT_PART_DEV" ./mnt_boot; then
  echo "Error: Failed to mount boot partition $BOOT_PART_DEV."
  echo "Attempting to clean up loop device and kpartx mappings..."
  sudo kpartx -d "$LOOP_DEV" || echo "Warning: kpartx -d $LOOP_DEV failed during cleanup."
  sudo losetup -d "$LOOP_DEV" || echo "Warning: losetup -d $LOOP_DEV failed during cleanup."
  exit 1
fi

echo "Mounting $ROOT_PART_DEV (root) to ./mnt_root..."
if ! sudo mount "$ROOT_PART_DEV" ./mnt_root; then
  echo "Error: Failed to mount root partition $ROOT_PART_DEV."
  echo "Attempting to clean up boot mount, loop device, and kpartx mappings..."
  sudo umount ./mnt_boot || echo "Warning: Could not unmount ./mnt_boot during cleanup."
  sudo kpartx -d "$LOOP_DEV" || echo "Warning: kpartx -d $LOOP_DEV failed during cleanup."
  sudo losetup -d "$LOOP_DEV" || echo "Warning: losetup -d $LOOP_DEV failed during cleanup."
  exit 1
fi

echo ""
echo "Image '$IMAGE_FILE' mounted successfully."
echo "  Boot partition: $BOOT_PART_DEV -> ./mnt_boot"
echo "  Root partition: $ROOT_PART_DEV -> ./mnt_root"
echo ""
echo "To unmount, run: ./unmount_image.sh $IMAGE_FILE"
