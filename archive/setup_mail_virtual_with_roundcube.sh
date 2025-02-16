#!/usr/bin/env bash
#
# setup_mail_virtual_with_roundcube.sh
#
# A script to install Postfix + Dovecot for virtual mailboxes on Ubuntu 22.04,
# then optionally install Roundcube webmail (Apache-based).

set -e

######################################
# Check if script is run as root
######################################
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root."
  exit 1
fi

######################################
# Configuration Variables
######################################
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

# Files used by Postfix and Dovecot
DOVECOT_USERS="/etc/dovecot/users"
VMAILBOX="/etc/postfix/vmailbox"

######################################
# Update & Install Prerequisites
######################################
echo "=== Installing Postfix & Dovecot Packages ==="
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  postfix \
  dovecot-core dovecot-imapd dovecot-pop3d \
  openssl

######################################
# Create vmail user/group
######################################
if ! getent group vmail >/dev/null; then
  groupadd -g "${VMAIL_GROUPID}" vmail
fi
if ! getent passwd vmail >/dev/null; then
  useradd -g vmail -u "${VMAIL_USERID}" vmail -d "${VMAIL_DIR}" -m
fi

mkdir -p "${VMAIL_DIR}"
chown -R vmail:vmail "${VMAIL_DIR}"
chmod -R 770 "${VMAIL_DIR}"

######################################
# Configure Postfix
######################################
echo "=== Configuring Postfix ==="
cp /etc/postfix/main.cf /etc/postfix/main.cf.bak."$(date +%F-%T)"

postconf -e "myhostname = ${MAIL_HOSTNAME}"
postconf -e "mydomain = ${MAIL_DOMAIN}"
postconf -e "mydestination = localhost, localhost.localdomain, \$myhostname"
postconf -e "mynetworks_style = host"
postconf -e "smtpd_banner = \$myhostname ESMTP \$mail_name (Ubuntu)"
postconf -e "biff = no"

# TLS (self-signed for testing)
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
postconf -e "virtual_mailbox_maps = hash:${VMAILBOX}"
postconf -e "virtual_minimum_uid = 100"
postconf -e "virtual_uid_maps = static:${VMAIL_USERID}"
postconf -e "virtual_gid_maps = static:${VMAIL_GROUPID}"

# Use Dovecot for SASL
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_sasl_security_options = noanonymous"
postconf -e "smtpd_sasl_tls_security_options = noanonymous"
postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"

# Aliases
postconf -e "alias_maps = hash:/etc/aliases"
postconf -e "alias_database = hash:/etc/aliases"
sed -i "/^postmaster:/d" /etc/aliases
echo "postmaster: ${POSTMASTER_ADDRESS}" >> /etc/aliases
newaliases

# /etc/postfix/vmailbox
cat > "${VMAILBOX}" <<EOF
${VMAIL_USER}   ${MAIL_DOMAIN}/test/
EOF
postmap "${VMAILBOX}"

echo "=== Generating self-signed SSL certificates (TEST ONLY) ==="
mkdir -p /etc/ssl/private
openssl req -new -x509 -days 365 -nodes \
  -subj "/C=${SSL_COUNTRY}/ST=${SSL_STATE}/L=${SSL_LOCALITY}/O=${SSL_ORG}/OU=${SSL_OU}/CN=${SSL_CN}" \
  -keyout "/etc/ssl/private/${MAIL_HOSTNAME}.key" \
  -out "/etc/ssl/certs/${MAIL_HOSTNAME}.pem"
chmod o= "/etc/ssl/private/${MAIL_HOSTNAME}.key"

######################################
# Configure Dovecot
######################################
echo "=== Configuring Dovecot ==="
cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-mail.conf /etc/dovecot/conf.d/10-mail.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-auth.conf /etc/dovecot/conf.d/10-auth.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-master.conf /etc/dovecot/conf.d/10-master.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-ssl.conf /etc/dovecot/conf.d/10-ssl.conf.bak."$(date +%F-%T)"

# Dovecot main config
sed -i "s|^#listen = \*, ::|listen = \*, ::|" /etc/dovecot/dovecot.conf

# Mail location
sed -i "s|^#mail_location = .*|mail_location = maildir:${VMAIL_DIR}/%d/%n/Maildir|" /etc/dovecot/conf.d/10-mail.conf

# Allow plaintext over TLS (demo only)
sed -i "s|^#disable_plaintext_auth = yes|disable_plaintext_auth = no|" /etc/dovecot/conf.d/10-auth.conf

# Disable system auth, enable passwd-file
sed -i "s/^!include auth-system.conf.ext/#!include auth-system.conf.ext/" /etc/dovecot/conf.d/10-auth.conf
sed -i "s/^#!include auth-passwdfile.conf.ext/!include auth-passwdfile.conf.ext/" /etc/dovecot/conf.d/10-auth.conf

cat > /etc/dovecot/conf.d/auth-passwdfile.conf.ext <<EOF
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u ${DOVECOT_USERS}
}

userdb {
  driver = static
  args = uid=${VMAIL_USERID} gid=${VMAIL_GROUPID} home=${VMAIL_DIR}/%d/%n
}
EOF

# SSL in Dovecot
sed -i "s|^#ssl = yes|ssl = yes|" /etc/dovecot/conf.d/10-ssl.conf
sed -i "s|^ssl_cert = .*|ssl_cert = </etc/ssl/certs/${MAIL_HOSTNAME}.pem|" /etc/dovecot/conf.d/10-ssl.conf
sed -i "s|^ssl_key = .*|ssl_key = </etc/ssl/private/${MAIL_HOSTNAME}.key|" /etc/dovecot/conf.d/10-ssl.conf

# Dovecot SASL socket for Postfix
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

######################################
# Create initial user in /etc/dovecot/users
######################################
mkdir -p /etc/dovecot
touch "${DOVECOT_USERS}"

echo "=== Creating a virtual mail user: ${VMAIL_USER} ==="
HASH=$(doveadm pw -s SHA512-CRYPT -p "${VMAIL_PASS}")
echo "${VMAIL_USER}:${HASH}" >> "${DOVECOT_USERS}"

# Ownership & permissions
chown root:dovecot "${DOVECOT_USERS}"
chmod 640 "${DOVECOT_USERS}"

######################################
# Restart Services
######################################
echo "=== Restarting and enabling Postfix & Dovecot ==="
systemctl restart postfix
systemctl restart dovecot
systemctl enable postfix
systemctl enable dovecot

######################################
# Prompt to Install Roundcube
######################################
read -rp "Would you like to also install Roundcube webmail? [y/N]: " INSTALL_ROUNDCUBE
if [[ "${INSTALL_ROUNDCUBE,,}" == "y" ]]; then
  echo "=== Installing Roundcube (Apache-based) ==="
  # Install Apache and Roundcube
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apache2 \
    roundcube \
    php-mbstring php-xml php-json php-zip php-gd

  # Enable Apache modules if needed
  a2enmod php7.4 &>/dev/null || true
  a2enmod rewrite &>/dev/null || true

  # Symlink Roundcube into /var/www/html/roundcube
  if [ ! -d "/var/www/html/roundcube" ]; then
    ln -s /usr/share/roundcube /var/www/html/roundcube
  fi

  # Restart Apache
  systemctl enable apache2
  systemctl restart apache2

  echo "Roundcube webmail has been installed."
  echo "You can access it at http://<server-ip>/roundcube"
  echo "Make sure your firewall is open on port 80 (and 443 if using HTTPS)."
fi

######################################
# Final Output
######################################
echo "===================================================================="
echo "Installation and basic configuration complete."
echo "Domain:       ${MAIL_DOMAIN}"
echo "Hostname:     ${MAIL_HOSTNAME}"
echo "User:         ${VMAIL_USER}"
echo "Password:     ${VMAIL_PASS}"
echo
echo "Check logs in /var/log/mail.log or /var/log/syslog if you see issues."
echo "Configure DNS (MX, SPF, DKIM, DMARC), use real certs, and secure your server."
echo "===================================================================="

# Fix for roundcube
# sudo apt install roundcube-sqlite3
# sudo mkdir -p /var/lib/roundcube
# sudo touch /var/lib/roundcube/roundcube.db
# sudo chown -R www-data:www-data /var/lib/roundcube
# sudo chmod 770 /var/lib/roundcube
# // Example in config.inc.php
# $config['db_dsnw'] = 'sqlite:////var/lib/roundcube/roundcube.db?mode=0640';
# sudo systemctl restart apache2