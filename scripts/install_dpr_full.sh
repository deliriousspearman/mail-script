#!/usr/bin/env bash
#
# install_dpr_ssl.sh
#
# Installs Dovecot, Postfix, and Roundcube with SSL enabled.
# Prompts the user for mail domain, hostname, test email, and password.
# Then prompts whether to generate a self-signed certificate or import one.
# Configures:
#   - Postfix: SMTPS (port 465) and supports TLS.
#   - Dovecot: IMAPS (port 993)
#   - Roundcube: Uses IMAPS (993) and SMTPS (465)
# Also enables Apache’s SSL module and default SSL site so the web interface is served on port 443.
#
# WARNING: This script is for testing/development purposes.
# Run as root (e.g., sudo ./install_dpr_ssl.sh).

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
# 1. Prompt for Domain, Hostname, and Test User Info
######################################
read -rp "Enter your mail domain (e.g., example.com): " MAIL_DOMAIN
read -rp "Enter your mail hostname (default: mail.$MAIL_DOMAIN): " input_hostname
if [ -z "$input_hostname" ]; then
  MAIL_HOSTNAME="mail.$MAIL_DOMAIN"
else
  MAIL_HOSTNAME="$input_hostname"
fi
POSTMASTER_ADDRESS="postmaster@$MAIL_DOMAIN"

read -rp "Enter test email address (e.g., test@$MAIL_DOMAIN): " TEST_USER
read -rsp "Enter test password for $TEST_USER: " TEST_PASS
echo

######################################
# 2. Basic Variables and Paths
######################################
# Virtual mail base directory
VMAIL_DIR="/var/mail/vhosts"
VMAIL_USERID="5000"
VMAIL_GROUPID="5000"

# Files for Postfix & Dovecot
POSTFIX_VMAILBOX="/etc/postfix/vmailbox"
DOVECOT_USERS="/etc/dovecot/users"

# SSL Certificate paths (for Postfix and Dovecot)
CERT_FILE="/etc/ssl/certs/${MAIL_HOSTNAME}.pem"
KEY_FILE="/etc/ssl/private/${MAIL_HOSTNAME}.key"

# Flag for Roundcube to ignore certificate validation if self-signed
IGNORE_CERT_VALIDATION_IN_ROUNDCUBE="false"

######################################
# 3. Ensure /etc/hosts maps MAIL_HOSTNAME to 127.0.0.1
######################################
echo "=== Checking /etc/hosts for ${MAIL_HOSTNAME} ==="
if grep -q "127.0.0.1.*${MAIL_HOSTNAME}" /etc/hosts; then
  echo "Domain '${MAIL_HOSTNAME}' already mapped to 127.0.0.1."
else
  echo "Adding '${MAIL_HOSTNAME}' => 127.0.0.1 to /etc/hosts."
  echo "127.0.0.1   ${MAIL_HOSTNAME}" >> /etc/hosts
fi

######################################
# 4. Prompt for Certificate Option (SSL)
######################################
echo "=== SSL Certificate Setup ==="
echo "1) Generate a self-signed certificate"
echo "2) Import an existing certificate/key"
read -rp "Choose an option [1-2]: " CERT_OPTION
case "$CERT_OPTION" in
  1)
    echo "Generating self-signed certificate..."
    mkdir -p /etc/ssl/private
    openssl req -new -x509 -days 365 -nodes \
      -subj "/C=US/ST=NewYork/L=NewYorkCity/O=ExampleInc/OU=IT/CN=${MAIL_HOSTNAME}" \
      -keyout "${KEY_FILE}" \
      -out "${CERT_FILE}"
    chmod o= "${KEY_FILE}"
    IGNORE_CERT_VALIDATION_IN_ROUNDCUBE="true"
    ;;
  2)
    echo "Importing existing certificate..."
    read -rp "Enter path to the certificate file (.pem): " SRC_CERT
    read -rp "Enter path to the private key file (.key): " SRC_KEY
    if [ ! -f "$SRC_CERT" ] || [ ! -f "$SRC_KEY" ]; then
      echo "ERROR: Certificate or key file not found. Aborting."
      exit 1
    fi
    mkdir -p /etc/ssl/private
    cp "$SRC_CERT" "${CERT_FILE}"
    cp "$SRC_KEY" "${KEY_FILE}"
    chmod o= "${KEY_FILE}"
    ;;
  *)
    echo "Invalid choice. Aborting."
    exit 1
    ;;
esac

######################################
# 5. Install Required Packages
######################################
echo "=== Installing required packages ==="
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  postfix \
  dovecot-core dovecot-imapd dovecot-pop3d \
  roundcube roundcube-sqlite3 \
  php-mbstring php-xml php-json php-zip php-gd \
  apache2 \
  openssl

######################################
# 6. Create 'vmail' User/Group
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
# 7. Configure Postfix with SSL
######################################
echo "=== Configuring Postfix with SSL ==="
cp /etc/postfix/main.cf /etc/postfix/main.cf.bak."$(date +%F-%T)"

postconf -e "myhostname = ${MAIL_HOSTNAME}"
postconf -e "mydomain = ${MAIL_DOMAIN}"
postconf -e "mydestination = localhost, localhost.localdomain, \$myhostname"
postconf -e "mynetworks_style = host"
postconf -e "smtpd_banner = \$myhostname ESMTP \$mail_name (SSL Enabled)"
postconf -e "biff = no"

# Enable TLS in Postfix
postconf -e "smtpd_use_tls=yes"
postconf -e "smtpd_tls_auth_only=yes"
postconf -e "smtpd_tls_security_level=encrypt"
postconf -e "smtpd_tls_cert_file=${CERT_FILE}"
postconf -e "smtpd_tls_key_file=${KEY_FILE}"
postconf -e "smtp_tls_security_level=encrypt"
postconf -e "smtp_tls_loglevel=1"

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

# Aliases
postconf -e "alias_maps = hash:/etc/aliases"
postconf -e "alias_database = hash:/etc/aliases"
sed -i "/^postmaster:/d" /etc/aliases
echo "postmaster: ${POSTMASTER_ADDRESS}" >> /etc/aliases
newaliases

# Configure Postfix virtual mailbox map
cat > "${POSTFIX_VMAILBOX}" <<EOF
${TEST_USER}   ${MAIL_DOMAIN}/$(echo "$TEST_USER" | cut -d@ -f1)/
EOF
postmap "${POSTFIX_VMAILBOX}"

######################################
# 8. Configure Dovecot with SSL
######################################
echo "=== Configuring Dovecot with SSL ==="
cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-mail.conf /etc/dovecot/conf.d/10-mail.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-auth.conf /etc/dovecot/conf.d/10-auth.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-master.conf /etc/dovecot/conf.d/10-master.conf.bak."$(date +%F-%T)"
cp /etc/dovecot/conf.d/10-ssl.conf /etc/dovecot/conf.d/10-ssl.conf.bak."$(date +%F-%T)"

# Listen on all interfaces
sed -i "s|^#\?listen = \*, ::|listen = \*, ::|" /etc/dovecot/dovecot.conf

# Set mail_location so that mail is stored in /var/mail/vhosts/<domain>/<user>
sed -i "s|^#\?mail_location = .*|mail_location = maildir:${VMAIL_DIR}/%d/%n|" /etc/dovecot/conf.d/10-mail.conf

# Allow plaintext auth over TLS so authentication works
sed -i "s|^#\?disable_plaintext_auth = yes|disable_plaintext_auth = no|" /etc/dovecot/conf.d/10-auth.conf

# Disable system auth, enable passwd-file
sed -i "s/^!include auth-system.conf.ext/#!include auth-system.conf.ext/" /etc/dovecot/conf.d/10-auth.conf
sed -i "s/^#!include auth-passwdfile.conf.ext/!include auth-passwdfile.conf.ext/" /etc/dovecot/conf.d/10-auth.conf

# Create Dovecot passwd-file configuration
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

# Enable SSL in Dovecot
sed -i "s|^#\?ssl = .*|ssl = yes|" /etc/dovecot/conf.d/10-ssl.conf
sed -i "s|^ssl_cert = .*|ssl_cert = <${CERT_FILE}|" /etc/dovecot/conf.d/10-ssl.conf
sed -i "s|^ssl_key = .*|ssl_key = <${KEY_FILE}|" /etc/dovecot/conf.d/10-ssl.conf

# Configure Dovecot SASL for Postfix
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
# 9. Create Test User in Dovecot
######################################
mkdir -p /etc/dovecot
touch "${DOVECOT_USERS}"
HASH=$(doveadm pw -s SHA512-CRYPT -p "${TEST_PASS}")
echo "${TEST_USER}:${HASH}" >> "${DOVECOT_USERS}"
chown root:dovecot "${DOVECOT_USERS}"
chmod 640 "${DOVECOT_USERS}"

######################################
# 10. Configure Roundcube for SSL
######################################
echo "=== Configuring Roundcube for SSL ==="
# Create symlink to Roundcube if not already present
if [ ! -d "/var/www/html/roundcube" ]; then
  ln -s /usr/share/roundcube /var/www/html/roundcube
fi

ROUNDCUBE_CONFIG="/etc/roundcube/config.inc.php"
if [ ! -f "$ROUNDCUBE_CONFIG" ]; then
  cat > "$ROUNDCUBE_CONFIG" <<EOF
<?php
\$config['default_host'] = 'ssl://${MAIL_HOSTNAME}';
\$config['smtp_server'] = 'ssl://${MAIL_HOSTNAME}';
\$config['smtp_port'] = 465;
EOF
fi

# Configure Roundcube database connection (SQLite)
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

# Set Roundcube default_host and default_port for IMAPS (SSL)
if grep -q "\$config\['default_host'\]" "$ROUNDCUBE_CONFIG"; then
  sed -i "s|\(\$config\['default_host'\]\).*=.*|\$config['default_host'] = 'ssl://${MAIL_HOSTNAME}';|" "$ROUNDCUBE_CONFIG"
else
  cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['default_host'] = 'ssl://${MAIL_HOSTNAME}';
EOF
fi

if grep -q "\$config\['default_port'\]" "$ROUNDCUBE_CONFIG"; then
  sed -i "s|\(\$config\['default_port'\]\).*=.*|\$config['default_port'] = 993;|" "$ROUNDCUBE_CONFIG"
else
  cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['default_port'] = 993;
EOF
fi

# Hide the "Server" field
if grep -q "\$config\['display_server_choice'\]" "$ROUNDCUBE_CONFIG"; then
  sed -i "s|\(\$config\['display_server_choice'\]\).*=.*|\$config['display_server_choice'] = false;|" "$ROUNDCUBE_CONFIG"
else
  cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['display_server_choice'] = false;
EOF
fi

# Force SMTP port to 465 for sending mail
if grep -q "\$config\['smtp_port'\]" "$ROUNDCUBE_CONFIG"; then
  sed -i "s|\(\$config\['smtp_port'\]\).*=.*|\$config['smtp_port'] = 465;|" "$ROUNDCUBE_CONFIG"
else
  cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['smtp_port'] = 465;
EOF
fi

# If using a self-signed certificate, configure Roundcube to ignore cert validation
if [ "${IGNORE_CERT_VALIDATION_IN_ROUNDCUBE}" = "true" ]; then
  if grep -q "\$config\['imap_conn_options'\]" "$ROUNDCUBE_CONFIG"; then
    sed -i "/\$config\['imap_conn_options'\]/,/);/d" "$ROUNDCUBE_CONFIG"
  fi
  cat <<EOF >> "$ROUNDCUBE_CONFIG"

\$config['imap_conn_options'] = array(
  'ssl' => array(
    'verify_peer' => false,
    'verify_peer_name' => false,
  ),
);
\$config['smtp_conn_options'] = array(
  'ssl' => array(
    'verify_peer' => false,
    'verify_peer_name' => false,
  ),
);
EOF
  echo "Roundcube will ignore certificate validation due to self-signed certificate."
fi

######################################
# 11. Enable Apache SSL and Restart Apache
######################################
echo "=== Enabling Apache SSL Module and Default SSL Site ==="
a2enmod ssl
a2ensite default-ssl
systemctl restart apache2

######################################
# 12. Restart Services
######################################
echo "=== Restarting Postfix, Dovecot, and Apache ==="
systemctl restart postfix
systemctl restart dovecot
systemctl enable postfix
systemctl enable dovecot

systemctl restart apache2
systemctl enable apache2

######################################
# 13. Final Output
######################################
echo "=============================================================="
echo " Dovecot + Postfix + Roundcube installed with SSL!"
echo " Mail domain:   ${MAIL_DOMAIN}"
echo " Hostname:      ${MAIL_HOSTNAME}"
echo " Test user:     ${TEST_USER}"
echo " Test password: ${TEST_PASS}"
echo
echo " * SMTP (SMTPS) port: 465 (encrypted)"
echo " * IMAP (IMAPS) port: 993 (encrypted)"
echo " Roundcube Web Interface: https://<server-ip>/roundcube"
echo "=============================================================="
