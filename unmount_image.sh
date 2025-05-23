#!/bin/bash
set -e
if [ ! -f ".current_loop_dev" ]; then
  echo "Error: .current_loop_dev file not found. Was the image mounted with mount_image.sh?"
  # As a fallback, try to find any loop devices associated with customized-piCore.img
  LOOP_DEV_GUESS=$(losetup -j customized-piCore.img | cut -d':' -f1)
  if [ -n "$LOOP_DEV_GUESS" ]; then
    echo "Guessing loop device is $LOOP_DEV_GUESS"
    LOOP_DEV="$LOOP_DEV_GUESS"
  else
    echo "Could not determine loop device. Please specify it or clean up manually."
    exit 1
  fi
else
  LOOP_DEV=$(cat .current_loop_dev)
fi

echo "Unmounting ./mnt_root and ./mnt_boot..."
sudo umount ./mnt_root || echo "Warning: Could not unmount ./mnt_root"
sudo umount ./mnt_boot || echo "Warning: Could not unmount ./mnt_boot"

echo "Removing partition mappings from $LOOP_DEV..."
sudo kpartx -d "$LOOP_DEV" || echo "Warning: kpartx -d $LOOP_DEV failed"

echo "Detaching loop device $LOOP_DEV..."
sudo losetup -d "$LOOP_DEV" || echo "Warning: losetup -d $LOOP_DEV failed"

rm -f .current_loop_dev
echo "Cleanup complete. You may remove mnt_boot and mnt_root if desired (sudo rmdir mnt_boot mnt_root)."
