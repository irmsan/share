#!/bin/bash

#
# Licensed Materials - Property of IBM
#
# (c) Copyright IBM Corp. 2023
#
# The source code for this program is not published or otherwise
# divested of its trade secrets, irrespective of what has been
# deposited with the U.S. Copyright Office
#

DURATION=7300

# Ensure DOMAIN is set
if [[ -z "$DOMAIN" ]]; then
    echo "OSO Domain not set"
    exit 1
fi
export DOMAIN

# Collect remote parameters upfront
read -p "LPAR2 admin user: " LPAR2_ADMIN
read -p "LPAR2 IP address: " LPAR2_IP
read -p "LPAR2 SCP target dir (e.g. /home/<user>/oso-install-main/new-vm-lpar2): " LPAR2_SCP_DIR

#############################################################################################################################
#############################################################################################################################
function createcerts {

    ## CA
    [ -f lpar1-ca-key.pem ] || openssl genrsa -out lpar1-ca-key.pem 4096
    [ -f lpar1-ca.crt ] || {
        openssl req -config ca.cnf -key lpar1-ca-key.pem -new -out lpar1-ca-req.csr
        openssl x509 -signkey lpar1-ca-key.pem -extfile ca.cnf -extensions v3_ca -in lpar1-ca-req.csr -req -days $DURATION -out lpar1-ca.crt
    }

    # Logging server certificate
    [ -f lpar1-logging-server-key.pem ] || openssl genrsa -out lpar1-logging-server-key.pem 4096
    [ -f lpar1-logging-server.crt ] || {
        openssl req -config logging-server.cnf -key lpar1-logging-server-key.pem -new -out lpar1-logging-server-req.csr
        openssl x509 -in lpar1-logging-server-req.csr -req -days $DURATION -CA lpar1-ca.crt -CAkey lpar1-ca-key.pem -CAcreateserial -extfile logging-server.cnf -extensions logging-server -out lpar1-logging-server.crt
    }

    # Client certificate
    [ -f lpar1-client-key.pem ] || openssl genrsa -out lpar1-client-key.pem 4096
    [ -f lpar1-client.crt ] || {
        openssl req -config client.cnf -key lpar1-client-key.pem -new -out lpar1-client-req.csr
        openssl x509 -in lpar1-client-req.csr -req -days $DURATION -CA lpar1-ca.crt -CAkey lpar1-ca-key.pem -CAcreateserial -out lpar1-client.crt
    }
    # Uncomment this line if PKCS8 format is required:
    # openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in lpar1-client-key.pem -out lpar1-client-key-pkcs8.pem

    # SCP files to remote server
    scp lpar1-logging-server.crt lpar1-client.crt lpar1-client-key.pem ${LPAR2_ADMIN}@${LPAR2_IP}:${LPAR2_SCP_DIR}
}

#############################################################################################################################
#############################################################################################################################
function setrsyslog {

    # Check if existing rsyslog certificates exist
    if [ -f /logging/lpar1-logging-server.crt ]; then
        echo "WARNING: Existing rsyslog certs found, remove existing config to apply new ones"
        return
    fi

    # Prepare /logging directory
    mkdir -p /logging
    cp lpar1-ca.crt /logging/
    cp lpar1-logging-server.crt /logging/
    cp lpar1-logging-server-key.pem /logging/

    # Set proper SELinux context
    semanage fcontext -a -t syslog_conf_t "/logging/(.*)"
    restorecon -R -v /logging

    # Configure rsyslog
    cp 100-server.conf /etc/rsyslog.d/

    # ====== RESTART RSYSLOG ======
    echo "Restarting rsyslog..."
    systemctl restart rsyslog

    # ====== STATUS CHECK ======
    SERVICE_STATUS=$(systemctl is-active rsyslog)

    if [ "$SERVICE_STATUS" == "active" ]; then
        echo "✅ rsyslog service is now running."
    else
        echo "❌ rsyslog service failed to start. Status: $SERVICE_STATUS"
    fi
}

#############################################################################################################################
## Main
#############################################################################################################################

# Ensure docker certs directory exists
[ -d /etc/docker/certs.d/osoregistry ] || mkdir -p /etc/docker/certs.d/osoregistry

# Ensure osoregistry entry in /etc/hosts
grep -q "osoregistry.$DOMAIN" /etc/hosts || echo "192.168.0.2 osoregistry.$DOMAIN osoregistry" >> /etc/hosts

# Main interactive menu
while true; do
    echo
    echo "Choose option:"
    echo "1) Generate certificates"
    echo "2) Configure rsyslog"
    echo "X) Exit"
    echo

    read -p "Enter your choice (1, 2, or X): " choice
    choice=${choice^^}  # convert input to uppercase

    case $choice in
        1)
            createcerts
            ;;
        2)
            setrsyslog
            ;;
        X)
            exit 0
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac
done
