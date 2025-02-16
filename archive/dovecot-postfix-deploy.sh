#!/usr/bin/env bash
#
# setup_mail_virtual.sh
#
# A basic script to install and configure Postfix + Dovecot
# using virtual mailboxes in a simple passwd-file on Ubuntu 22.04.
#
# Must be run as root.

set -e

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Aborting."
  exit 1
fi

# ---------------------------
# EDIT THESE VARIABLES AS NEEDED
# ---------------------------
MAIL_DOMAIN="example.com"
MAIL_HOSTNAME="mail.example.com"
POSTMASTER_ADDRESS="postmaster@example.com"

# Example virtual user and password (for demonstration)
VMAIL_USER="test@example.com"
VMAIL_PASS="MySecurePassword"  # Script will generate a hash

# Where virtual mail is stored
VMAIL_DIR="/var/mail/vhosts"

# ID under which mail will be stored (we'll create a user/group "vmail")
VMAIL_USERID="5000"
VMAIL_GROUPID="5000"

# SSL/TLS settings (self-signed for testing, replace with real certs in production)
SSL_COUNTRY="US"
SSL_STATE="NewYork"
SSL_LOCALITY="NewYorkCity"
SSL_ORG="ExampleInc"
SSL_OU="IT"
SSL_CN="${MAIL_HOSTNAME}"
# ---------------------------

echo "=== Installing Postfix & Dovecot ==="
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  postfix \
  dovecot-core dovecot-imapd dovecot-pop3d \
  openssl

# -----------------------------------------------------------
# Create vmail user/group for storing virtual mail directories
# -----------------------------------------------------------
if ! getent group vmail >/dev/null; then
  echo "=== Creating group vmail with GID ${VMAIL_GROUPID} ==="
  groupadd -g "${VMAIL_GROUPID}" vmail
fi

if ! getent passwd vmail >/dev/null; then
  echo "=== Creating user vmail with UID ${VMAIL_USERID} ==="
  useradd -g vmail -u "${VMAIL_USERID}" vmail -d "${VMAIL_DIR}" -m
fi

# Make sure the mail root directory exists
mkdir -p "${VMAIL_DIR}"
chown -R vmail:vmail "${VMAIL_DIR}"
chmod -R 770 "${VMAIL_DIR}"

# ---------------------------
# Configure Postfix
# ---------------------------
echo "=== Configuring Postfix for virtual domains ==="

cp /etc/postfix/main.cf /etc/postfix/main.cf.bak."$(date +%F-%T)"

# Basic settings
postconf -e "myhostname = ${MAIL_HOSTNAME}"
postconf -e "mydomain = ${MAIL_DOMAIN}"
# We'll only consider localhost as local delivery; everything else is virtual
postconf -e "mydestination = localhost, localhost.localdomain, \$myhostname"
postconf -e "mynetworks_style = host"
postconf -e "smtpd_banner = \$myhostname ESMTP \$mail_name (Ubuntu)"
postconf -e "biff = no"

# Enable TLS (with self-signed cert for testing)
postconf -e "smtpd_use_tls=yes"
postconf -e "smtpd_tls_auth_only=yes"
postconf -e "smtpd_tls_security_level=may"
postconf -e "smtpd_tls_cert_file=/etc/ssl/certs/${MAIL_HOSTNAME}.pem"
postconf -e "smtpd_tls_key_file=/etc/ssl/private/${MAIL_HOSTNAME}.key"
postconf -e "smtp_tls_security_level=may"
postconf -e "smtp_tls_loglevel=1"

# Virtual mail settings
postconf -e "virtual_mailbox_domains = ${MAIL_DOMAIN}"
postconf -e "virtual_mailbox_base = ${VMAIL_DIR}"
# We'll store the mapping of email -> mailbox path in /etc/postfix/vmailbox
postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmailbox"
# Force mail to be owned by vmail user/group
postconf -e "virtual_minimum_uid = 100"
postconf -e "virtual_uid_maps = static:${VMAIL_USERID}"
postconf -e "virtual_gid_maps = static:${VMAIL_GROUPID}"

# Use Dovecot for SASL so we can authenticate for outbound mail
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_sasl_tls_security_options = noanonymous"
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"

# Aliases: route postmaster to the chosen address
postconf -e "alias_maps = hash:/etc/aliases"
postconf -e "alias_database = hash:/etc/aliases"
sed -i "/^postmaster:/d" /etc/aliases
echo "postmaster: ${POSTMASTER_ADDRESS}" >> /etc/aliases
newaliases

# Generate /etc/postfix/vmailbox
# This file maps an email address to the “directory” path relative to $virtual_mailbox_base
echo "=== Setting up /etc/postfix/vmailbox ==="
cat > /etc/postfix/vmailbox <<EOF
${VMAIL_USER}   ${MAIL_DOMAIN}/test/
EOF

postmap /etc/postfix/vmailbox

# Generate self-signed certificates (FOR TESTING ONLY)
echo "=== Generating self-signed SSL certificates (TEST ONLY) ==="
mkdir -p /etc/ssl/private
openssl req -new -x509 -days 365 -nodes \
  -subj "/C=${SSL_COUNTRY}/ST=${SSL_STATE}/L=${SSL_LOCALITY}/O=${SSL_ORG}/OU=${SSL_OU}/CN=${SSL_CN}" \
  -keyout "/etc/ssl/private/${MAIL_HOSTNAME}.key" \
  -out "/etc/ssl/certs/${MAIL_HOSTNAME}.pem"

chmod o= "/etc/ssl/private/${MAIL_HOSTNAME}.key"

# ---------------------------
# Configure Dovecot
# ---------------------------
echo "=== Configuring Dovecot for virtual users (passwd-file) ==="

cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-mail.conf /etc/dovecot/conf.d/10-mail.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-auth.conf /etc/dovecot/conf.d/10-auth.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-master.conf /etc/dovecot/conf.d/10-master.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-ssl.conf /etc/dovecot/conf.d/10-ssl.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/auth-passwdfile.conf.ext /etc/dovecot/conf.d/auth-passwdfile.conf.ext.bak."$(date +%F-%T)" 2>/dev/null || true

# Listen on all interfaces
sed -i "s|^#listen = \*, ::|listen = \*, ::|" /etc/dovecot/dovecot.conf

# Mail location in /var/mail/vhosts/%d/%n/Maildir
sed -i "s|^#mail_location = .*|mail_location = maildir:${VMAIL_DIR}/%d/%n/Maildir|" /etc/dovecot/conf.d/10-mail.conf

# Allow plain text auth (over TLS) - demo only
# (In production, you likely want disable_plaintext_auth = yes)
sed -i "s|^#disable_plaintext_auth = yes|disable_plaintext_auth = no|" /etc/dovecot/conf.d/10-auth.conf

# Disable the default system auth, enable passwd-file
sed -i "s/^!include auth-system.conf.ext/#!include auth-system.conf.ext/" /etc/dovecot/conf.d/10-auth.conf
sed -i "s/^#!include auth-passwdfile.conf.ext/!include auth-passwdfile.conf.ext/" /etc/dovecot/conf.d/10-auth.conf

# Overwrite /etc/dovecot/conf.d/auth-passwdfile.conf.ext with our config
cat > /etc/dovecot/conf.d/auth-passwdfile.conf.ext <<EOF
passdb {
  driver = passwd-file
  # You can specify the hashing scheme and the file path:
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/users
}

userdb {
  driver = static
  # We force the same uid/gid and home directory path for all virtual users:
  args = uid=${VMAIL_USERID} gid=${VMAIL_GROUPID} home=${VMAIL_DIR}/%d/%n
}
EOF

# SSL settings
sed -i "s|^#ssl = yes|ssl = yes|" /etc/dovecot/conf.d/10-ssl.conf
sed -i "s|^ssl_cert = .*|ssl_cert = </etc/ssl/certs/${MAIL_HOSTNAME}.pem|" /etc/dovecot/conf.d/10-ssl.conf
sed -i "s|^ssl_key = .*|ssl_key = </etc/ssl/private/${MAIL_HOSTNAME}.key|" /etc/dovecot/conf.d/10-ssl.conf

# Configure Dovecot SASL socket for Postfix
sed -i '/^service auth {/,/}/ s/^#//g' /etc/dovecot/conf.d/10-master.conf
sed -i '/unix_listener auth-userdb {/,+2 s/^#//g' /etc/dovecot/conf.d/10-master.conf
sed -i '/unix_listener auth-userdb {/,+2 s/^}//g' /etc/dovecot/conf.d/10-master.conf
sed -i '/service auth {/a\
  # Postfix smtp-auth\
  unix_listener /var/spool/postfix/private/auth {\
    mode = 0660\
    user = postfix\
    group = postfix\
  }\
' /etc/dovecot/conf.d/10-master.conf

# --------------------------------
# Create a virtual user in /etc/dovecot/users
# --------------------------------
echo "=== Creating virtual mail user: ${VMAIL_USER} ==="
mkdir -p /etc/dovecot
touch /etc/dovecot/users

# Generate a hashed password using Dovecot's doveadm
echo "Generating password hash for ${VMAIL_USER}..."
HASH=$(doveadm pw -s SHA512-CRYPT -p "${VMAIL_PASS}")
echo "${VMAIL_USER}:${HASH}" >> /etc/dovecot/users

# ------------------------------------------------
# Fix ownership/permissions so Dovecot can read it
# ------------------------------------------------
# Ensure /etc/dovecot is owned by root:root and is 755 (default)
chown root:root /etc/dovecot
chmod 755 /etc/dovecot

# Ensure the file is owned by root:dovecot and has mode 640
chown root:dovecot /etc/dovecot/users
chmod 640 /etc/dovecot/users

# ---------------------------
# Restart and enable services
# ---------------------------
echo "=== Restarting and enabling Postfix + Dovecot ==="
systemctl restart postfix
systemctl restart dovecot
systemctl enable postfix
systemctl enable dovecot

# ---------------------------
# Test the authentication
# ---------------------------
echo "=== Testing Dovecot authentication for ${VMAIL_USER} ==="
if command -v doveadm >/dev/null 2>&1; then
  doveadm auth test "${VMAIL_USER}" "${VMAIL_PASS}" && \
    echo "Authentication successful!" || \
    echo "Authentication failed! Check /var/log/mail.log for details."
else
  echo "doveadm not found. Unable to test authentication automatically."
fi

echo "===================================================================="
echo " Installation and basic configuration complete."
echo " Virtual mailbox setup for user: ${VMAIL_USER}"
echo " Password: ${VMAIL_PASS}"
echo
echo " Check logs in /var/log/mail.log or /var/log/syslog if you see issues."
echo " For production, use real certificates (e.g., Let's Encrypt)."
echo " Configure DNS (MX, SPF, DKIM, DMARC), spam filtering, and firewalls."
echo "===================================================================="