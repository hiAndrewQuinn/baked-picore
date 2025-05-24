#!/bin/bash
set -e
set -o pipefail

echo "RootFS CPIO Diagnostic Script"
echo "--------------------------------"

# --- Configuration ---
INPUT_ROOTFS_GZ="$1" # First argument: path to the .gz file to diagnose
# Example: ./mnt_boot/rootfs-piCore-15.0.gz (if run after mounting)
# Or a local copy: ./original_rootfs-piCore-15.0.gz

DIAG_WORKDIR="./cpio_diag_work"
ORIGINAL_DIR_NAME="original_rootfs_content"
REPACKED_DIR_NAME="repacked_rootfs_content"

# --- Sanity Checks and Setup ---
if [ -z "$INPUT_ROOTFS_GZ" ]; then
  echo "ERROR: No input rootfs.gz file specified."
  echo "Usage: $0 <path_to_rootfs.gz>"
  exit 1
fi

if [ ! -f "$INPUT_ROOTFS_GZ" ]; then
  echo "ERROR: Input file '$INPUT_ROOTFS_GZ' not found."
  exit 1
fi

# Check for necessary commands
for cmd in gunzip gzip cpio find mkdir rm diff; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Command '$cmd' not found. Please install it."
    exit 1
  fi
done

echo "INFO: Using input file: $INPUT_ROOTFS_GZ"
echo "INFO: Diagnostic work directory will be: $DIAG_WORKDIR"

# Clean up previous diagnostic run if it exists
if [ -d "$DIAG_WORKDIR" ]; then
  echo "INFO: Removing previous diagnostic directory: $DIAG_WORKDIR"
  sudo rm -rf "$DIAG_WORKDIR"
fi
mkdir -p "$DIAG_WORKDIR"
cd "$DIAG_WORKDIR"

# === Step 1: Analyze ORIGINAL rootfs.gz ===
echo ""
echo "=== Analyzing ORIGINAL: $INPUT_ROOTFS_GZ ==="
mkdir -p "$ORIGINAL_DIR_NAME"

echo "INFO: Decompressing original to original.cpio..."
gunzip -c "../$INPUT_ROOTFS_GZ" >original.cpio
if [ ! -s "original.cpio" ]; then
  echo "ERROR: Failed to decompress or original.cpio is empty."
  exit 1
fi

echo "INFO: Creating verbose CPIO listing (original_cpio_itv_listing.txt)..."
cpio -itv <original.cpio >original_cpio_itv_listing.txt 2>&1 || echo "WARN: cpio -itv for original had non-zero exit, check listing file."

echo "INFO: Extracting original.cpio to $ORIGINAL_DIR_NAME..."
(cd "$ORIGINAL_DIR_NAME" && cpio -i -d -H newc --no-absolute-filenames <../original.cpio)
echo "INFO: Original CPIO extracted."

echo "INFO: Generating ls -lR for original content (original_ls_lR.txt)..."
(cd "$ORIGINAL_DIR_NAME" && ls -lR >../original_ls_lR.txt)

echo "INFO: Generating ls -liR for original content (original_ls_liR.txt) (for inodes/hard links)..."
(cd "$ORIGINAL_DIR_NAME" && ls -liR >../original_ls_liR.txt)

# === Step 2: Repack and Analyze the REPACKED version ===
echo ""
echo "=== Repacking and Analyzing REPACKED version ==="
mkdir -p "$REPACKED_DIR_NAME"

echo "INFO: Re-creating CPIO archive (repacked_noop.cpio) from $ORIGINAL_DIR_NAME content using --reproducible..."
# Using the same cpio command as in the previous failing script
(cd "$ORIGINAL_DIR_NAME" && find . -depth | cpio --reproducible -o -H newc >../repacked_noop.cpio)
if [ ! -s "repacked_noop.cpio" ]; then
  echo "ERROR: Failed to create repacked_noop.cpio or it is empty."
  exit 1
fi

echo "INFO: Compressing repacked_noop.cpio to repacked_noop.gz..."
gzip -9 <repacked_noop.cpio >repacked_noop.gz
if [ ! -s "repacked_noop.gz" ]; then
  echo "ERROR: Failed to create repacked_noop.gz or it is empty."
  exit 1
fi

echo "INFO: Creating verbose CPIO listing for repacked (repacked_cpio_itv_listing.txt)..."
cpio -itv <repacked_noop.cpio >repacked_cpio_itv_listing.txt 2>&1 || echo "WARN: cpio -itv for repacked had non-zero exit, check listing file."

echo "INFO: Extracting repacked_noop.cpio to $REPACKED_DIR_NAME..."
(cd "$REPACKED_DIR_NAME" && cpio -i -d -H newc --no-absolute-filenames <../repacked_noop.cpio)
echo "INFO: Repacked CPIO extracted."

echo "INFO: Generating ls -lR for repacked content (repacked_ls_lR.txt)..."
(cd "$REPACKED_DIR_NAME" && ls -lR >../repacked_ls_lR.txt)

echo "INFO: Generating ls -liR for repacked content (repacked_ls_liR.txt) (for inodes/hard links)..."
(cd "$REPACKED_DIR_NAME" && ls -liR >../repacked_ls_liR.txt)

# === Step 3: Generate Diffs ===
echo ""
echo "=== Generating Diffs (check these files for differences) ==="

echo "INFO: Diffing CPIO listings (diff_cpio_itv_listings.txt)..."
diff -u original_cpio_itv_listing.txt repacked_cpio_itv_listing.txt >diff_cpio_itv_listings.txt || echo "INFO: CPIO listings differ (expected if --reproducible changes timestamps/owners)."

echo "INFO: Diffing ls -lR outputs (diff_ls_lR.txt)..."
diff -u original_ls_lR.txt repacked_ls_lR.txt >diff_ls_lR.txt || echo "INFO: ls -lR outputs differ."

echo "INFO: Diffing ls -liR outputs (diff_ls_liR.txt)..."
diff -u original_ls_liR.txt repacked_ls_liR.txt >diff_ls_liR.txt || echo "INFO: ls -liR outputs differ (check for inode changes indicating broken hard links)."

echo "INFO: Diffing the CPIO binary files (cmp_cpio_files.txt)..."
cmp -l original.cpio repacked_noop.cpio >cmp_cpio_files.txt || echo "INFO: CPIO binary files differ."
# Note: cmp output can be large if files differ significantly.

echo ""
echo "Diagnostic script finished."
echo "Please examine the files in the '$DIAG_WORKDIR' directory:"
echo "  - original_cpio_itv_listing.txt"
echo "  - repacked_cpio_itv_listing.txt"
echo "  - diff_cpio_itv_listings.txt"
echo ""
echo "  - original_ls_lR.txt"
echo "  - repacked_ls_lR.txt"
echo "  - diff_ls_lR.txt"
echo ""
echo "  - original_ls_liR.txt"
echo "  - repacked_ls_liR.txt"
echo "  - diff_ls_liR.txt"
echo ""
echo "  - cmp_cpio_files.txt (binary comparison)"
echo ""
echo "Pay close attention to permissions, ownership, file types (especially device files 'c' or 'b'),"
echo "major/minor numbers for device files, and differences in inode numbers for the same paths"
echo "(which could indicate issues with hard links)."

exit 0
