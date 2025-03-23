#!/bin/bash
set -e

# Check for config file argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <config-file.json|config-file.yaml>"
    exit 1
fi

CONFIG_FILE="$1"

# Get the number of certificates in the config.
CERT_COUNT=$(yq e '.certificates | length' "$CONFIG_FILE")
if [ "$CERT_COUNT" -eq 0 ]; then
    echo "No certificates found in the configuration."
    exit 0
fi

# Process each certificate record.
for i in $(seq 0 $(($CERT_COUNT - 1))); do
    # Read certificate properties from the configuration.
    certName=$(yq e ".certificates[$i].certName" "$CONFIG_FILE")
    subjectC=$(yq e ".certificates[$i].subject.C" "$CONFIG_FILE")
    subjectST=$(yq e ".certificates[$i].subject.ST" "$CONFIG_FILE")
    subjectL=$(yq e ".certificates[$i].subject.L" "$CONFIG_FILE")
    subjectO=$(yq e ".certificates[$i].subject.O" "$CONFIG_FILE")
    subjectOU=$(yq e ".certificates[$i].subject.OU" "$CONFIG_FILE")
    subjectCN=$(yq e ".certificates[$i].subject.CN" "$CONFIG_FILE")
    emailAddress=$(yq e ".certificates[$i].subject.emailAddress" "$CONFIG_FILE")
    keySize=$(yq e ".certificates[$i].keySize" "$CONFIG_FILE")
    digestAlgorithm=$(yq e ".certificates[$i].digestAlgorithm" "$CONFIG_FILE")
    validityDays=$(yq e ".certificates[$i].validityDays" "$CONFIG_FILE")
    
    # Build the subject string in OpenSSL format.
    subjectStr="/C=${subjectC}/ST=${subjectST}/L=${subjectL}/O=${subjectO}"
    if [ "$subjectOU" != "null" ] && [ -n "$subjectOU" ]; then
      subjectStr="${subjectStr}/OU=${subjectOU}"
    fi
    subjectStr="${subjectStr}/CN=${subjectCN}"
    if [ "$emailAddress" != "null" ] && [ -n "$emailAddress" ]; then
      subjectStr="${subjectStr}/emailAddress=${emailAddress}"
    fi

    # Process the SAN list if it exists.
    sanCount=$(yq e ".certificates[$i].san | length" "$CONFIG_FILE" 2>/dev/null || echo 0)
    SAN_PRESENT=0
    if [ "$sanCount" -gt 0 ]; then
        SAN_PRESENT=1
        # Create a temporary OpenSSL extension configuration file for SAN.
        extFile=$(mktemp)
        cat > "$extFile" <<EOF
[ req ]
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
[ v3_req ]
subjectAltName = @alt_names
[ alt_names ]
EOF
        for j in $(seq 0 $(($sanCount - 1))); do
            sanEntry=$(yq e ".certificates[$i].san[$j]" "$CONFIG_FILE")
            echo "DNS.$((j+1)) = $sanEntry" >> "$extFile"
        done
    fi

    # Define file names for the certificate and key.
    certFile="${certName}.crt"
    keyFile="${certName}.key"

    regenerate=0

    # If the certificate file exists, compare its subject and SANs.
    if [ -f "$certFile" ]; then
        currentSubject=$(openssl x509 -in "$certFile" -noout -subject | sed 's/subject= //')
        # A simple check: ensure the certificate's subject includes the expected common name.
        if ! echo "$currentSubject" | grep -q "$subjectCN"; then
            echo "Subject mismatch for $certName."
            regenerate=1
        fi

        if [ $SAN_PRESENT -eq 1 ]; then
            # Extract the SAN extension from the certificate.
            currentSAN=$(openssl x509 -in "$certFile" -noout -ext subjectAltName | sed 's/subjectAltName=//')
            for j in $(seq 0 $(($sanCount - 1))); do
                sanEntry=$(yq e ".certificates[$i].san[$j]" "$CONFIG_FILE")
                if ! echo "$currentSAN" | grep -q "$sanEntry"; then
                    echo "SAN entry '$sanEntry' missing in $certName."
                    regenerate=1
                    break
                fi
            done
        fi
    else
        regenerate=1
    fi

    # Regenerate the certificate if needed.
    if [ $regenerate -eq 1 ]; then
        echo "Generating certificate for $certName..."
        if [ $SAN_PRESENT -eq 1 ]; then
            openssl req -new -newkey rsa:${keySize} -nodes -x509 -days ${validityDays} \
              -subj "$subjectStr" -keyout "$keyFile" -out "$certFile" \
              -extensions v3_req -config "$extFile"
            rm "$extFile"
        else
            openssl req -new -newkey rsa:${keySize} -nodes -x509 -days ${validityDays} \
              -subj "$subjectStr" -keyout "$keyFile" -out "$certFile"
        fi
    else
        echo "Certificate $certName is up-to-date."
    fi

done
