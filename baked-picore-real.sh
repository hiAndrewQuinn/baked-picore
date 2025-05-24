#!/bin/bash
# ###################################################################
# piCore Offline Image Customizer - Functional Script with Caching, Image Expansion & Dynamic WiFi TCZ
# ###################################################################
set -e
set -o pipefail
INITIAL_PWD_AT_SCRIPT_START=$(pwd) # Capture current directory at script start

# --- Global Configuration ---
DEFAULT_PICORE_URL="http://tinycorelinux.net/15.x/armhf/releases/RPi/piCore-15.0.0.zip"
PICORE_KERNEL_SERIES_PREFIX="6.6." # Used to glob wireless modules
FIXED_HOSTNAME="piCoreCustom"
FIXED_OUTPUT_IMAGE_BASENAME="customized-piCore"        # .img will be appended
TCE_REPO_URL="http://repo.tinycorelinux.net"           # Base repo URL
TCE_VERSION_PATH="15.x/armhf"                          # Specific version path
TCE_BASE_URL="${TCE_REPO_URL}/${TCE_VERSION_PATH}/tcz" # Full URL to TCZ directory

REQUIRED_PACKAGES_COMMON="openssh.tcz openssl.tcz"
REQUIRED_PACKAGES_WIFI="ca-certificates.tcz wifi.tcz wireless_tools.tcz wpa_supplicant.tcz libnl.tcz ncurses.tcz readline.tcz firmware-rpi-wifi.tcz ethtool.tcz"
NEW_TOTAL_IMAGE_SIZE_MB=1024 # Desired total size of the final .img file in MB

# Cache directories
CACHE_DIR="${HOME}/.cache/baked_picore_assets"
IMAGE_CACHE_DIR="${CACHE_DIR}/images"
TCZ_CACHE_DIR="${CACHE_DIR}/tczs"

# Temporary working directory
WORK_DIR=""
# Mount points
BOOT_MNT=""
ROOT_MNT=""
# Loop device
LOOP_DEV=""
# Interrupt handling
_interrupted_once=0

# --- Helper Functions ---
cleanup_exit() {
  local signal_name="${1:-EXIT}"
  local exit_status=$?

  if [ "$_interrupted_once" -eq 1 ] && [[ "$signal_name" == "INT" || "$signal_name" == "TERM" ]]; then
    echo ""
    log_info "Second interrupt ($signal_name) received. Exiting immediately."
    trap - EXIT INT TERM
    exit 130
  fi

  if [[ "$signal_name" == "INT" || "$signal_name" == "TERM" ]]; then
    _interrupted_once=1
    echo ""
    log_info "Interrupt ($signal_name) received. Cleaning up..."
  elif [ "$signal_name" == "EXIT" ] && [ "$exit_status" -ne 0 ]; then
    log_info "Script exiting due to an error (status $exit_status). Cleaning up..."
  else
    log_info "Cleaning up..."
  fi

  if [ -n "$LOOP_DEV" ]; then
    if mountpoint -q "$ROOT_MNT"; then
      sudo umount "$ROOT_MNT" || log_info "Warning: Could not unmount $ROOT_MNT"
    fi
    if mountpoint -q "$BOOT_MNT"; then
      sudo umount "$BOOT_MNT" || log_info "Warning: Could not unmount $BOOT_MNT"
    fi
    if losetup "$LOOP_DEV" &>/dev/null; then
      if sudo kpartx -l "$LOOP_DEV" 2>/dev/null | grep -q "$(basename "$LOOP_DEV")p"; then
        sudo kpartx -d "$LOOP_DEV" || log_info "Warning: kpartx -d $LOOP_DEV failed"
      else
        log_info "No kpartx mappings found for $LOOP_DEV to remove."
      fi
      sudo losetup -d "$LOOP_DEV" || log_info "Warning: losetup -d $LOOP_DEV failed"
    else
      log_info "Loop device $LOOP_DEV not active or already detached."
    fi
  fi
  if [ -d "$WORK_DIR" ]; then
    sudo rm -rf "$WORK_DIR"
    log_info "Working directory $WORK_DIR removed."
  fi
  log_info "Cleanup finished."

  if [ "$_interrupted_once" -eq 1 ]; then
    trap - EXIT INT TERM
    if [ "$signal_name" == "INT" ]; then exit 130; fi
    if [ "$signal_name" == "TERM" ]; then exit 143; fi
  fi
}

# Trap signals
trap 'cleanup_exit EXIT' EXIT
trap 'cleanup_exit INT' INT
trap 'cleanup_exit TERM' TERM

log_step() {
  echo -e "\n==> $1"
}

log_info() {
  echo "    $1"
}

check_dependencies() {
  log_info "Checking dependencies..."
  local missing_deps=0
  # Added date for timestamp
  local deps=("wget" "curl" "unzip" "gzip" "losetup" "kpartx" "fdisk" "mkfs.ext4" "truncate" "ssh-keygen" "partprobe" "mount" "umount" "blkid" "e2label" "sort" "find" "awk" "grep" "sed" "tee" "basename" "mktemp" "tr" "head" "id" "chpasswd" "nmcli" "realpath" "mkdir" "cp" "rm" "date")
  for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      log_info "Error: Command '$cmd' not found. Please install it (e.g., 'network-manager' for 'nmcli', 'coreutils' for 'truncate', 'util-linux' for 'fdisk')."
      missing_deps=1
    fi
  done
  if [ "$missing_deps" -eq 1 ]; then
    echo "Exiting due to missing dependencies."
    exit 1
  fi
  log_info "All dependencies found."
}

ask_user_yn() {
  local prompt_message="$1"
  local var_name="$2"
  local default_choice="$3"

  local yn_prompt="(y/n)"
  local full_prompt_message="$prompt_message $yn_prompt [${default_choice}]: "

  while true; do
    echo ""
    read -r -p "$full_prompt_message" "$var_name"
    eval "$var_name=\"\${$var_name:-$default_choice}\""
    if [[ "${!var_name}" == "y" || "${!var_name}" == "n" ]]; then
      break
    else
      log_info "Invalid input. Please enter 'y' or 'n'."
    fi
  done
}

ask_user() {
  local prompt_message="$1"
  local var_name="$2"
  local default_value="${3:-}"

  echo ""
  if [ -n "$default_value" ]; then
    read -r -p "$prompt_message [${default_value}]: " "$var_name"
    eval "$var_name=\"\${$var_name:-$default_value}\""
  else
    read -r -p "$prompt_message: " "$var_name"
  fi
}

download_and_stage_file() {
  local file_url="$1"
  local target_path="$2"
  local cache_path="$3"
  local file_basename="$4"

  if [ -f "$cache_path" ]; then
    log_info "    Using cached $file_basename..."
    sudo cp "$cache_path" "$target_path"
  else
    log_info "    Fetching $file_basename from $file_url ..."
    if ! sudo wget -q -O "$target_path" "$file_url"; then
      log_info "Warning: Failed to download ${file_basename} from ${file_url}. Continuing..."
      return 1
    else
      sudo mkdir -p "$(dirname "$cache_path")"
      sudo cp "$target_path" "$cache_path"
    fi
  fi
  return 0
}

generate_picore_info_json() {
  log_info "Generating baked-picore-info.json..."
  local json_file_path="${WORK_DIR}/baked-picore-info.json"
  # Timestamp format YYYY-MM-DD-HH-MM-SS
  BUILD_TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")

  # Basic sanitization for JSON string values (escape double quotes)
  local sanitized_picore_source=$(echo "$PICORE_SOURCE" | sed 's/"/\\"/g')
  # ORIGINAL_IMAGE_NAME_IN_WORK_DIR is the basename of the initial file (zip, gz, or img)
  local sanitized_original_input_filename=$(echo "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" | sed 's/"/\\"/g')
  local sanitized_decompressed_image_name=$(basename "$DECOMPRESSED_IMAGE_PATH" | sed 's/"/\\"/g')

  local sanitized_fixed_hostname=$(echo "$FIXED_HOSTNAME" | sed 's/"/\\"/g')
  local sanitized_fixed_output_basename=$(echo "$FIXED_OUTPUT_IMAGE_BASENAME" | sed 's/"/\\"/g')

  local sanitized_wifi_ssid=""
  if [ "$NET_TYPE" == "wifi" ]; then
    sanitized_wifi_ssid=$(echo "$WIFI_SSID" | sed 's/"/\\"/g')
  fi

  local wifi_psk_provided="false"
  if [ "$NET_TYPE" == "wifi" ] && [ -n "$WIFI_PSK" ]; then # Check if WIFI_PSK was set
    wifi_psk_provided="true"
  fi

  local ssh_key_generated_for_host_access="false"
  if [ "$SSH_CONFIG_TYPE" == "key" ] && [ -f "${GENERATED_PICORE_ACCESS_KEY_PATH}.pub" ]; then
    ssh_key_generated_for_host_access="true"
  fi

  local ssh_password_generated_for_tc_user="false"
  if [ "$SSH_CONFIG_TYPE" == "password" ] && [ -n "$GENERATED_SSH_PASSWORD" ]; then
    ssh_password_generated_for_tc_user="true"
  fi

  # Start JSON
  printf "{\n" >"$json_file_path"
  printf "  \"build_timestamp\": \"%s\",\n" "$BUILD_TIMESTAMP" >>"$json_file_path"

  # Image Source
  printf "  \"image_source_details\": {\n" >>"$json_file_path"
  printf "    \"user_provided_url_or_path\": \"%s\",\n" "$sanitized_picore_source" >>"$json_file_path"
  printf "    \"original_input_filename\": \"%s\",\n" "$sanitized_original_input_filename" >>"$json_file_path"
  printf "    \"decompressed_image_filename_used\": \"%s\"\n" "$sanitized_decompressed_image_name" >>"$json_file_path"
  printf "  },\n" >>"$json_file_path"

  # Image Settings
  printf "  \"image_settings\": {\n" >>"$json_file_path"
  printf "    \"target_expanded_size_mb\": %d,\n" "$NEW_TOTAL_IMAGE_SIZE_MB" >>"$json_file_path"
  printf "    \"final_output_image_basename\": \"%s\"\n" "$sanitized_fixed_output_basename" >>"$json_file_path"
  printf "  },\n" >>"$json_file_path"

  # Network Config
  printf "  \"network_configuration\": {\n" >>"$json_file_path"
  printf "    \"type\": \"%s\",\n" "$NET_TYPE" >>"$json_file_path"
  printf "    \"ip_assignment\": \"%s\"" "$IP_CONFIG_TYPE" >>"$json_file_path"
  if [ "$NET_TYPE" == "wifi" ]; then
    printf ",\n" >>"$json_file_path"
    printf "    \"wifi_ssid\": \"%s\",\n" "$sanitized_wifi_ssid" >>"$json_file_path"
    printf "    \"wifi_psk_provided\": %s" "$wifi_psk_provided" >>"$json_file_path"
  fi
  if [ "$IP_CONFIG_TYPE" == "static" ]; then
    printf ",\n" >>"$json_file_path"
    printf "    \"static_ip\": \"%s\",\n" "$(echo "$STATIC_IP" | sed 's/"/\\"/g')" >>"$json_file_path"
    printf "    \"subnet_mask\": \"%s\",\n" "$(echo "$SUBNET_MASK" | sed 's/"/\\"/g')" >>"$json_file_path"
    printf "    \"gateway_ip\": \"%s\",\n" "$(echo "$GATEWAY_IP" | sed 's/"/\\"/g')" >>"$json_file_path"
    printf "    \"dns_server\": \"%s\"" "$(echo "$DNS_SERVER" | sed 's/"/\\"/g')" >>"$json_file_path"
  fi
  printf "\n  },\n" >>"$json_file_path"

  # System Config
  printf "  \"system_configuration\": {\n" >>"$json_file_path"
  printf "    \"hostname\": \"%s\"\n" "$sanitized_fixed_hostname" >>"$json_file_path"
  printf "  },\n" >>"$json_file_path"

  # SSH Config
  printf "  \"ssh_configuration\": {\n" >>"$json_file_path"
  printf "    \"access_type\": \"%s\",\n" "$SSH_CONFIG_TYPE" >>"$json_file_path"
  printf "    \"client_access_key_generated_on_host\": %s,\n" "$ssh_key_generated_for_host_access" >>"$json_file_path"
  printf "    \"tc_user_password_generated_for_first_boot\": %s\n" "$ssh_password_generated_for_tc_user" >>"$json_file_path"
  printf "  },\n" >>"$json_file_path"

  # TCZ Package Config
  printf "  \"tcz_package_configuration\": {\n" >>"$json_file_path"
  printf "    \"tce_repository_base_url\": \"%s\",\n" "$(echo "$TCE_REPO_URL" | sed 's/"/\\"/g')" >>"$json_file_path"
  printf "    \"tce_repository_version_path\": \"%s\",\n" "$(echo "$TCE_VERSION_PATH" | sed 's/"/\\"/g')" >>"$json_file_path"
  printf "    \"common_packages_onboot\": [" "$(echo "$REQUIRED_PACKAGES_COMMON" | awk '{for(i=1;i<=NF;i++) printf (i==NF ? "\"%s\"" : "\"%s\", "), $i}')" "],\n" >>"$json_file_path"

  local wifi_packages_json_array="[]"
  if [ "$NET_TYPE" == "wifi" ] && [ -n "$REQUIRED_PACKAGES_WIFI" ]; then
    wifi_packages_json_array="[ $(echo "$REQUIRED_PACKAGES_WIFI" | awk '{for(i=1;i<=NF;i++) printf (i==NF ? "\"%s\"" : "\"%s\", "), $i}') ]"
  fi
  printf "    \"wifi_specific_packages_onboot\": %s,\n" "$wifi_packages_json_array" >>"$json_file_path"
  printf "    \"kernel_series_prefix_for_wireless_modules\": \"%s\"\n" "$(echo "$PICORE_KERNEL_SERIES_PREFIX" | sed 's/"/\\"/g')" >>"$json_file_path"
  printf "  }\n" >>"$json_file_path" # No comma for the last main entry in the main object

  # End JSON
  printf "}\n" >>"$json_file_path"
  log_info "baked-picore-info.json generated at ${json_file_path}"
}

# --- Main Script Flow ---

echo "Welcome to the piCore Offline Image Customizer."
echo "This script will modify a piCore image."
echo "IMPORTANT: This script must be run with sudo or as root."

if [ "$(id -u)" -ne 0 ]; then
  log_info "Error: This script must be run as root or with sudo."
  exit 1
fi

check_dependencies

mkdir -p "$IMAGE_CACHE_DIR"
mkdir -p "$TCZ_CACHE_DIR"
log_info "Asset cache directory: $CACHE_DIR"

WORK_DIR=$(mktemp -d)
log_info "Working directory: $WORK_DIR"
cd "$WORK_DIR"

# 1. Collect User Inputs
log_step "Phase 1: Gathering Configuration Details"

echo ""
log_info "The script will attempt to download or use cached piCore for Raspberry Pi."
ask_user "Use this URL for piCore image? (or provide your own URL/local path)" PICORE_SOURCE "$DEFAULT_PICORE_URL"

ORIGINAL_IMAGE_NAME_IN_WORK_DIR="" # This will store the basename of the initial download/local file
DECOMPRESSED_IMAGE_PATH=""         # This will store the path to the .img file after potential extraction/decompression

if [[ "$PICORE_SOURCE" == http* ]]; then
  ORIGINAL_IMAGE_NAME_IN_WORK_DIR=$(basename "$PICORE_SOURCE")
  CACHED_IMAGE_PATH="${IMAGE_CACHE_DIR}/${ORIGINAL_IMAGE_NAME_IN_WORK_DIR}"

  if [ -f "$CACHED_IMAGE_PATH" ]; then
    log_info "Found cached image: ${CACHED_IMAGE_PATH}"
    log_info "Copying to working directory..."
    cp "$CACHED_IMAGE_PATH" "./$ORIGINAL_IMAGE_NAME_IN_WORK_DIR"
  else
    log_info "Downloading '${PICORE_SOURCE}' to ${WORK_DIR}/${ORIGINAL_IMAGE_NAME_IN_WORK_DIR}..."
    if command -v wget &>/dev/null; then
      if ! wget -O "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" "$PICORE_SOURCE"; then
        log_info "Error: Download failed with wget. Please check URL and network."
        exit 1
      fi
    elif command -v curl &>/dev/null; then
      if ! curl -L -o "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" "$PICORE_SOURCE"; then
        log_info "Error: Download failed with curl. Please check URL and network."
        exit 1
      fi
    else
      log_info "Error: Neither wget nor curl found for downloading."
      exit 1
    fi
    log_info "   Download complete: $ORIGINAL_IMAGE_NAME_IN_WORK_DIR"
    log_info "   Caching downloaded image to ${CACHED_IMAGE_PATH}..."
    cp "./$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" "$CACHED_IMAGE_PATH"
  fi

  if [[ "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" == *.zip ]]; then
    log_info "Extracting '${ORIGINAL_IMAGE_NAME_IN_WORK_DIR}'..."
    if ! unzip -o "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" -d extracted_image; then
      log_info "Error: Failed to unzip $ORIGINAL_IMAGE_NAME_IN_WORK_DIR"
      exit 1
    fi
    DECOMPRESSED_IMAGE_PATH_TEMP=$(find extracted_image -name '*.img' -print -quit)
    if [ -z "$DECOMPRESSED_IMAGE_PATH_TEMP" ]; then
      log_info "Error: No .img file found in extracted archive."
      exit 1
    fi
    mv "$DECOMPRESSED_IMAGE_PATH_TEMP" .
    DECOMPRESSED_IMAGE_PATH="./$(basename "$DECOMPRESSED_IMAGE_PATH_TEMP")"
    rm -rf extracted_image
    log_info "   Extraction complete, image at: ${DECOMPRESSED_IMAGE_PATH}"
  elif [[ "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" == *.img.gz ]]; then
    log_info "Decompressing '${ORIGINAL_IMAGE_NAME_IN_WORK_DIR}'..."
    DECOMPRESSED_IMAGE_PATH="./${ORIGINAL_IMAGE_NAME_IN_WORK_DIR%.gz}"
    if ! gunzip -k -f "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR"; then # -k to keep original .gz
      log_info "Error: Failed to decompress $ORIGINAL_IMAGE_NAME_IN_WORK_DIR"
      exit 1
    fi
    log_info "   Decompression complete, image at: ${DECOMPRESSED_IMAGE_PATH}"
  elif [[ "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" == *.img ]]; then
    DECOMPRESSED_IMAGE_PATH="./$ORIGINAL_IMAGE_NAME_IN_WORK_DIR"
  else
    log_info "Error: Unrecognized image format from URL: $ORIGINAL_IMAGE_NAME_IN_WORK_DIR"
    exit 1
  fi
else # Local file
  if [ ! -f "$PICORE_SOURCE" ]; then
    log_info "Error: Local file not found: $PICORE_SOURCE"
    exit 1
  fi
  log_info "Using local piCore source: '${PICORE_SOURCE}'"
  ORIGINAL_IMAGE_NAME_IN_WORK_DIR=$(basename "$PICORE_SOURCE")

  # Copy to work_dir if not already there
  if [ "$(realpath "$PICORE_SOURCE")" != "$(realpath "$WORK_DIR/$ORIGINAL_IMAGE_NAME_IN_WORK_DIR")" ]; then
    cp "$PICORE_SOURCE" "$WORK_DIR/$ORIGINAL_IMAGE_NAME_IN_WORK_DIR"
  fi

  if [[ "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" == *.zip ]]; then
    log_info "Extracting local '${ORIGINAL_IMAGE_NAME_IN_WORK_DIR}'..."
    unzip -o "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" -d extracted_image
    DECOMPRESSED_IMAGE_PATH_TEMP=$(find extracted_image -name '*.img' -print -quit)
    if [ -z "$DECOMPRESSED_IMAGE_PATH_TEMP" ]; then
      log_info "Error: No .img file found."
      exit 1
    fi
    mv "$DECOMPRESSED_IMAGE_PATH_TEMP" .
    DECOMPRESSED_IMAGE_PATH="./$(basename "$DECOMPRESSED_IMAGE_PATH_TEMP")"
    rm -rf extracted_image
    log_info "   Extraction complete, image at: ${DECOMPRESSED_IMAGE_PATH}"
  elif [[ "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" == *.img.gz ]]; then
    log_info "Decompressing local '${ORIGINAL_IMAGE_NAME_IN_WORK_DIR}'..."
    DECOMPRESSED_IMAGE_PATH="./${ORIGINAL_IMAGE_NAME_IN_WORK_DIR%.gz}"
    gunzip -k -f "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" # -k to keep original .gz
    log_info "   Decompression complete, image at: ${DECOMPRESSED_IMAGE_PATH}"
  elif [[ "$ORIGINAL_IMAGE_NAME_IN_WORK_DIR" == *.img ]]; then
    DECOMPRESSED_IMAGE_PATH="./$ORIGINAL_IMAGE_NAME_IN_WORK_DIR"
  else
    log_info "Error: Unrecognized local file format: $ORIGINAL_IMAGE_NAME_IN_WORK_DIR. Must be .zip, .img.gz, or .img."
    exit 1
  fi
fi

if [ -z "$DECOMPRESSED_IMAGE_PATH" ] || [ ! -f "$DECOMPRESSED_IMAGE_PATH" ]; then
  log_info "Error: Could not obtain a valid .img file. Path: '${DECOMPRESSED_IMAGE_PATH}'"
  exit 1
fi
log_info "Proceeding with image: ${DECOMPRESSED_IMAGE_PATH}"

NEW_TOTAL_IMAGE_SIZE_BYTES=$((NEW_TOTAL_IMAGE_SIZE_MB * 1024 * 1024))
log_info "Expanding image file '${DECOMPRESSED_IMAGE_PATH}' to ${NEW_TOTAL_IMAGE_SIZE_MB}MB..."
if ! sudo truncate -s "$NEW_TOTAL_IMAGE_SIZE_BYTES" "$DECOMPRESSED_IMAGE_PATH"; then
  log_info "Error: Failed to expand image file using truncate."
  exit 1
fi
log_info "   Image file expanded."

echo ""
log_info "SD Card Size Confirmation:"
log_info "   This script bakes in various packages for initial setup (like Wi-Fi)."
log_info "   Please ensure the SD card you intend to use is at least ${NEW_TOTAL_IMAGE_SIZE_MB}MB in size (target image size)."
log_info "   This is for storage space, not RAM requirements."
ask_user_yn "Is your target SD card at least ${NEW_TOTAL_IMAGE_SIZE_MB}MB in size?" SD_CARD_BIG_ENOUGH "y"

if [ "$SD_CARD_BIG_ENOUGH" == "n" ]; then
  log_info "Error: Target SD card is too small for the expanded image. Exiting."
  exit 1
fi
log_info "   SD card size confirmed as adequate for the ${NEW_TOTAL_IMAGE_SIZE_MB}MB image."

echo ""
log_info "Network Configuration:"
ask_user "Network type? (wifi/ethernet):" NET_TYPE "wifi"

WIFI_SSID=""
WIFI_PSK=""
DEFAULT_WIFI_SSID=""

if [ "$NET_TYPE" == "wifi" ]; then
  echo ""
  if command -v nmcli &>/dev/null; then
    log_info "Scanning for Wi-Fi networks using nmcli..."
    wifi_scan_output=$(nmcli --mode multiline --fields SSID,IN-USE device wifi list --rescan yes 2>/dev/null || echo "SCAN_FAILED")

    available_ssids=()
    current_ssid=""

    if [ "$wifi_scan_output" != "SCAN_FAILED" ] && [ -n "$wifi_scan_output" ]; then
      log_info "Available Wi-Fi networks:"
      temp_ssid=""
      while IFS= read -r line; do
        if [[ "$line" == SSID:* ]]; then
          temp_ssid="${line#SSID:}"
          temp_ssid=$(echo "$temp_ssid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        elif [[ "$line" == IN-USE:* ]]; then
          in_use_marker="${line#IN-USE:}"
          in_use_marker=$(echo "$in_use_marker" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

          if [ -n "$temp_ssid" ] && [[ "$temp_ssid" != "--" ]]; then
            is_connected=""
            if [[ "$in_use_marker" == "*" ]]; then
              is_connected=" (Currently Connected)"
              current_ssid="$temp_ssid"
            fi

            is_present=false
            for existing_ssid in "${available_ssids[@]}"; do
              if [[ "$existing_ssid" == "$temp_ssid" ]]; then
                is_present=true
                break
              fi
            done
            if ! $is_present; then
              available_ssids+=("$temp_ssid")
              log_info "   $((${#available_ssids[@]})) $temp_ssid$is_connected"
            fi
          fi
          temp_ssid=""
        fi
      done <<<"$wifi_scan_output"

      if [ -n "$current_ssid" ]; then
        DEFAULT_WIFI_SSID="$current_ssid"
      elif [ ${#available_ssids[@]} -gt 0 ]; then
        DEFAULT_WIFI_SSID="${available_ssids[0]}"
      fi
    else
      log_info "Could not scan for Wi-Fi networks or no networks found. Please enter SSID manually."
    fi
  else
    log_info "nmcli not found. Simulating Wi-Fi scan..."
    log_info "   Available networks (simulated):"
    log_info "     1. MyHomeNetwork (Currently Connected)"
    log_info "     2. NeighborsWifi_5G"
    DEFAULT_WIFI_SSID="MyHomeNetwork"
  fi
  ask_user "   Enter Wi-Fi SSID:" WIFI_SSID "$DEFAULT_WIFI_SSID"
  ask_user "   Enter Wi-Fi Password/PSK for '${WIFI_SSID}':" WIFI_PSK
fi

ask_user "   Configure IP for '${NET_TYPE}'? (dhcp/static):" IP_CONFIG_TYPE "dhcp"
STATIC_IP=""
SUBNET_MASK=""
GATEWAY_IP=""
DNS_SERVER=""
if [ "$IP_CONFIG_TYPE" == "static" ]; then
  ask_user "     Enter static IP address (e.g., 192.168.1.100):" STATIC_IP
  ask_user "     Enter subnet mask (e.g., 255.255.255.0):" SUBNET_MASK
  ask_user "     Enter gateway address (e.g., 192.168.1.1):" GATEWAY_IP
  ask_user "     Enter DNS server (e.g., 192.168.1.1 or 8.8.8.8):" DNS_SERVER
fi

echo ""
log_info "SSH Configuration:"
ask_user "How to configure SSH access to the piCore image? (key/password):" SSH_CONFIG_TYPE "key"

GENERATED_SSH_PASSWORD=""
GENERATED_PICORE_ACCESS_KEY_PATH="${WORK_DIR}/${FIXED_HOSTNAME}_id_rsa"

if [ "$SSH_CONFIG_TYPE" == "key" ]; then
  echo ""
  log_info "   Key-based SSH access selected."
  log_info "   Generating a new SSH key pair for accessing the piCore image..."
  ssh-keygen -t rsa -b 4096 -f "${GENERATED_PICORE_ACCESS_KEY_PATH}" -N "" -C "piCoreAccessKey@${FIXED_HOSTNAME}"
  log_info "   Generated private key: ${GENERATED_PICORE_ACCESS_KEY_PATH}"
  log_info "   Generated public key:  ${GENERATED_PICORE_ACCESS_KEY_PATH}.pub"
  log_info "   The public key will be installed on the piCore image."
  log_info "   The private key above should be used to connect to the piCore image."
elif [ "$SSH_CONFIG_TYPE" == "password" ]; then
  echo ""
  log_info "   Password-based SSH access selected."
  GENERATED_SSH_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
  log_info "   Generated password for 'tc' user: ${GENERATED_SSH_PASSWORD}"
  log_info "   IMPORTANT: Make a note of this password!"
fi

# Generate the JSON info file after all inputs are collected
generate_picore_info_json

# --- Phase 2: Image Customization ---
log_step "Phase 2: Image Customization"
echo ""
log_info "Hostname will be set to: '${FIXED_HOSTNAME}'"
log_info "Output image will be: '${INITIAL_PWD_AT_SCRIPT_START}/${FIXED_OUTPUT_IMAGE_BASENAME}.img' (Total size: ${NEW_TOTAL_IMAGE_SIZE_MB}MB)"
echo ""

log_info "Setting up loop device for '${DECOMPRESSED_IMAGE_PATH}'..."
LOOP_DEV=$(sudo losetup -fP --show "${DECOMPRESSED_IMAGE_PATH}")
if [ -z "$LOOP_DEV" ]; then
  log_info "Error: Failed to set up loop device for ${DECOMPRESSED_IMAGE_PATH}"
  exit 1
fi
log_info "   Loop device: ${LOOP_DEV}"
sudo partprobe "$LOOP_DEV"

log_info "Mapping partitions from ${LOOP_DEV} using kpartx..."
sudo kpartx -v -a -s "$LOOP_DEV"

BOOT_PART_DEV="/dev/mapper/$(basename "$LOOP_DEV")p1"
ROOT_PART_DEV="/dev/mapper/$(basename "$LOOP_DEV")p2"

BOOT_MNT="${WORK_DIR}/mnt_boot"
ROOT_MNT="${WORK_DIR}/mnt_root"
sudo mkdir -p "$BOOT_MNT" "$ROOT_MNT"

log_info "Mounting boot partition (${BOOT_PART_DEV})..."
if ! sudo mount "$BOOT_PART_DEV" "$BOOT_MNT"; then
  log_info "Error: Failed to mount boot partition ${BOOT_PART_DEV}"
  exit 1
fi
log_info "   Boot partition mounted at ${BOOT_MNT}"

log_info "Configuring second partition to fill remaining space in ${NEW_TOTAL_IMAGE_SIZE_MB}MB image..."
IMG_TOTAL_SECTORS=$(sudo fdisk -l "$LOOP_DEV" | grep "^Disk $LOOP_DEV:" | grep sectors | awk '{print $7}')
P1_DEVICE_FSKNAME="${LOOP_DEV}p1"
P1_INFO_LINE=$(sudo fdisk -l "$LOOP_DEV" | grep "^${P1_DEVICE_FSKNAME}[[:space:]]")

if [ -z "$P1_INFO_LINE" ]; then
  log_info "Error: Could not find boot partition information for ${P1_DEVICE_FSKNAME} in fdisk output."
  sudo fdisk -l "$LOOP_DEV" || log_info " (fdisk -l also failed or produced no output)"
  exit 1
fi

P1_START_SECTOR=$(echo "$P1_INFO_LINE" | awk '{print $2}')
P1_END_SECTOR=$(echo "$P1_INFO_LINE" | awk '{print $3}')

if ! [[ "$P1_START_SECTOR" =~ ^[0-9]+$ ]] || ! [[ "$P1_END_SECTOR" =~ ^[0-9]+$ ]]; then
  log_info "Error: Failed to parse valid start/end sectors for partition p1."
  exit 1
fi

P2_START_SECTOR=$((P1_END_SECTOR + 2048))

if ! [[ "$P2_START_SECTOR" =~ ^[0-9]+$ ]] || [ "$P2_START_SECTOR" -le 0 ] || [ "$P2_START_SECTOR" -ge "$IMG_TOTAL_SECTORS" ]; then
  log_info "Error: Invalid calculated start sector for P2. Start: $P2_START_SECTOR, Total: $IMG_TOTAL_SECTORS"
  exit 1
fi

log_info "   Re-partitioning ${LOOP_DEV} using fdisk (non-interactive)..."
sudo fdisk "$LOOP_DEV" <<EOF >/dev/null 2>&1
d
2
n
p
2
$P2_START_SECTOR

N
t
2
83
w
EOF
log_info "   fdisk re-partitioning complete."
sudo partprobe "$LOOP_DEV"
sudo kpartx -d "$LOOP_DEV" >/dev/null 2>&1 || true
sudo kpartx -v -a -s "$LOOP_DEV"

log_info "Formatting ${ROOT_PART_DEV} as ext4..."
if ! sudo mkfs.ext4 -F "$ROOT_PART_DEV"; then
  log_info "Error: Failed to format ${ROOT_PART_DEV} as ext4."
  exit 1
fi
log_info "   ${ROOT_PART_DEV} formatted."

log_info "Mounting root/data partition (${ROOT_PART_DEV})..."
if ! sudo mount "$ROOT_PART_DEV" "$ROOT_MNT"; then
  log_info "Error: Failed to mount root/data partition ${ROOT_PART_DEV}"
  exit 1
fi
log_info "   Root/data partition mounted at ${ROOT_MNT}"

sudo mkdir -p "${ROOT_MNT}/home/tc" "${ROOT_MNT}/opt" "${ROOT_MNT}/etc" "${ROOT_MNT}/tmp"
sudo chmod 1777 "${ROOT_MNT}/tmp"
sudo chown 1001:50 "${ROOT_MNT}/home/tc"
sudo mkdir -p "${ROOT_MNT}/tce/optional"

PART_UUID=$(sudo blkid -s UUID -o value "$ROOT_PART_DEV")
if [ -n "$PART_UUID" ]; then
  if [ -f "${BOOT_MNT}/cmdline.txt" ]; then
    CMDLINE_CONTENT=$(cat "${BOOT_MNT}/cmdline.txt")
    if echo "$CMDLINE_CONTENT" | grep -q "tce=UUID="; then
      NEW_CMDLINE=$(echo "$CMDLINE_CONTENT" | sed "s|tce=UUID=[^ ]*|tce=UUID=${PART_UUID}|")
    elif echo "$CMDLINE_CONTENT" | grep -q "tce="; then
      NEW_CMDLINE=$(echo "$CMDLINE_CONTENT" | sed "s|tce=[^ ]*|tce=UUID=${PART_UUID}|")
    else
      NEW_CMDLINE="${CMDLINE_CONTENT} tce=UUID=${PART_UUID}"
    fi
    echo "$NEW_CMDLINE" | sudo tee "${BOOT_MNT}/cmdline.txt" >/dev/null
    log_info "   Configured cmdline.txt to use UUID=${PART_UUID} for TCE persistence."
  else
    log_info "Warning: ${BOOT_MNT}/cmdline.txt not found."
  fi
else
  log_info "Warning: Could not get UUID for ${ROOT_PART_DEV}."
fi

log_info "Configuring hostname to '${FIXED_HOSTNAME}'..."
echo "${FIXED_HOSTNAME}" | sudo tee "${ROOT_MNT}/etc/hostname" >/dev/null
sudo mkdir -p "${ROOT_MNT}/opt"
echo "etc/hostname" | sudo tee -a "${ROOT_MNT}/opt/.filetool.lst" >/dev/null

log_info "Copying baked-picore-info.json to image..."
sudo cp "${WORK_DIR}/baked-picore-info.json" "${ROOT_MNT}/home/tc/baked-picore-info.json"
sudo chown 1001:50 "${ROOT_MNT}/home/tc/baked-picore-info.json" # tc:staff
sudo chmod 644 "${ROOT_MNT}/home/tc/baked-picore-info.json"
echo "home/tc/baked-picore-info.json" | sudo tee -a "${ROOT_MNT}/opt/.filetool.lst" >/dev/null
log_info "   baked-picore-info.json configured for persistence."

log_info "Injecting Network Configuration (${NET_TYPE})..."
if [ ! -f "${ROOT_MNT}/opt/bootlocal.sh" ]; then
  echo '#!/bin/sh' | sudo tee "${ROOT_MNT}/opt/bootlocal.sh" >/dev/null
  echo 'sudo /usr/local/etc/init.d/openssh start # Start SSHD' | sudo tee -a "${ROOT_MNT}/opt/bootlocal.sh" >/dev/null
fi

if [ "$NET_TYPE" == "wifi" ]; then
  sudo mkdir -p "${ROOT_MNT}/opt/wpa_supplicant"
  WPA_CONF_PATH="${ROOT_MNT}/opt/wpa_supplicant/wpa_supplicant.conf"
  log_info "   Creating ${WPA_CONF_PATH} for Wi-Fi..."
  cat <<EOF | sudo tee "$WPA_CONF_PATH" >/dev/null
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=staff
update_config=1
country=US 

network={
    ssid="${WIFI_SSID}"
    psk="${WIFI_PSK}"
}
EOF
  echo "opt/wpa_supplicant/wpa_supplicant.conf" | sudo tee -a "${ROOT_MNT}/opt/.filetool.lst" >/dev/null
  cat <<EOF | sudo tee "${ROOT_MNT}/opt/wifi-connect.sh" >/dev/null
#!/bin/sh
MAX_RETRIES=10 
RETRY_COUNT=0
WLAN_IFACE="wlan0" 

for iface in \$(ip -o link show | awk -F': ' '{print \$2}'); do
    if ethtool -i \$iface 2>/dev/null | grep -iq 'driver: brcmfmac'; then 
        WLAN_IFACE=\$iface
        echo "Detected RPi WLAN interface: \$WLAN_IFACE based on brcmfmac driver"
        break
    fi
    if command -v iw &> /dev/null && iw dev \$iface info &>/dev/null; then
        WLAN_IFACE=\$iface
        echo "Detected WLAN interface: \$WLAN_IFACE using iw dev"
        break
    fi
done
echo "Using WLAN interface: \$WLAN_IFACE for Wi-Fi setup."

while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
    if ip link show \$WLAN_IFACE &> /dev/null; then
        if ! ip link show \$WLAN_IFACE up | grep -q "UP"; then
            echo "Bringing up \$WLAN_IFACE..."
            sudo ip link set \$WLAN_IFACE up
            sleep 2 
        fi
        break 
    fi
    echo "\$WLAN_IFACE not found, retrying... (\$((RETRY_COUNT+1))/\$MAX_RETRIES)"
    sleep 3
    RETRY_COUNT=\$((RETRY_COUNT+1))
done

if ! ip link show \$WLAN_IFACE up | grep -q "UP"; then
    echo "Failed to bring up \$WLAN_IFACE after \$MAX_RETRIES attempts."
    exit 1
fi

if ! iwgetid -r \$WLAN_IFACE > /dev/null 2>&1; then
    echo "Starting wpa_supplicant for \$WLAN_IFACE..."
    sudo wpa_supplicant -B -i \$WLAN_IFACE -c /opt/wpa_supplicant/wpa_supplicant.conf -D nl80211,wext
    sleep 8 
fi

if [ "$IP_CONFIG_TYPE" == "dhcp" ]; then
    if ! iwgetid -r \$WLAN_IFACE > /dev/null 2>&1; then
        echo "Still not connected to Wi-Fi on \$WLAN_IFACE after wpa_supplicant start. Cannot run DHCP."
    else
        echo "Attempting DHCP on \$WLAN_IFACE..."
        sudo udhcpc -i \$WLAN_IFACE -q -b 
    fi
else 
    echo "Setting static IP for \$WLAN_IFACE..."
    sudo ip addr flush dev \$WLAN_IFACE
    sudo ip addr add ${STATIC_IP}/${SUBNET_MASK} dev \$WLAN_IFACE
    sudo ip route add default via ${GATEWAY_IP}
    echo "nameserver ${DNS_SERVER}" | sudo tee /etc/resolv.conf > /dev/null
    # Persist /etc/resolv.conf for static IP. It's usually symlinked from /usr/local/etc/resolv.conf
    # So we persist the target if it's a symlink, or the file itself.
    # For piCore, /etc/resolv.conf is often what we want to save.
    echo "etc/resolv.conf" | sudo tee -a "${ROOT_MNT}/opt/.filetool.lst" > /dev/null
fi
EOF
  sudo chmod +x "${ROOT_MNT}/opt/wifi-connect.sh"
  echo "/opt/wifi-connect.sh &" | sudo tee -a "${ROOT_MNT}/opt/bootlocal.sh" >/dev/null

  echo "!!! BODGE: Copying ${ROOT_MNT}/opt/wifi-connect.sh to ${BOOT_MNT}/opt/wifi-connect.sh. See if it shows up on your Pi, now."
  mkdir -p ${BOOT_MNT}/opt/
  cp "${ROOT_MNT}/opt/wifi-connect.sh" "${BOOT_MNT}/opt/wifi-connect.sh"

elif [ "$NET_TYPE" == "ethernet" ]; then
  if [ "$IP_CONFIG_TYPE" == "dhcp" ]; then
    echo "sudo udhcpc -i eth0 -q -b # Ethernet DHCP" | sudo tee -a "${ROOT_MNT}/opt/bootlocal.sh" >/dev/null
  elif [ "$IP_CONFIG_TYPE" == "static" ]; then
    cat <<EOF | sudo tee "${ROOT_MNT}/opt/eth0-static.sh" >/dev/null
#!/bin/sh
echo "Setting static IP for eth0..."
sudo ip link set eth0 up
sleep 2
sudo ip addr flush dev eth0
sudo ip addr add ${STATIC_IP}/${SUBNET_MASK} dev eth0
sudo ip route add default via ${GATEWAY_IP}
echo "nameserver ${DNS_SERVER}" | sudo tee /etc/resolv.conf > /dev/null
echo "etc/resolv.conf" | sudo tee -a "${ROOT_MNT}/opt/.filetool.lst" > /dev/null 
EOF
    sudo chmod +x "${ROOT_MNT}/opt/eth0-static.sh"
    echo "/opt/eth0-static.sh" | sudo tee -a "${ROOT_MNT}/opt/bootlocal.sh" >/dev/null
  fi
fi
echo "opt/bootlocal.sh" | sudo tee -a "${ROOT_MNT}/opt/.filetool.lst" >/dev/null
sudo chmod +x "${ROOT_MNT}/opt/bootlocal.sh"

log_info "Setting up SSH on piCore image (${SSH_CONFIG_TYPE})..."
sudo mkdir -p "${ROOT_MNT}/home/tc/.ssh"
sudo mkdir -p "${ROOT_MNT}/etc/ssh"

log_info "   Generating SSH host keys for the image..."
sudo ssh-keygen -A -f "${ROOT_MNT}"
echo "etc/ssh" | sudo tee -a "${ROOT_MNT}/opt/.filetool.lst" >/dev/null

if [ "$SSH_CONFIG_TYPE" == "key" ]; then
  log_info "   Installing generated public key to piCore image for key-based SSH..."
  sudo cp "${GENERATED_PICORE_ACCESS_KEY_PATH}.pub" "${ROOT_MNT}/home/tc/.ssh/authorized_keys"
  log_info "   Public key installed."
elif [ "$SSH_CONFIG_TYPE" == "password" ]; then
  log_info "   Configuring first-boot password change for 'tc' user..."
  echo "echo \"tc:${GENERATED_SSH_PASSWORD}\" | sudo chpasswd" | sudo tee -a "${ROOT_MNT}/opt/bootlocal.sh" >/dev/null
  log_info "   Password will be set on first boot."
fi
sudo chown -R 1001:50 "${ROOT_MNT}/home/tc/.ssh"
sudo chmod 700 "${ROOT_MNT}/home/tc/.ssh"
if [ -f "${ROOT_MNT}/home/tc/.ssh/authorized_keys" ]; then
  sudo chmod 600 "${ROOT_MNT}/home/tc/.ssh/authorized_keys"
fi
echo "home/tc/.ssh" | sudo tee -a "${ROOT_MNT}/opt/.filetool.lst" >/dev/null

log_info "Downloading and staging TCZ extensions..."
sudo mkdir -p "${ROOT_MNT}/tce/optional"
sudo mkdir -p "${BOOT_MNT}/tce"

ALL_REQUIRED_PACKAGES="$REQUIRED_PACKAGES_COMMON"
if [ "$NET_TYPE" == "wifi" ]; then
  ALL_REQUIRED_PACKAGES="$ALL_REQUIRED_PACKAGES $REQUIRED_PACKAGES_WIFI"
fi

sudo rm -f "${BOOT_MNT}/tce/onboot.lst"
sudo touch "${BOOT_MNT}/tce/onboot.lst"

for pkg_file_full in $ALL_REQUIRED_PACKAGES; do
  pkg_basename=$(basename "$pkg_file_full")
  if download_and_stage_file "${TCE_BASE_URL}/${pkg_file_full}" \
    "${ROOT_MNT}/tce/optional/${pkg_basename}" \
    "${TCZ_CACHE_DIR}/${pkg_basename}" \
    "$pkg_basename"; then
    echo "$pkg_file_full" | sudo tee -a "${BOOT_MNT}/tce/onboot.lst"
  fi

  download_and_stage_file "${TCE_BASE_URL}/${pkg_file_full}.dep" \
    "${ROOT_MNT}/tce/optional/${pkg_basename}.dep" \
    "${TCZ_CACHE_DIR}/${pkg_basename}.dep" \
    "${pkg_basename}.dep" >/dev/null 2>&1 || true

  download_and_stage_file "${TCE_BASE_URL}/${pkg_file_full}.md5.txt" \
    "${ROOT_MNT}/tce/optional/${pkg_basename}.md5.txt" \
    "${TCZ_CACHE_DIR}/${pkg_basename}.md5.txt" \
    "${pkg_basename}.md5.txt" >/dev/null 2>&1 || true
done

if [ "$NET_TYPE" == "wifi" ]; then
  log_info "Fetching list of all wireless kernel modules for ${PICORE_KERNEL_SERIES_PREFIX} series..."
  wireless_tcz_list=$(curl -s "${TCE_BASE_URL}/" | grep -oE "wireless-${PICORE_KERNEL_SERIES_PREFIX}[0-9\.]+-piCore[^\"']*\.tcz" | sort -u || echo "LIST_FAILED")

  if [ "$wireless_tcz_list" != "LIST_FAILED" ] && [ -n "$wireless_tcz_list" ]; then
    log_info "Found potential wireless kernel modules:"
    echo "$wireless_tcz_list" | awk '{print "     - " $1}'

    for pkg_file_full in $wireless_tcz_list; do
      pkg_basename=$(basename "$pkg_file_full")
      download_and_stage_file "${TCE_BASE_URL}/${pkg_file_full}" \
        "${ROOT_MNT}/tce/optional/${pkg_basename}" \
        "${TCZ_CACHE_DIR}/${pkg_basename}" \
        "$pkg_basename"
      download_and_stage_file "${TCE_BASE_URL}/${pkg_file_full}.md5.txt" \
        "${ROOT_MNT}/tce/optional/${pkg_basename}.md5.txt" \
        "${TCZ_CACHE_DIR}/${pkg_basename}.md5.txt" \
        "${pkg_basename}.md5.txt" >/dev/null 2>&1 || true
    done
  else
    log_info "Warning: Could not fetch or parse list of wireless kernel modules."
  fi
fi

if [ -f "${BOOT_MNT}/tce/onboot.lst" ]; then
  log_info "   Finalizing onboot.lst on boot partition..."
  sudo sort -u "${BOOT_MNT}/tce/onboot.lst" -o "${BOOT_MNT}/tce/onboot.lst"
  echo "================="
  echo "onboot.lst contents (${BOOT_MNT}/tce/onboot.lst):"
  echo "-----------------"
  cat "${BOOT_MNT}/tce/onboot.lst"
  echo "================="
fi

if [ -f "${BOOT_MNT}/tce/onboot.lst" ]; then
  sudo cp "${BOOT_MNT}/tce/onboot.lst" "${ROOT_MNT}/tce/onboot.lst"
fi

log_info "Finalizing persistence list (.filetool.lst)..."
if [ -f "${ROOT_MNT}/opt/.filetool.lst" ]; then
  # Ensure entries are unique and then sort.
  # Create a temporary file for unique entries, then sort that back to the original.
  TMP_FILETOOL_LST=$(mktemp)
  sudo awk '!seen[$0]++' "${ROOT_MNT}/opt/.filetool.lst" >"$TMP_FILETOOL_LST"
  sudo sort "$TMP_FILETOOL_LST" -o "${ROOT_MNT}/opt/.filetool.lst"
  sudo cp "${ROOT_MNT}/opt/.filetool.lst" "${BOOT_MNT}/opt/.filetool.lst"
  rm "$TMP_FILETOOL_LST"
fi

if [ -f "${ROOT_MNT}/opt/bootlocal.sh" ]; then
  if ! grep -q "openssh start" "${ROOT_MNT}/opt/bootlocal.sh"; then
    echo 'sudo /usr/local/etc/init.d/openssh start # Start SSHD' | sudo tee -a "${ROOT_MNT}/opt/bootlocal.sh" >/dev/null
  fi
  sudo chmod +x "${ROOT_MNT}/opt/bootlocal.sh"
fi

log_step "Phase 3: Finalizing Image"
log_info "Unmounting partitions..."
sudo sync
sudo umount "$ROOT_MNT" || log_info "Warning: umount $ROOT_MNT failed."
sudo umount "$BOOT_MNT" || log_info "Warning: umount $BOOT_MNT failed."

log_info "Detaching loop device ${LOOP_DEV}..."
if losetup "$LOOP_DEV" &>/dev/null; then
  if sudo kpartx -l "$LOOP_DEV" 2>/dev/null | grep -q "$(basename "$LOOP_DEV")p"; then
    sudo kpartx -d "$LOOP_DEV"
  fi
  sudo losetup -d "$LOOP_DEV"
fi
LOOP_DEV=""

FINAL_IMAGE_OUTPUT_PATH="${INITIAL_PWD_AT_SCRIPT_START}/${FIXED_OUTPUT_IMAGE_BASENAME}.img"
FINAL_KEY_OUTPUT_PATH="${INITIAL_PWD_AT_SCRIPT_START}/${FIXED_HOSTNAME}_id_rsa"

mv "${DECOMPRESSED_IMAGE_PATH}" "${FINAL_IMAGE_OUTPUT_PATH}"
log_info "Customized image saved to: ${FINAL_IMAGE_OUTPUT_PATH}"

if [ "$SSH_CONFIG_TYPE" == "key" ]; then
  mv "${GENERATED_PICORE_ACCESS_KEY_PATH}" "${FINAL_KEY_OUTPUT_PATH}"
  chmod 600 "${FINAL_KEY_OUTPUT_PATH}"
  log_info "SSH Private Key for access is saved at: ${FINAL_KEY_OUTPUT_PATH}"
  log_info "Use: ssh -i \"${FINAL_KEY_OUTPUT_PATH}\" tc@<pi_ip_address>"
elif [ "$SSH_CONFIG_TYPE" == "password" ]; then
  log_info "SSH into the piCore image as user 'tc' with password: ${GENERATED_SSH_PASSWORD}"
  log_info "(This password will be set on the first boot of the image)."
fi
log_info "You can now flash '${FINAL_IMAGE_OUTPUT_PATH}' to your SD card."
log_info "The temporary working directory was: ${WORK_DIR}"
log_info "(This directory will be removed automatically by cleanup trap)."

log_info "Script finished successfully."
exit 0
