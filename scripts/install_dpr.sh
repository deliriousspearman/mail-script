#!/usr/bin/env bash
#
# install_dpr_no_ssl.sh
#
# Installs Dovecot, Postfix, and Roundcube without SSL.
# Prompts for domain, hostname, test email, and password.
# Configures:
#   - Postfix (plain SMTP on port 25)
#   - Dovecot with mail_location = maildir:/var/mail/vhosts/%d/%n
#   - Roundcube (IMAP on port 143, SMTP on port 25)
#
# WARNING: This setup uses unencrypted connections. Do not use in production.

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

######################################
# Prompt for Domain, Hostname, and Test User Info
######################################
read -rp "Enter your mail domain (e.g., example.com): " MAIL_DOMAIN
read -rp "Enter your mail hostname (default: mail.$MAIL_DOMAIN): " input_hostname
if [ -z "$input_hostname" ]; then
  MAIL_HOSTNAME="mail.$MAIL_DOMAIN"
else
  MAIL_HOSTNAME="$input_hostname"
fi
# Set postmaster automatically
POSTMASTER_ADDRESS="postmaster@$MAIL_DOMAIN"

read -rp "Enter test email address (e.g., test@$MAIL_DOMAIN): " TEST_USER
read -rsp "Enter test password for $TEST_USER: " TEST_PASS
echo

######################################
# Basic Variables and Paths
######################################
# Virtual mail base directory
VMAIL_DIR="/var/mail/vhosts"
VMAIL_USERID="5000"
VMAIL_GROUPID="5000"

# Files used by Postfix & Dovecot
POSTFIX_VMAILBOX="/etc/postfix/vmailbox"
DOVECOT_USERS="/etc/dovecot/users"

######################################
# Ensure /etc/hosts has the domain => 127.0.0.1
######################################
echo "=== Checking /etc/hosts for ${MAIL_HOSTNAME} ==="
if grep -q "127.0.0.1.*${MAIL_HOSTNAME}" /etc/hosts; then
  echo "Domain '${MAIL_HOSTNAME}' already mapped to 127.0.0.1 in /etc/hosts."
else
  echo "Adding '${MAIL_HOSTNAME}' => 127.0.0.1 to /etc/hosts."
  echo "127.0.0.1   ${MAIL_HOSTNAME}" >> /etc/hosts
fi

######################################
# Install Packages
######################################
echo "=== Installing packages: Postfix, Dovecot, Roundcube, Apache, etc. ==="
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  postfix \
  dovecot-core dovecot-imapd dovecot-pop3d \
  roundcube roundcube-sqlite3 \
  php-mbstring php-xml php-json php-zip php-gd \
  apache2 \
  openssl

######################################
# Create 'vmail' user/group
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
# Configure Postfix (No SSL)
######################################
echo "=== Configuring Postfix for no SSL ==="
cp /etc/postfix/main.cf /etc/postfix/main.cf.bak."$(date +%F-%T)"

postconf -e "myhostname = ${MAIL_HOSTNAME}"
postconf -e "mydomain = ${MAIL_DOMAIN}"
postconf -e "mydestination = localhost, localhost.localdomain, \$myhostname"
postconf -e "mynetworks_style = host"
postconf -e "smtpd_banner = \$myhostname ESMTP \$mail_name (No SSL)"
postconf -e "biff = no"

# Disable TLS
postconf -e "smtpd_use_tls=no"
postconf -e "smtp_tls_security_level=none"
# Remove any TLS cert references
postconf -# "smtpd_tls_cert_file" 2>/dev/null || true
postconf -# "smtpd_tls_key_file"  2>/dev/null || true

# Virtual mailbox settings
postconf -e "virtual_mailbox_domains = ${MAIL_DOMAIN}"
postconf -e "virtual_mailbox_base = ${VMAIL_DIR}"
postconf -e "virtual_mailbox_maps = hash:${POSTFIX_VMAILBOX}"
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

# Aliases configuration
postconf -e "alias_maps = hash:/etc/aliases"
postconf -e "alias_database = hash:/etc/aliases"
sed -i "/^postmaster:/d" /etc/aliases
echo "postmaster: ${POSTMASTER_ADDRESS}" >> /etc/aliases
newaliases

# Configure Postfix vmailbox
cat > "${POSTFIX_VMAILBOX}" <<EOF
${TEST_USER}   ${MAIL_DOMAIN}/$(echo "$TEST_USER" | cut -d@ -f1)/
EOF
postmap "${POSTFIX_VMAILBOX}"

######################################
# Configure Dovecot (No SSL)
######################################
echo "=== Configuring Dovecot for no SSL ==="
cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-mail.conf /etc/dovecot/conf.d/10-mail.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-auth.conf /etc/dovecot/conf.d/10-auth.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-master.conf /etc/dovecot/conf.d/10-master.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-ssl.conf /etc/dovecot/conf.d/10-ssl.conf.bak."$(date +%F-%T)"

# Listen on all interfaces
sed -i "s|^#\?listen = \*, ::|listen = \*, ::|" /etc/dovecot/dovecot.conf

# Set mail_location to include the domain and user:
sed -i "s|^#\?mail_location = .*|mail_location = maildir:${VMAIL_DIR}/%d/%n|" /etc/dovecot/conf.d/10-mail.conf

# Allow plaintext auth (no SSL)
sed -i "s|^#\?disable_plaintext_auth = yes|disable_plaintext_auth = no|" /etc/dovecot/conf.d/10-auth.conf

# Disable system auth, enable passwd-file
sed -i "s/^!include auth-system.conf.ext/#!include auth-system.conf.ext/" /etc/dovecot/conf.d/10-auth.conf
sed -i "s/^#!include auth-passwdfile.conf.ext/!include auth-passwdfile.conf.ext/" /etc/dovecot/conf.d/10-auth.conf

# Create the passwd-file configuration
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

# Disable SSL in Dovecot
sed -i "s|^#\?ssl = yes|ssl = no|" /etc/dovecot/conf.d/10-ssl.conf
sed -i "/^ssl_cert = /d" /etc/dovecot/conf.d/10-ssl.conf
sed -i "/^ssl_key = /d"  /etc/dovecot/conf.d/10-ssl.conf

# Provide Dovecot SASL for Postfix
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
# Create Test User in Dovecot
######################################
mkdir -p /etc/dovecot
touch "${DOVECOT_USERS}"
HASH=$(doveadm pw -s SHA512-CRYPT -p "${TEST_PASS}")
echo "${TEST_USER}:${HASH}" >> "${DOVECOT_USERS}"
chown root:dovecot "${DOVECOT_USERS}"
chmod 640 "${DOVECOT_USERS}"

######################################
# Configure Roundcube (No SSL) - Force SMTP port to 25
######################################
echo "=== Configuring Roundcube (No SSL) ==="
# Create symlink if needed
if [ ! -d "/var/www/html/roundcube" ]; then
  ln -s /usr/share/roundcube /var/www/html/roundcube
fi

ROUNDCUBE_CONFIG="/etc/roundcube/config.inc.php"
if [ ! -f "$ROUNDCUBE_CONFIG" ]; then
  cat > "$ROUNDCUBE_CONFIG" <<EOF
<?php
\$config['default_host'] = 'localhost';
\$config['smtp_server'] = 'localhost';
\$config['smtp_port'] = 25;
EOF
fi

# Set SQLite DSN for Roundcube
if grep -q "\$config\['db_dsnw'\]" "$ROUNDCUBE_CONFIG"; then
  sed -i "s|\(\$config\['db_dsnw'\]\).*=.*|\$config['db_dsnw'] = 'sqlite:////var/lib/roundcube/roundcube.db?mode=0640';|" "$ROUNDCUBE_CONFIG"
else
  cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['db_dsnw'] = 'sqlite:////var/lib/roundcube/roundcube.db?mode=0640';
EOF
fi

# Prepare Roundcube SQLite DB
mkdir -p /var/lib/roundcube
touch /var/lib/roundcube/roundcube.db
chown -R www-data:www-data /var/lib/roundcube
chmod 770 /var/lib/roundcube

# Configure Roundcube IMAP host and port (No SSL)
if grep -q "\$config\['default_host'\]" "$ROUNDCUBE_CONFIG"; then
  sed -i "s|\(\$config\['default_host'\]\).*=.*|\$config['default_host'] = '${MAIL_HOSTNAME}';|" "$ROUNDCUBE_CONFIG"
else
  cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['default_host'] = '${MAIL_HOSTNAME}';
EOF
fi

if grep -q "\$config\['default_port'\]" "$ROUNDCUBE_CONFIG"; then
  sed -i "s|\(\$config\['default_port'\]\).*=.*|\$config['default_port'] = 143;|" "$ROUNDCUBE_CONFIG"
else
  cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['default_port'] = 143;
EOF
fi

# Hide "Server" field
if grep -q "\$config\['display_server_choice'\]" "$ROUNDCUBE_CONFIG"; then
  sed -i "s|\(\$config\['display_server_choice'\]\).*=.*|\$config['display_server_choice'] = false;|" "$ROUNDCUBE_CONFIG"
else
  cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['display_server_choice'] = false;
EOF
fi

# Force SMTP port to 25
if grep -q "\$config\['smtp_port'\]" "$ROUNDCUBE_CONFIG"; then
  sed -i "s|\(\$config\['smtp_port'\]\).*=.*|\$config['smtp_port'] = 25;|" "$ROUNDCUBE_CONFIG"
else
  cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['smtp_port'] = 25;
EOF
fi

######################################
# Restart Services
######################################
echo "=== Restarting Postfix, Dovecot, and Apache ==="
systemctl restart postfix
systemctl restart dovecot
systemctl enable postfix
systemctl enable dovecot

systemctl restart apache2
systemctl enable apache2

######################################
# Final Output
######################################
echo "=============================================================="
echo " Dovecot + Postfix + Roundcube installed (No SSL)!"
echo " Mail domain:   ${MAIL_DOMAIN}"
echo " Hostname:      ${MAIL_HOSTNAME}"
echo " Test user:     ${TEST_USER}"
echo " Test password: ${TEST_PASS}"
echo
echo " * SMTP port: 25 (plaintext)"
echo " * IMAP port: 143 (plaintext)"
echo " Roundcube:  http://<server-ip>/roundcube"
echo "=============================================================="
echo "WARNING: This setup uses NO SSL. Credentials travel in plaintext."
echo "For production, consider enabling TLS or using an SSL-enabled script."
