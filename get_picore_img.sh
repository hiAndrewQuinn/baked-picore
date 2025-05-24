#!/bin/bash
# ###################################################################
# Simplified piCore Image Retriever
# ###################################################################
set -e          # Exit immediately if a command exits with a non-zero status.
set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that failed.

# --- Global Configuration ---
DEFAULT_PICORE_URL="http://tinycorelinux.net/15.x/armhf/releases/RPi/piCore-15.0.0.zip"
# Cache directory for downloaded assets
CACHE_DIR="${HOME}/.cache/baked_picore_assets"
IMAGE_CACHE_DIR="${CACHE_DIR}/images"

# --- Helper Functions ---
log_info() {
  echo "INFO: $1"
}

log_error() {
  echo "ERROR: $1" >&2
}

# --- Main Script Flow ---
echo "Simplified piCore Image Retriever"

# 1. Check Dependencies (minimal)
if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
  log_error "Either 'wget' or 'curl' is required to download the image. Please install one."
  exit 1
fi
if ! command -v unzip &>/dev/null; then
  log_error "'unzip' is required to extract the image. Please install it."
  exit 1
fi

# 2. Ensure cache directory exists
mkdir -p "$IMAGE_CACHE_DIR"
log_info "Using cache directory: $IMAGE_CACHE_DIR"

# 3. Determine piCore source and filenames
PICORE_SOURCE_URL="$DEFAULT_PICORE_URL"
ZIP_FILENAME=$(basename "$PICORE_SOURCE_URL")
CACHED_ZIP_FILE_PATH="${IMAGE_CACHE_DIR}/${ZIP_FILENAME}"
LOCAL_ZIP_FILE_PATH="./${ZIP_FILENAME}" # Zip file in current working directory

# 4. Get the piCore ZIP file (from cache or download)
if [ -f "$CACHED_ZIP_FILE_PATH" ]; then
  log_info "Found cached piCore zip: ${CACHED_ZIP_FILE_PATH}"
  log_info "Copying to current directory: ${LOCAL_ZIP_FILE_PATH}..."
  cp "$CACHED_ZIP_FILE_PATH" "$LOCAL_ZIP_FILE_PATH"
else
  log_info "piCore zip not found in cache. Downloading from ${PICORE_SOURCE_URL}..."
  if command -v wget &>/dev/null; then
    if ! wget -O "$LOCAL_ZIP_FILE_PATH" "$PICORE_SOURCE_URL"; then
      log_error "Download failed with wget. Please check URL and network."
      rm -f "$LOCAL_ZIP_FILE_PATH" # Clean up partial download
      exit 1
    fi
  elif command -v curl &>/dev/null; then
    if ! curl -L -o "$LOCAL_ZIP_FILE_PATH" "$PICORE_SOURCE_URL"; then
      log_error "Download failed with curl. Please check URL and network."
      rm -f "$LOCAL_ZIP_FILE_PATH" # Clean up partial download
      exit 1
    fi
  fi
  log_info "Download complete: ${LOCAL_ZIP_FILE_PATH}"
  log_info "Caching downloaded zip to ${CACHED_ZIP_FILE_PATH}..."
  cp "$LOCAL_ZIP_FILE_PATH" "$CACHED_ZIP_FILE_PATH"
fi

# 5. Unzip the piCore image
EXTRACTION_DIR="./extracted_picore_image"
log_info "Extracting '${LOCAL_ZIP_FILE_PATH}' to '${EXTRACTION_DIR}'..."
mkdir -p "$EXTRACTION_DIR"
if ! unzip -o "$LOCAL_ZIP_FILE_PATH" -d "$EXTRACTION_DIR"; then
  log_error "Failed to unzip ${LOCAL_ZIP_FILE_PATH}"
  rm -rf "$EXTRACTION_DIR" # Clean up partial extraction
  exit 1
fi

# 6. Find and rename the .img file
#    The original script assumes the .img is the only one or can be easily found.
#    We'll use 'find' to locate it robustly within the extraction directory.
DECOMPRESSED_IMAGE_PATH_TEMP=$(find "$EXTRACTION_DIR" -name '*.img' -print -quit)

if [ -z "$DECOMPRESSED_IMAGE_PATH_TEMP" ]; then
  log_error "No .img file found in extracted archive at '${EXTRACTION_DIR}'."
  rm -rf "$EXTRACTION_DIR"
  exit 1
fi

OUTPUT_IMAGE_NAME="default-piCore.img"
log_info "Found image: ${DECOMPRESSED_IMAGE_PATH_TEMP}"
log_info "Moving to ./${OUTPUT_IMAGE_NAME} ..."
if ! mv "$DECOMPRESSED_IMAGE_PATH_TEMP" "./${OUTPUT_IMAGE_NAME}"; then
  log_error "Failed to move ${DECOMPRESSED_IMAGE_PATH_TEMP} to ./${OUTPUT_IMAGE_NAME}"
  rm -rf "$EXTRACTION_DIR"
  exit 1
fi

log_info "Successfully extracted and renamed image to: ./${OUTPUT_IMAGE_NAME}"

# 7. Cleanup
log_info "Cleaning up extraction directory: ${EXTRACTION_DIR}"
rm -rf "$EXTRACTION_DIR"
log_info "Local zip file '${LOCAL_ZIP_FILE_PATH}' can be removed if no longer needed."

log_info "Script finished successfully."
exit 0
