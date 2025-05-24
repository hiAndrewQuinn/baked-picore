#!/bin/bash
set -e

IMAGE_FILE="$1" # Mandatory first parameter

# Check if IMAGE_FILE is provided
if [ -z "$IMAGE_FILE" ]; then
  echo "Error: No image file specified for unmounting."
  echo "Usage: $0 <path_to_image.img>"
  exit 1
fi

# Check if the specified image file exists (to find its loop device)
# It might not be strictly necessary for the file to exist if the loop device is already set up
# but it's a good check for the user providing the correct parameter.
if [ ! -f "$IMAGE_FILE" ] && ! losetup -j "$IMAGE_FILE" &>/dev/null; then
  echo "Warning: Image file '$IMAGE_FILE' not found, but will attempt to find associated loop device if one exists."
fi

echo "Attempting to unmount image: $IMAGE_FILE"

# Determine the loop device associated with the image file
# losetup -j <file> shows associated loop devices. We take the first one.
LOOP_DEV=$(losetup -j "$IMAGE_FILE" | cut -d':' -f1)

if [ -z "$LOOP_DEV" ]; then
  echo "Error: Could not determine loop device for '$IMAGE_FILE'."
  echo "It might not be mounted or was mounted under a different path."
  echo "You may need to clean up manually using 'losetup -l', 'kpartx -l <loop_device>', 'umount', 'kpartx -d <loop_device>', and 'losetup -d <loop_device>'."
  exit 1
fi

echo "Found loop device: $LOOP_DEV for $IMAGE_FILE"

# Define standard mount points
# If you use different mount points, you'll need to adjust these.
MNT_ROOT="./mnt_root"
MNT_BOOT="./mnt_boot"

echo "Unmounting $MNT_ROOT and $MNT_BOOT..."
if mountpoint -q "$MNT_ROOT"; then
  sudo umount "$MNT_ROOT" || echo "Warning: Could not unmount $MNT_ROOT. It might not have been mounted or was already unmounted."
else
  echo "$MNT_ROOT was not a mountpoint."
fi

if mountpoint -q "$MNT_BOOT"; then
  sudo umount "$MNT_BOOT" || echo "Warning: Could not unmount $MNT_BOOT. It might not have been mounted or was already unmounted."
else
  echo "$MNT_BOOT was not a mountpoint."
fi

echo "Removing partition mappings from $LOOP_DEV..."
# -d deletes partition mappings
if sudo kpartx -l "$LOOP_DEV" 2>/dev/null | grep -q "$(basename "$LOOP_DEV")p"; then
  sudo kpartx -d "$LOOP_DEV" || echo "Warning: kpartx -d $LOOP_DEV failed. Mappings might not have existed or another issue occurred."
else
  echo "No kpartx mappings found for $LOOP_DEV to remove."
fi

echo "Detaching loop device $LOOP_DEV..."
if losetup "$LOOP_DEV" &>/dev/null; then
  sudo losetup -d "$LOOP_DEV" || echo "Warning: losetup -d $LOOP_DEV failed. It might have already been detached or another issue occurred."
else
  echo "Loop device $LOOP_DEV not active or already detached."
fi

echo ""
echo "Cleanup for '$IMAGE_FILE' complete."
echo "You may remove the mount point directories ./mnt_boot and ./mnt_root if they are empty and no longer needed (e.g., sudo rmdir ./mnt_boot ./mnt_root)."
