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
DURATION=7300

if [[ -z "$DOMAIN" ]]; then
    echo "OSO Domain not set"
    exit 1
fi
export DOMAIN

#############################################################################################################################
#############################################################################################################################
function createcerts {

    # CA (Add lpar3- prefix)
    [ -f lpar3-ca-key.pem ] || openssl genrsa -out lpar3-ca-key.pem 4096
    [ -f lpar3-ca.crt ] || openssl req -config ca.cnf -key lpar3-ca-key.pem -new -out lpar3-ca-req.csr
    [ -f lpar3-ca.crt ] || openssl x509 -signkey lpar3-ca-key.pem -extfile ca.cnf -extensions v3_ca -in lpar3-ca-req.csr -req -days $DURATION -out lpar3-ca.crt

    # Logging (Add lpar3- prefix)
    [ -f lpar3-logging-server-key.pem ] || openssl genrsa -out lpar3-logging-server-key.pem 4096
    [ -f lpar3-logging-server.crt ] || openssl req -config logging-server.cnf -key lpar3-logging-server-key.pem -new -out lpar3-logging-server-req.csr
    [ -f lpar3-logging-server.crt ] || openssl x509 -in lpar3-logging-server-req.csr -req -days $DURATION -CA lpar3-ca.crt -CAkey lpar3-ca-key.pem -CAcreateserial -extfile logging-server.cnf -extensions logging-server -out lpar3-logging-server.crt

    # Registry - You mentioned that registry certs are not created, but if they were, they should also have a prefix
    echo "Registry certs are not created on purpose, you can copy LPAR2 lpar2-registry-server-key.pem, lpar2-registry-server.crt, lpar2-ca.crt as lpar2-registryca.crt here"
    # If you were creating registry certs here, they'd get the lpar3- prefix:
    # [ -f lpar3-registry-server-key.pem ] || openssl genrsa -out lpar3-registry-server-key.pem 4096
    # [ -f lpar3-registry-server-req.crt ] || openssl req -config registry-server.cnf -key lpar3-registry-server-key.pem -new -out lpar3-registry-server-req.csr
    # [ -f lpar3-registry-server-req.crt ] || openssl x509 -in lpar3-registry-server-req.csr -req -days $DURATION -CA lpar3-ca.crt -CAkey lpar3-ca-key.pem -CAcreateserial -extfile registry-server.cnf -extensions registry-server -out lpar3-registry-server.crt

    # Client (Add lpar3- prefix)
    [ -f lpar3-client-key.pem ] || openssl genrsa -out lpar3-client-key.pem 4096
    [ -f lpar3-client.crt ] || openssl req -config client.cnf -key lpar3-client-key.pem -new -out lpar3-client-req.csr
    [ -f lpar3-client.crt ] || openssl x509 -in lpar3-client-req.csr -req -days $DURATION -CA lpar3-ca.crt -CAkey lpar3-ca-key.pem -CAcreateserial -out lpar3-client.crt
    #openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in lpar3-client-key.pem -out lpar3-client-key-pkcs8.pem
}

#############################################################################################################################
#############################################################################################################################
function setrsyslog {

    # Ensure the lpar3 prefixed files are used for logging certs
    if [ -f /logging/lpar3-logging-server.crt ]; then
        echo "WARNING: Existing rsyslog certs found, remove existing config to apply new ones"
        return
    fi

    mkdir -p /logging
    cp lpar3-ca.crt /logging/
    cp lpar3-logging-server.crt /logging/
    cp lpar3-logging-server-key.pem /logging/

    # Copy the LPAR2 certificates with lpar2- prefix (these are expected to remain unchanged)
    for i in lpar2-logging-server.crt lpar2-client.crt lpar2-client-key.pem; do
        if [ ! -f $i ]; then
            echo "Missing $i file to connect LPAR2 rsyslog"
            exit 1
        fi
        cp $i /logging
    done

    # Apply the correct SELinux context and permissions
    semanage fcontext -a -t syslog_conf_t "/logging/(.*)"
    restorecon -R -v /logging

    # Copy rsyslog config
    cp 100-server.conf /etc/rsyslog.d

    systemctl restart rsyslog
}

#############################################################################################################################
#############################################################################################################################
function setregistry {

    # Ensure "osoregistry" is in /etc/hosts
    grep -q "osoregistry.$DOMAIN" /etc/hosts || echo "192.168.96.3 osoregistry.$DOMAIN osoregistry" >> /etc/hosts

    # Check if registry certs exist (for LPAR2, using lpar2- prefix)
    if [ ! -f lpar2-registry-server.crt ]; then
        echo "Please copy lpar2-registry-server.crt, lpar2-registry-server-key.pem, lpar2-ca.crt (as lpar2 registry ca.crt) here, we will reuse the same certs as for LPAR2"
        return
    fi

    # Ensure the registry user exists
    if ! id "$REGISTRY_USER" &>/dev/null; then
        echo "User $REGISTRY_USER not defined, will be defined NOW"
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
    [ -f /home/$REGISTRY_USER/config.yml ] || cp config.yml /home/$REGISTRY_USER

    # Generate htpasswd file
    htpasswd -Bbn registryuser "$REGISTRY_PASS" > htpasswd

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
    mkdir -p /etc/docker/certs.d/192.168.64.3:5000
    [ -f /etc/docker/certs.d/192.168.64.3:5000/lpar2-ca.crt ] || cp lpar2-ca.crt /etc/docker/certs.d/192.168.64.3:5000/

    # Ensure the registry service is set up
    if [ ! -f /etc/systemd/system/registry.service ]; then

        # Copy the modified registry.service to systemd folder
        cp registry.service /etc/systemd/system/
        systemctl enable registry
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
## Main
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
