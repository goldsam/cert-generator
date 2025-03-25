#!/bin/bash
set -e

# Check for config file argument
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <config-file.json|config-file.yaml> [output-directory]"
    exit 1
fi

CONFIG_FILE="$1"
OUTPUT_DIR="${2:-.}"  # Default to current directory if not specified

# Convert the config file to JSON
CONFIG_JSON=$(mktemp)
yq eval -o=json "." "$CONFIG_FILE" > "$CONFIG_JSON"

# Validate the configuration file against the schema
echo "Validating configuration file $CONFIG_FILE..."
/usr/local/bin/jsonschema "/config.schema.json" -i "$CONFIG_JSON"
CONFIG_VALID=$?
rm -f "$CONFIG_JSON"
if [ $CONFIG_VALID != "0" ]; then
    echo "Configuration file validation failed!"
    exit 1
fi

# Create output directory if it doesn't exist
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
fi

# Get the number of certificates in the config.
CERT_COUNT=$(yq e '.certificates | length' "$CONFIG_FILE")
if [ "$CERT_COUNT" -eq 0 ]; then
    echo "No certificates found in the configuration."
    exit 2
fi

# Track failures
failures=0

# Set default subject properties from environment variables
DEFAULT_digestAlgorithm=${DEFAULT_digestAlgorithm:-"sha256"}
DEFAULT_C=${DEFAULT_C:-"US"}
DEFAULT_ST=${DEFAULT_ST:-"California"}
DEFAULT_L=${DEFAULT_L:-"San Francisco"}
DEFAULT_O=${DEFAULT_O:-"My Company"}
DEFAULT_OU=${DEFAULT_OU:-"IT"}
DEFAULT_CN=${DEFAULT_CN:-"example.com"}
DEFAULT_emailAddress=${DEFAULT_emailAddress:-"admin@example.com"}
DEFAULT_validityDays=${DEFAULT_validityDays:-"365"}
DEFAULT_keySize=${DEFAULT_keySize:-"2048"}

# Process each certificate record.
for i in $(seq 0 $(($CERT_COUNT - 1))); do
    # Read certificate properties from the configuration.
    certName=$(yq e ".certificates[$i].name" "$CONFIG_FILE")
    subjectC=$(yq e ".certificates[$i].subject.C // \"$DEFAULT_C\"" "$CONFIG_FILE")
    subjectST=$(yq e ".certificates[$i].subject.ST // \"$DEFAULT_ST\"" "$CONFIG_FILE")
    subjectL=$(yq e ".certificates[$i].subject.L // \"$DEFAULT_L\"" "$CONFIG_FILE")
    subjectO=$(yq e ".certificates[$i].subject.O // \"$DEFAULT_O\"" "$CONFIG_FILE")
    subjectOU=$(yq e ".certificates[$i].subject.OU // \"$DEFAULT_OU\"" "$CONFIG_FILE")
    subjectCN=$(yq e ".certificates[$i].subject.CN // \"$DEFAULT_CN\"" "$CONFIG_FILE")
    emailAddress=$(yq e ".certificates[$i].subject.emailAddress // \"$DEFAULT_emailAddress\"" "$CONFIG_FILE")

    keySize=$(yq e ".certificates[$i].keySize // \"$DEFAULT_keySize\"" "$CONFIG_FILE")
    digestAlgorithm=$(yq e ".certificates[$i].digestAlgorithm // \"$DEFAULT_digestAlgorithm\"" "$CONFIG_FILE")
    validityDays=$(yq e ".certificates[$i].validityDays // \"$DEFAULT_validityDays\"" "$CONFIG_FILE")
    
    echo "keySize=$keySize"
    # Convert digest algorithm to lowercase and prefix with a dash.
    digestOption="-$(echo "$digestAlgorithm" | tr '[:upper:]' '[:lower:]')"

    # Build the subject string in OpenSSL format.
    subjectStr="subject=C=${subjectC}, ST=${subjectST}, L=${subjectL}, O=${subjectO}"
    if [ "$subjectOU" != "null" ] && [ -n "$subjectOU" ]; then
      subjectStr="${subjectStr}, OU=${subjectOU}"
    fi
    subjectStr="${subjectStr}, CN=${subjectCN}"
    if [ "$emailAddress" != "null" ] && [ -n "$emailAddress" ]; then
      subjectStr="${subjectStr}, emailAddress=${emailAddress}"
    fi

    # Create a temporary OpenSSL extension configuration file for SAN.
    extFile=$(mktemp)
        
    cat <<EOF > "$extFile"
[ req ]
default_bits       = ${keySize} 
distinguished_name = req_distinguished_name
req_extensions     = req_ext
x509_extensions    = v3_req
prompt             = no

[ req_distinguished_name ]
C                  = ${subjectC}
ST                 = ${subjectST}
L                  = ${subjectL}
O                  = ${subjectO}
OU                 = ${subjectOU}
CN                 = ${subjectCN}
emailAddress       = ${emailAddress}

EOF
        
    # Process the SAN list if it exists.
    sanCount=$(yq e ".certificates[$i].san | length" "$CONFIG_FILE" 2>/dev/null || echo 0)
    SAN_PRESENT=0
    if [ "$sanCount" -gt 0 ]; then
        SAN_PRESENT=1
        
        cat <<EOF >> "$extFile"
[ req_ext ]
subjectAltName = @alt_names

[ v3_req ]
subjectAltName = @alt_names

[ alt_names ]
EOF

        for j in $(seq 0 $(($sanCount - 1))); do
            sanEntry=$(yq e ".certificates[$i].san[$j]" "$CONFIG_FILE")
            echo "DNS.$((j+1)) = $sanEntry" >> "$extFile"
        done

    else
        cat <<EOF >> "$extFile"
[ req_ext ]

[ v3_req ]
EOF

    fi

    # Define file names for the key, CSR, and certs.
    keyFile="$OUTPUT_DIR/${certName}.key"
    csrFile="$OUTPUT_DIR/${certName}.csr"
    certFile="$OUTPUT_DIR/${certName}.crt"
    pfxFile="$OUTPUT_DIR/${certName}.pfx"
    
    regenerate=0

    # If the certificate file exists, compare its subject, SANs, key size, and digest algorithm.
    if [ -f "$certFile" ]; then
        currentSubject=$(openssl x509 -in "$certFile" -noout -subject | sed 's/subject= //')
        # Check subject: ensure the certificate's subject includes the expected common name.
        if [ "$currentSubject" != "$subjectStr" ]; then
            echo "Subject mismatch for $certName."
            regenerate=1
        fi

        # Check SAN entries if provided.
        if [ $SAN_PRESENT -eq 1 ]; then
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

        # Check key size.
        # Extract the key size from the certificate's text. This assumes a line like "Public-Key: (2048 bit)".
        currentKeySize=$(openssl x509 -in "$certFile" -noout -text | grep "Public-Key" | head -n1 | awk -F'[(]' '{print $2}' | awk -F' ' '{print $1}')
        if [ "$currentKeySize" != "$keySize" ]; then
            echo "Key size mismatch for $certName. Expected ${keySize}, got ${currentKeySize}."
            regenerate=1
        fi

        # Check digest algorithm.
        # Extract the signature algorithm, e.g. "sha256WithRSAEncryption".
        currentDigest=$(openssl x509 -in "$certFile" -noout -text | grep "Signature Algorithm" | head -n1 | awk -F': ' '{print $2}')
        if ! echo "$currentDigest" | grep -qi "$digestAlgorithm"; then
            echo "Digest algorithm mismatch for $certName. Expected ${digestAlgorithm}, got ${currentDigest}."
            regenerate=1
        fi
    else
        regenerate=1
    fi

    # Regenerate the certificate if needed.
    if [ $regenerate -eq 1 ]; then
        # Create private key + CSR:
        echo "Generating key and CSR for $certName..."
        openssl req $digestOption -newkey rsa:${keySize} -nodes \
            -keyout "$keyFile" -out "$csrFile" -config "$extFile"
        if [ $? -ne 0 ]; then
            echo "Failed to generate key and CSR for $certName!"
            failures=1
        else
            echo "Generating self-signed certificate for $certName..."                  
            openssl x509 $digestOption -req -days ${validityDays} -in "$csrFile" \
                -signkey "$keyFile" -extensions v3_req -extfile "$extFile" -out "$certFile"
            if [ $? -ne 0 ]; then
                echo "Failed to generate self-signed certificate for $certName!"
                failures=1
            fi
        fi 
    # rm -f "$extFile"
    else
        echo "Certificate and key files for $certName are up-to-date."
    fi

    # Generate PFX file if requested
    pfxRegenerate=$regenerate
    
    # First check if the PFX file doesn't exist
    if [ ! -f "$pfxFile" ]; then
        echo "PFX file does not exist, will generate."
        pfxRegenerate=1
    fi

    if [ $pfxRegenerate -eq 1 ]; then
        # Create the PFX file
        echo "Generating unprotected PFX file for $certName..."
        openssl pkcs12 -export -out "$pfxFile" -inkey "$keyFile" -in "$certFile" -passout pass:
        if [ $? -ne 0 ]; then
            echo "Failed to generate PFX file for $certName!"
            failures=1
        else
            echo "PFX file generated successfully."
        fi
    else
        echo "PFX file for $certName is up-to-date."
    fi

done

# Print success message only if there were no failures
if [ $failures -eq 0 ]; then
    echo "All files are now up-to-date."
fi