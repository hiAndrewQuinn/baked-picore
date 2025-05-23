#!/bin/bash

# ###################################################################
# piCore Offline Image Customizer - Flow Outline Script (Simplified)
# ###################################################################

# --- Helper Functions ---
log_step() {
  echo -e "\n==> $1"
}

log_info() {
  echo "    $1" # Indent for readability
}

ask_user_yn() {
  local prompt_message="$1"
  local var_name="$2"
  local default_choice="$3" # Should be 'y' or 'n'

  local yn_prompt="(y/n)"
  local full_prompt_message="$prompt_message $yn_prompt [${default_choice}]: "

  while true; do
    # Add a newline before the prompt for better spacing
    echo ""
    read -r -p "$full_prompt_message" "$var_name"
    eval "$var_name=\"\${$var_name:-$default_choice}\"" # Assign default if input is empty
    if [[ "${!var_name}" == "y" || "${!var_name}" == "n" ]]; then
      break
    else
      echo "    Invalid input. Please enter 'y' or 'n'."
    fi
  done
}

ask_user() {
  local prompt_message="$1"
  local var_name="$2"
  local default_value="${3:-}" # Optional default value

  # Add a newline before the prompt for better spacing
  echo ""
  if [ -n "$default_value" ]; then
    read -r -p "$prompt_message [${default_value}]: " "$var_name"
    eval "$var_name=\"\${$var_name:-$default_value}\"" # Assign default if input is empty
  else
    read -r -p "$prompt_message: " "$var_name"
  fi
}

# --- Main Script Flow ---

echo "Welcome to the piCore Offline Image Customizer."
echo "This script will guide you through preparing a piCore image."
echo "No actual changes will be made by this outline script."

# 1. Collect User Inputs
# -----------------------
log_step "Phase 1: Gathering Configuration Details"

# --- Download piCore Image ---
DEFAULT_PICORE_URL="http://tinycorelinux.net/15.x/armhf/releases/RPi/piCore-15.0.0.zip"
FIXED_HOSTNAME="piCoreCustom"                     # Fixed hostname
FIXED_OUTPUT_IMAGE_PATH="./customized-piCore.img" # Fixed output path

echo "" # Extra newline for spacing
log_info "The script will attempt to download the latest stable piCore for Raspberry Pi."
ask_user "Use this URL for piCore image? (or provide your own URL/local path)" PICORE_SOURCE "$DEFAULT_PICORE_URL"

# Simulate download/local file check
PICORE_DOWNLOADED_FILE="" # This would be the path to the downloaded .zip or .img.gz
PICORE_IMAGE_PATH=""      # This would be the path to the extracted .img file

if [[ "$PICORE_SOURCE" == http* ]]; then
  log_info "Simulating download of '${PICORE_SOURCE}'..."
  PICORE_DOWNLOADED_FILE="temp_picore_download.zip" # Assuming it's a zip for now based on your URL
  log_info "  Simulated download complete: ${PICORE_DOWNLOADED_FILE}"

  if [[ "$PICORE_DOWNLOADED_FILE" == *.zip ]]; then
    log_info "Simulating extraction of '${PICORE_DOWNLOADED_FILE}'..."
    PICORE_IMAGE_PATH="./temp_extracted_image/piCore-15.0.0.img" # Example
    log_info "  Simulated extraction, image found at: ${PICORE_IMAGE_PATH}"
  elif [[ "$PICORE_DOWNLOADED_FILE" == *.img.gz ]]; then
    log_info "Simulating gunzip of '${PICORE_DOWNLOADED_FILE}'..."
    PICORE_IMAGE_PATH="${PICORE_DOWNLOADED_FILE%.gz}"
    log_info "  Simulated gunzip, image at: ${PICORE_IMAGE_PATH}"
  else
    PICORE_IMAGE_PATH="$PICORE_SOURCE"
  fi
else
  PICORE_IMAGE_PATH="$PICORE_SOURCE"
  log_info "Using local piCore image: '${PICORE_IMAGE_PATH}'"
  if [[ "$PICORE_IMAGE_PATH" == *.zip ]]; then
    log_info "Error: Direct local .zip files are not yet handled in this simulation. Please provide path to .img or .img.gz"
    exit 1
  elif [[ "$PICORE_IMAGE_PATH" == *.img.gz ]]; then
    log_info "Simulating gunzip of local '${PICORE_IMAGE_PATH}'..."
    log_info "  Simulated gunzip, image would be: ${PICORE_IMAGE_PATH%.gz}"
  fi
fi

if [ -z "$PICORE_IMAGE_PATH" ]; then
  log_info "Error: Could not determine a valid piCore image path. Exiting."
  exit 1
fi
log_info "Proceeding with image: ${PICORE_IMAGE_PATH}"

# --- SD Card Size Check ---
echo "" # Extra newline for spacing
log_info "SD Card Size Confirmation:"
log_info "  This script bakes in ~30MB of extra packages for initial setup (like Wi-Fi)."
log_info "  Please ensure the SD card you intend to use is at least 1GB in size."
log_info "  This is for storage space, not RAM requirements."
ask_user_yn "Is your target SD card at least 1GB in size?" SD_CARD_BIG_ENOUGH "y"

if [ "$SD_CARD_BIG_ENOUGH" == "n" ]; then
  log_info "Error: Target SD card is too small. Please use an SD card that is at least 1GB. Exiting."
  exit 1
fi
log_info "  SD card size confirmed as adequate."

# --- Network Configuration ---
echo "" # Extra newline for spacing
log_info "Network Configuration:"
ask_user "Network type? (wifi/ethernet):" NET_TYPE "wifi"

if [ "$NET_TYPE" == "wifi" ]; then
  echo ""
  log_info "Attempting to scan for Wi-Fi networks (simulation)..."
  log_info "  (In a real script, this would use OS-specific commands)"
  log_info "  Available networks (simulated):"
  log_info "    1. MyHomeNetwork (Currently Connected)"
  log_info "    2. NeighborsWifi_5G"
  CURRENTLY_CONNECTED_SSID_SIMULATED="MyHomeNetwork"

  ask_user "  Enter Wi-Fi SSID (or choose from list if available):" WIFI_SSID "$CURRENTLY_CONNECTED_SSID_SIMULATED"
  ask_user "  Enter Wi-Fi Password/PSK for '${WIFI_SSID}':" WIFI_PSK
fi

ask_user "  Configure IP for '${NET_TYPE}'? (dhcp/static):" IP_CONFIG_TYPE "dhcp"
if [ "$IP_CONFIG_TYPE" == "static" ]; then
  ask_user "    Enter static IP address (e.g., 192.168.1.100):" STATIC_IP
  ask_user "    Enter subnet mask (e.g., 255.255.255.0):" SUBNET_MASK
  ask_user "    Enter gateway address (e.g., 192.168.1.1):" GATEWAY_IP
  ask_user "    Enter DNS server (e.g., 192.168.1.1 or 8.8.8.8):" DNS_SERVER
fi

# --- SSH Configuration ---
echo "" # Extra newline for spacing
log_info "SSH Configuration:"
ask_user "How to configure SSH access to the piCore image? (key/password):" SSH_CONFIG_TYPE "key"

if [ "$SSH_CONFIG_TYPE" == "key" ]; then
  echo ""
  log_info "  Key-based SSH access selected."
  log_info "  A new SSH key pair will be generated FOR THE PICORE IMAGE."
  SIMULATED_PICORE_PRIVATE_KEY_PATH="/mnt/pidata_temp/home/tc/.ssh/id_rsa_picore_image"
  SIMULATED_PICORE_PUBLIC_KEY_PATH="/mnt/pidata_temp/home/tc/.ssh/id_rsa_picore_image.pub"
  log_info "  Simulated: New piCore private key at: ${SIMULATED_PICORE_PRIVATE_KEY_PATH}"
  log_info "  Simulated: New piCore public key at: ${SIMULATED_PICORE_PUBLIC_KEY_PATH}"
  log_info "  This public key will be set as an authorized key on the piCore image itself."

  ask_user_yn "  Add the piCore image's NEW public key to THIS machine's ~/.ssh/authorized_keys?" SSH_INSTALL_LOCAL_KEY "y"
  if [ "$SSH_INSTALL_LOCAL_KEY" == "y" ]; then
    log_info "  Simulated: Would append piCore image's public key to ~/.ssh/authorized_keys on THIS machine."
  else
    log_info "  Okay, the new piCore image's public key will NOT be added to this machine's authorized_keys."
  fi
elif [ "$SSH_CONFIG_TYPE" == "password" ]; then
  echo ""
  log_info "  Password-based SSH access selected."
  SIMULATED_PASSWORD="Correct-Horse-Battery-Staple"
  log_info "  A secure password will be generated for the 'tc' user on the piCore image."
  log_info "  Simulated generated password: ${SIMULATED_PASSWORD}"
  log_info "  (Please make a note of this password if this were the real script)"
fi

# 2. Simulate Image Processing Steps
# ----------------------------------
log_step "Phase 2: Simulating Image Customization"
echo "" # Extra newline
log_info "Hostname will be set to: '${FIXED_HOSTNAME}'"
log_info "Output image will be: '${FIXED_OUTPUT_IMAGE_PATH}'"
log_info "Image partitions will be resized to ensure at least 1GB usable space for essentials."
echo "" # Extra newline

log_info "Validating source image: '${PICORE_IMAGE_PATH}'..."
if [ -z "$PICORE_IMAGE_PATH" ]; then
  log_info "Error: Source image path not determined. Exiting."
  exit 1
fi
log_info "  Source image path appears okay (simulation)."
echo ""

DECOMPRESSED_IMAGE_NAME="$PICORE_IMAGE_PATH"
log_info "Using image '${DECOMPRESSED_IMAGE_NAME}' for processing."
echo ""

log_info "Setting up loop device for '${DECOMPRESSED_IMAGE_NAME}'..."
log_info "Identifying and mounting partitions from the image..."
log_info "Resizing partitions (simulated)..." # Simplified message
log_info "Configuring hostname to '${FIXED_HOSTNAME}'..."
log_info "Injecting Network Configuration (${NET_TYPE})..."
log_info "Setting up SSH on piCore image (${SSH_CONFIG_TYPE})..."
if [ "$SSH_CONFIG_TYPE" == "key" ]; then
  log_info "  A NEW SSH key pair would be generated and placed within the piCore image."
  if [ "$SSH_INSTALL_LOCAL_KEY" == "y" ]; then
    log_info "  Action: The public key from the NEWLY generated piCore image key pair would be added to THIS machine's ~/.ssh/authorized_keys."
  fi
elif [ "$SSH_CONFIG_TYPE" == "password" ]; then
  log_info "  The password for user 'tc' on the piCore image would be set to: '${SIMULATED_PASSWORD}'."
fi
log_info "  openssh.tcz would be added to onboot.lst on the piCore image."
echo ""

log_info "Configuring persistence settings..."
log_info "Unmounting partitions..."
log_info "Detaching loop device..."
echo ""

if [[ "$FIXED_OUTPUT_IMAGE_PATH" != "$DECOMPRESSED_IMAGE_NAME" ]]; then
  log_info "Copying/Moving processed image to '${FIXED_OUTPUT_IMAGE_PATH}'..."
fi
log_info "Optional: Compressing '${FIXED_OUTPUT_IMAGE_PATH}' to '${FIXED_OUTPUT_IMAGE_PATH}.gz'..."

# 3. Completion
# -------------
log_step "Phase 3: Customization Simulation Complete!"
echo ""
log_info "The customized piCore image would be available at: ${FIXED_OUTPUT_IMAGE_PATH} (or ${FIXED_OUTPUT_IMAGE_PATH}.gz)"
echo ""
if [ "$SSH_CONFIG_TYPE" == "password" ]; then
  log_info "SSH into the piCore image as user 'tc' with password: ${SIMULATED_PASSWORD}"
elif [ "$SSH_CONFIG_TYPE" == "key" ]; then
  if [ "$SSH_INSTALL_LOCAL_KEY" == "y" ]; then
    log_info "You should be able to SSH into the piCore image as user 'tc' from THIS machine without a password."
  else
    log_info "To SSH into the piCore image, you'll need to manually set up key-based authentication."
  fi
fi
echo ""
log_info "You could then flash this image to your SD card."
log_info "Remember to use 'sudo' for commands that require root privileges in the real script."

echo -e "\nAll simulation steps finished.\n"
