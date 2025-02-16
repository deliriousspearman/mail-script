#!/usr/bin/env bash
#
# wizard.sh
#
# Main menu script that:
#  - Checks if the system is Ubuntu 22.04
#  - Checks if run as root
#  - Prevents Ctrl+C and Ctrl+Z from exiting the script
#  - Prompts the user to install, manage users, uninstall, or exit.
#  - Calls other scripts in the "scripts" folder.
#
# Installation sub-menu includes 5 options:
# 1) Dovecot + Postfix + Roundcube (SSL + No SSL)
# 2) Dovecot + Postfix + Roundcube (SSL)
# 3) Dovecot + Postfix + Roundcube (No SSL)
# 4) Dovecot + Postfix (SSL)
# 5) Dovecot + Postfix (No SSL)

set -e

########################################
# Set Colours
########################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD_RED='\033[1;31m'
BOLD_GREEN='\033[1;32m'
CLEAR='\033[0m'

########################################
# Prevent Ctrl+C and Ctrl+Z from exiting the script
########################################
trap 'echo -e "\n${CYAN}[INFO] Ctrl+C is disabled. Please use the menu option to exit."${CLEAR}' INT
trap 'echo -e "\n${CYAN}[INFO] Ctrl+Z is disabled. Please use the menu option to exit."${CLEAR}' TSTP

########################################
# Check if script is run as root
########################################
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}[ERROR] This script must be run as root. Aborting.${CLEAR}"
  exit 1
fi
echo -e "${CYAN}[INFO] Running as root.${CLEAR}"

########################################
# Check OS version
########################################
if grep -q 'Ubuntu 22.04' /etc/os-release; then
  echo -e "${CYAN}[INFO] System match: Ubuntu 22.04 detected.${CLEAR}"
else
  echo -e "${YELLOW}[WARN] This script is intended for Ubuntu 22.04.${CLEAR}"
  read -rp "Continue anyway? [y/N]: " CONTINUE_ANYWAY
  if [[ "${CONTINUE_ANYWAY,,}" != "y" ]]; then
    echo -e "${CYAN}[INFO] User chose not to continue. Aborting.${CLEAR}"
    exit 1
  fi
fi

########################################
# Ensure scripts are executable
########################################

# Check if the "scripts" directory exists
if [ ! -d "scripts" ]; then
  echo -e "${RED}[ERROR] Directory 'scripts' does not exist.${CLEAR}"
  exit 1
fi

# Define the expected permission in octal
expected_perm="744"

# Loop through each .sh file in the "scripts" directory
for file in scripts/*.sh; do
  # Check if the glob didn't match any files
  [ -e "$file" ] || continue

  # Only process regular files
  if [ -f "$file" ]; then
    # Get the current permission in octal format
    current_perm=$(stat -c "%a" "$file")
    
    # Compare with the expected permission
    if [ "$current_perm" != "$expected_perm" ]; then
      echo -e "${CYAN}[INFO] Changing permissions for $file from $current_perm to $expected_perm${CLEAR}"
      chmod "$expected_perm" "$file"
    fi
  fi
done

########################################
# Main wizard menu
########################################
while true; do
  echo "======================================"
  echo "       Mail Server Wizard"
  echo "======================================"
  echo "1) Install"
  echo "2) Manage Users"
  echo "3) Uninstall"
  echo "4) Exit"
  echo "======================================"
  read -rp "Select an option [1-4]: " choice

  case "$choice" in
    1)
      echo -e "${CYAN}[INFO] User selected Install.${CLEAR}"
      echo "======================================"
      echo " Which installation do you want?"
      echo " 1) Dovecot + Postfix + Roundcube (SSL + No SSL)"
      echo " 2) Dovecot + Postfix + Roundcube (SSL)"
      echo " 3) Dovecot + Postfix + Roundcube (No SSL)"
      echo " 4) Dovecot + Postfix (SSL)"
      echo " 5) Dovecot + Postfix (No SSL)"
      echo "======================================"
      read -rp "Select an option [1-5]: " install_choice

      case "$install_choice" in
        1)
          echo -e "${CYAN}[INFO] Installing combined Dovecot, Postfix, and Roundcube (SSL + No SSL).${CLEAR}"
          ./scripts/install_dpr_combined.sh
          ;;
        2)
          echo -e "${CYAN}[INFO] Installing Dovecot, Postfix, and Roundcube (SSL).${CLEAR}"
          ./scripts/install_dpr_ssl.sh
          ;;
        3)
          echo -e "${CYAN}[INFO] Installing Dovecot, Postfix, and Roundcube (No SSL).${CLEAR}"
          ./scripts/install_dpr.sh
          ;;
        4)
          echo -e "${CYAN}[INFO] Installing Dovecot and Postfix (SSL).${CLEAR}"
          ./scripts/install_dp_ssl.sh
          ;;
        5)
          echo -e "${CYAN}[INFO] Installing Dovecot and Postfix (No SSL).${CLEAR}"
          ./scripts/install_dp.sh
          ;;
        *)
          echo -e "${YELLOW}[WARN] Invalid installation choice. Returning to main menu.${CLEAR}"
          ;;
      esac
      ;;
    2)
      echo -e "${CYAN}[INFO] User selected Manage Users.${CLEAR}"
      ./scripts/manage_users.sh
      ;;
    3)
      echo -e "${CYAN}[INFO] User selected Uninstall.${CLEAR}"
      ./scripts/uninstall.sh
      ;;
    4)
      echo -e "${CYAN}[INFO] User selected Exit. Exiting wizard.${CLEAR}"
      exit 0
      ;;
    *)
      echo -e "${YELLOW}[WARN] Invalid menu choice. Please select 1, 2, 3, or 4.${CLEAR}"
      ;;
  esac
done
