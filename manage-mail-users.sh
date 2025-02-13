#!/usr/bin/env bash
#
# manage_mail_users.sh
#
# An interactive script to list, add, reset passwords, remove virtual users,
# and test authentication for a user in a Postfix + Dovecot setup
# (passwd-file + vmailbox) on Ubuntu.
#
# Must be run as root. Usage: ./manage_mail_users.sh

set -e

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root."
  exit 1
fi

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------
DOVECOT_USERS="/etc/dovecot/users"    # Dovecot passwd-file
VMAILBOX="/etc/postfix/vmailbox"      # Postfix vmailbox map

# ---------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------

reload_services() {
  echo "Reloading Postfix and Dovecot..."
  systemctl reload postfix
  systemctl reload dovecot
}

generate_hash() {
  local plain="$1"
  doveadm pw -s SHA512-CRYPT -p "$plain"
}

user_exists_in_dovecot() {
  local user_email="$1"
  grep -q "^$user_email:" "$DOVECOT_USERS" 2>/dev/null
}

user_exists_in_vmailbox() {
  local user_email="$1"
  grep -q "^$user_email[[:space:]]" "$VMAILBOX" 2>/dev/null
}

add_user_dovecot() {
  local user_email="$1"
  local user_hash="$2"

  if user_exists_in_dovecot "$user_email"; then
    echo "User '$user_email' already exists in $DOVECOT_USERS. Skipping add."
  else
    echo "$user_email:$user_hash" >> "$DOVECOT_USERS"
    echo "User '$user_email' added to $DOVECOT_USERS."
  fi
}

modify_user_dovecot() {
  local user_email="$1"
  local user_hash="$2"

  if user_exists_in_dovecot "$user_email"; then
    sed -i "s|^$user_email:.*|$user_email:$user_hash|" "$DOVECOT_USERS"
    echo "Updated password for '$user_email' in $DOVECOT_USERS."
  else
    echo "User '$user_email' does not exist in $DOVECOT_USERS. Cannot modify."
  fi
}

remove_user_dovecot() {
  local user_email="$1"

  if user_exists_in_dovecot "$user_email"; then
    sed -i "/^$user_email:/d" "$DOVECOT_USERS"
    echo "Removed '$user_email' from $DOVECOT_USERS."
  else
    echo "User '$user_email' not found in $DOVECOT_USERS."
  fi
}

add_user_vmailbox() {
  local user_email="$1"
  local domain="${user_email#*@}"
  local localpart="${user_email%@*}"

  if user_exists_in_vmailbox "$user_email"; then
    echo "User '$user_email' already exists in $VMAILBOX. Skipping add."
  else
    echo "$user_email    $domain/$localpart/" >> "$VMAILBOX"
    echo "Added '$user_email' to $VMAILBOX."
    postmap "$VMAILBOX"
  fi
}

remove_user_vmailbox() {
  local user_email="$1"
  if user_exists_in_vmailbox "$user_email"; then
    sed -i "/^$user_email[[:space:]]/d" "$VMAILBOX"
    echo "Removed '$user_email' from $VMAILBOX."
    postmap "$VMAILBOX"
  else
    echo "User '$user_email' not found in $VMAILBOX."
  fi
}

# ---------------------------------------------------------------------
# New function: list existing users
# ---------------------------------------------------------------------
list_users() {
  if [ ! -s "$DOVECOT_USERS" ]; then
    echo "No users found in $DOVECOT_USERS."
    return
  fi

  echo "=== Existing Virtual Users ==="
  cut -d':' -f1 "$DOVECOT_USERS"
  echo "==============================="
}

# ---------------------------------------------------------------------
# New function: test authentication for a user
# ---------------------------------------------------------------------
test_auth_for_user() {
  read -rp "Enter the email to test: " auth_email
  if [[ ! "$auth_email" =~ "@" ]]; then
    echo "Invalid email address."
    return
  fi

  read -rsp "Enter the password for $auth_email: " auth_pass
  echo
  echo "Testing authentication with 'doveadm auth test'..."
  if doveadm auth test "$auth_email" "$auth_pass"; then
    echo "Authentication succeeded!"
  else
    echo "Authentication failed! Check /var/log/mail.log or /var/log/syslog for details."
  fi
}

# ---------------------------------------------------------------------
# Ensure files exist
# ---------------------------------------------------------------------
[ -f "$DOVECOT_USERS" ] || touch "$DOVECOT_USERS"
[ -f "$VMAILBOX" ] || touch "$VMAILBOX"

# ---------------------------------------------------------------------
# Main Menu
# ---------------------------------------------------------------------
while true; do
  echo "-------------------------------------------------"
  echo "Manage Mail Users:"
  echo "1) List existing users"
  echo "2) Add a new user"
  echo "3) Reset an existing user's password"
  echo "4) Remove a user"
  echo "5) Test authentication for a user"
  echo "6) Exit"
  echo "-------------------------------------------------"

  read -rp "Select an option [1-6]: " menu_choice

  case "$menu_choice" in
    1)  # List users
        echo "=== Listing existing users ==="
        list_users
        ;;
    2)  # Add a new user
        echo "=== Add a new user ==="
        read -rp "Enter the email (e.g., alice@example.com): " new_email
        if [[ ! "$new_email" =~ "@" ]]; then
          echo "Invalid email address."
          continue
        fi

        read -rsp "Enter a password for $new_email: " new_pass
        echo
        new_hash="$(generate_hash "$new_pass")"
        add_user_dovecot "$new_email" "$new_hash"
        add_user_vmailbox "$new_email"
        # Fix ownership/permissions
        chown root:dovecot "$DOVECOT_USERS"
        chmod 640 "$DOVECOT_USERS"
        reload_services
        ;;
    3)  # Reset an existing user's password
        echo "=== Reset an existing user's password ==="
        read -rp "Enter the email to reset password for: " mod_email
        if [[ ! "$mod_email" =~ "@" ]]; then
          echo "Invalid email address."
          continue
        fi

        if ! user_exists_in_dovecot "$mod_email"; then
          echo "User '$mod_email' does not exist in Dovecot. Cannot reset."
          continue
        fi

        read -rsp "Enter a new password for $mod_email: " mod_pass
        echo
        mod_hash="$(generate_hash "$mod_pass")"
        modify_user_dovecot "$mod_email" "$mod_hash"
        chown root:dovecot "$DOVECOT_USERS"
        chmod 640 "$DOVECOT_USERS"
        reload_services
        ;;
    4)  # Remove a user
        echo "=== Remove a user ==="
        read -rp "Enter the email to remove: " del_email
        if [[ ! "$del_email" =~ "@" ]]; then
          echo "Invalid email address."
          continue
        fi

        remove_user_dovecot "$del_email"
        remove_user_vmailbox "$del_email"
        chown root:dovecot "$DOVECOT_USERS"
        chmod 640 "$DOVECOT_USERS"
        reload_services
        ;;
    5)  # Test authentication for a user
        echo "=== Test authentication ==="
        test_auth_for_user
        ;;
    6)  # Exit
        echo "Exiting."
        break
        ;;
    *)
        echo "Invalid choice. Please select [1-6]."
        ;;
  esac
done
