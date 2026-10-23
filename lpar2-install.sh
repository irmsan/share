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

# Define variables
REGISTRY_USER="registryuser"
REGISTRY_PASS="password"
REGISTRY_ADDRESS="192.168.0.2"
DURATION=7300

if [[ -z "$DOMAIN" ]]; then
    echo "OSO Domain not set"
    exit 1
fi
export DOMAIN

# Collect remote parameters upfront
read -p "LPAR3 admin user: " LPAR3_ADMIN
read -p "LPAR3 IP address: " LPAR3_IP
read -p "LPAR3 SCP target dir (e.g. /home/<user>/oso-install-main/new-vm-lpar3): " LPAR3_SCP_DIR

#############################################################################################################################
#############################################################################################################################
function createcerts {

    # CA
    [ -f lpar2-ca-key.pem ] || openssl genrsa -out lpar2-ca-key.pem 4096
    [ -f lpar2-ca.crt ] || openssl req -config ca.cnf -key lpar2-ca-key.pem -new -out lpar2-ca-req.csr
    [ -f lpar2-ca.crt ] || openssl x509 -signkey lpar2-ca-key.pem -extfile ca.cnf -extensions v3_ca -in lpar2-ca-req.csr -req -days $DURATION -out lpar2-ca.crt

    # Logging
    [ -f lpar2-logging-server-key.pem ] || openssl genrsa -out lpar2-logging-server-key.pem 4096
    [ -f lpar2-logging-server.crt ] || openssl req -config logging-server.cnf -key lpar2-logging-server-key.pem -new -out lpar2-logging-server-req.csr
    [ -f lpar2-logging-server.crt ] || openssl x509 -in lpar2-logging-server-req.csr -req -days $DURATION -CA lpar2-ca.crt -CAkey lpar2-ca-key.pem -CAcreateserial -extfile logging-server.cnf -extensions logging-server -out lpar2-logging-server.crt

    # Registry
    [ -f lpar2-registry-server-key.pem ] || openssl genrsa -out lpar2-registry-server-key.pem 4096
    [ -f lpar2-registry-server-req.crt ] || openssl req -config registry-server.cnf -key lpar2-registry-server-key.pem -new -out lpar2-registry-server-req.csr
    [ -f lpar2-registry-server-req.crt ] || openssl x509 -in lpar2-registry-server-req.csr -req -days $DURATION -CA lpar2-ca.crt -CAkey lpar2-ca-key.pem -CAcreateserial -extfile registry-server.cnf -extensions registry-server -out lpar2-registry-server.crt

    # Client
    [ -f lpar2-client-key.pem ] || openssl genrsa -out lpar2-client-key.pem 4096
    [ -f lpar2-client.crt ] || openssl req -config client.cnf -key lpar2-client-key.pem -new -out lpar2-client-req.csr
    [ -f lpar2-client.crt ] || openssl x509 -in lpar2-client-req.csr -req -days $DURATION -CA lpar2-ca.crt -CAkey lpar2-ca-key.pem -CAcreateserial -out lpar2-client.crt
    #openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in lpar2-client-key.pem -out lpar2-client-key-pkcs8.pem

    echo "Copy the files to LPAR3 for rsyslog and for the registry"
    scp lpar2-logging-server.crt lpar2-client.crt lpar2-client-key.pem lpar2-registry-server-key.pem lpar2-registry-server.crt lpar2-ca.crt ${LPAR3_ADMIN}@${LPAR3_IP}:${LPAR3_SCP_DIR}
}

#############################################################################################################################
#############################################################################################################################
function setrsyslog {
    if [ -f /logging/lpar2-logging-server.crt ]; then
        echo "WARNING: Existing rsyslog certs found, remove existing config to apply new ones"
        return
    fi

    mkdir -p /logging
    cp lpar2-ca.crt /logging/
    cp lpar2-logging-server.crt /logging/
    cp lpar2-logging-server-key.pem /logging/

    # Check for lpar1 files with prefix lpar1- (files from lpar1 should stay as is)
    for i in lpar1-logging-server.crt lpar1-client.crt lpar1-client-key.pem; do
        if [ ! -f $i ]; then
            echo "Missing $i file to connect LPAR1 rsyslog"
            exit 1
        fi
        cp $i /logging/
    done

    semanage fcontext -a -t syslog_conf_t "/logging/(.*)"
    restorecon -R -v /logging

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
#############################################################################################################################
function setregistry {

    grep -q "osoregistry.$DOMAIN" /etc/hosts || echo "192.168.0.2 osoregistry.$DOMAIN osoregistry" >> /etc/hosts

    if ! id "$REGISTRY_USER" &>/dev/null; then
        echo "User $REGISTRY_USER not defined, so creating NOW"
        useradd "$REGISTRY_USER"
    fi

    # Ensure directories exist
    mkdir -p /home/$REGISTRY_USER/data
    mkdir -p /home/$REGISTRY_USER/conf

    # Modify the config.yml and registry.service files before copying it
    echo "Modifying registry.service: inserting $REGISTRY_USER as user, group, and in /home/$REGISTRY_USER/... paths in registry.service"
    sed -i "s|^User=.*|User=$REGISTRY_USER|" registry.service
    sed -i "s|^Group=.*|Group=$REGISTRY_USER|" registry.service
    sed -i "s|/home//\{0,1\}[^/]*|/home/$REGISTRY_USER|g" registry.service

    echo "Modifying config.yml: inserting $REGISTRY_USER in all /home/$REGISTRY_USER/... paths"
    sed -i "s|/home//\{0,1\}[^/]*|/home/$REGISTRY_USER|g" config.yml


    # Copy the modified config.yml to the user's directory
    [ -f /home/$REGISTRY_USER/config.yml ] || cp config.yml /home/$REGISTRY_USER/

    # Generate htpasswd file
    htpasswd -Bbn "$REGISTRY_USER" "$REGISTRY_PASS" > htpasswd

    if [ ! -f htpasswd ]; then
        echo "Registry password file not created, exiting"
        exit 1
    fi

    # Copy the generated htpasswd file to the correct location
    cp htpasswd /home/$REGISTRY_USER/conf/

    # Copy the necessary SSL certificates and keys
    cp lpar2-registry-server.crt /home/$REGISTRY_USER/conf/server.crt
    cp lpar2-registry-server-key.pem /home/$REGISTRY_USER/conf/server-key.pem

    # Set the correct ownership of the registry files
    chown -R $REGISTRY_USER:$REGISTRY_USER /home/$REGISTRY_USER/*

    # Ensure Docker certs directory exists
    mkdir -p /etc/docker/certs.d/$REGISTRY_ADDRESS
    [ -f /etc/docker/certs.d/$REGISTRY_ADDRESS/lpar2-ca.crt ] || cp lpar2-ca.crt /etc/docker/certs.d/$REGISTRY_ADDRESS/

    # Copy the modified registry.service to systemd folder
    if [ ! -f /etc/systemd/system/registry.service ]; then
        cp registry.service /etc/systemd/system/
    fi

    # Copy only if not already present
    if [ ! -f /usr/bin/registry ]; then
        cp ../registry /usr/bin/registry
    fi

    # Set capability only if not already set
    if ! getcap /usr/bin/registry 2>/dev/null | grep -q cap_net_bind_service; then
        setcap 'cap_net_bind_service=+ep' /usr/bin/registry
    fi

    # Enable only if not enabled
    if ! systemctl is-enabled registry >/dev/null 2>&1; then
        systemctl enable registry
    fi

    # Start only if not active
    if ! systemctl is-active --quiet registry; then
        systemctl start registry
    fi

    # Check the status of the registry service
    SERVICE_STATUS=$(systemctl is-active registry)

    if [ "$SERVICE_STATUS" == "active" ]; then
        echo "Registry service is now set up and running."
    else
        echo "Failed to start the registry service. Status: $SERVICE_STATUS"
    fi
}

#############################################################################################################################
while true; do
    echo
    echo "Choose option"
    echo "1) Generate certificates"
    echo "2) Configure rsyslog"
    echo "3) Configure the registry"
    echo "X) Exit"
    echo
    read -p "Enter your choice (1, 2, 3, or X): " choice
    choice=${choice^^}  # convert input to uppercase

    # Use a case statement to handle the choice
    case $choice in
        1)
            createcerts
            ;;
        2)
            setrsyslog
            ;;
        3)
            setregistry
            ;;
        X)
            exit 0
            ;;
        *)
            echo "Invalid choice."
            ;;
    esac
done
