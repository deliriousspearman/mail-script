#!/usr/bin/env bash
#
# scripts/uninstall.sh
#
# Uninstall (purge) Postfix, Dovecot, and Roundcube from an Ubuntu/Debian system.
# Also offers to remove leftover directories, config files, and the vmail user and group.

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

echo "==================================="
echo "    Uninstall Mail Server"
echo "==================================="
echo "${YELLOW}[WARN] This will remove Postfix, Dovecot, and Roundcube from your system.${CLEAR}"
read -rp "Are you sure you want to continue? [y/N]: " CONFIRM

if [[ "${CONFIRM,,}" != "y" ]]; then
  echo "Aborting uninstall."
  exit 0
fi

echo "Purging packages: Postfix, Dovecot, Roundcube..."
# Remove relevant packages.
DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y \
  postfix \
  dovecot-core dovecot-imapd dovecot-pop3d \
  roundcube roundcube-core roundcube-sqlite3

echo "Removing any residual config files..."
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
DEBIAN_FRONTEND=noninteractive apt-get autoclean -y

# Optionally remove leftover config or data directories.
echo "==================================="
read -rp "Remove leftover mail directories (e.g., /var/mail/vhosts)? [y/N]: " RM_VMAIL
if [[ "${RM_VMAIL,,}" == "y" ]]; then
  if [ -d "/var/mail/vhosts" ]; then
    echo "Removing /var/mail/vhosts..."
    rm -rf /var/mail/vhosts
  fi
fi

read -rp "Remove leftover config files in /etc/dovecot, /etc/postfix, /etc/roundcube? [y/N]: " RM_CONFIG
if [[ "${RM_CONFIG,,}" == "y" ]]; then
  if [ -d "/etc/dovecot" ]; then
    echo "Removing /etc/dovecot..."
    rm -rf /etc/dovecot
  fi
  if [ -d "/etc/postfix" ]; then
    echo "Removing /etc/postfix..."
    rm -rf /etc/postfix
  fi
  if [ -d "/etc/roundcube" ]; then
    echo "Removing /etc/roundcube..."
    rm -rf /etc/roundcube
  fi
fi

# Optionally remove the vmail user and group
echo "==================================="
read -rp "Remove vmail user and group? [y/N]: " RM_VMAIL_USER
if [[ "${RM_VMAIL_USER,,}" == "y" ]]; then
  if id "vmail" &>/dev/null; then
    echo "Removing vmail user..."
    userdel -r vmail
    echo "Removing vmail group..."
    groupdel vmail
  else
    echo "vmail user does not exist."
  fi
fi

echo "==================================="
echo "Uninstallation complete."
echo "Mail server components have been removed (packages purged)."
echo "Check your system for any remaining custom data if needed."
echo "==================================="
