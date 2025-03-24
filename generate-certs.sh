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
if [ CONFIG_VALID != "0" ]; then
    echo "Configuration file validation failed!"
    exit 1
fi

echo "CONFIG_VALID:$CONFIG_VALID"
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

# Process each certificate record.
for i in $(seq 0 $(($CERT_COUNT - 1))); do
    # Read certificate properties from the configuration.
    certName=$(yq e ".certificates[$i].name" "$CONFIG_FILE")
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
    
    # Check if pfx object exists first
    pfxExists=$(yq e ".certificates[$i].pfx" "$CONFIG_FILE" 2>/dev/null | grep -v "^null$" | wc -l)
    if [ "$pfxExists" -gt 0 ]; then
        # pfx object exists, so default to true unless specifically false
        pfxGenerate=$(yq e ".certificates[$i].pfx.generate" "$CONFIG_FILE" 2>/dev/null || echo "true")
        pfxPassword=$(yq e ".certificates[$i].pfx.password" "$CONFIG_FILE" 2>/dev/null || echo "")
        if [ "$pfxGenerate" = "null" ]; then
            pfxGenerate="true"
        fi
    else
        # pfx object doesn't exist, default to false
        pfxGenerate="false"
    fi
    
    # Convert digest algorithm to lowercase and prefix with a dash.
    digestOption="-$(echo "$digestAlgorithm" | tr '[:upper:]' '[:lower:]')"

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
    certFile="$OUTPUT_DIR/${certName}.crt"
    keyFile="$OUTPUT_DIR/${certName}.key"

    regenerate=0

    # If the certificate file exists, compare its subject, SANs, key size, and digest algorithm.
    if [ -f "$certFile" ]; then
        currentSubject=$(openssl x509 -in "$certFile" -noout -subject | sed 's/subject= //')
        # Check subject: ensure the certificate's subject includes the expected common name.
        if ! echo "$currentSubject" | grep -q "$subjectCN"; then
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
        echo "Generating key and certificate for $certName..."
        if [ $SAN_PRESENT -eq 1 ]; then
            openssl req $digestOption -new -newkey rsa:${keySize} -nodes -x509 -days ${validityDays} \
              -subj "$subjectStr" -keyout "$keyFile" -out "$certFile" \
              -extensions v3_req -config "$extFile"
            if [ $? -ne 0 ]; then
                echo "Failed to generate key and certificate files for $certName!"
                failures=1
            fi
            rm "$extFile"
        else
            openssl req $digestOption -new -newkey rsa:${keySize} -nodes -x509 -days ${validityDays} \
              -subj "$subjectStr" -keyout "$keyFile" -out "$certFile"
            if [ $? -ne 0 ]; then
                echo "Failed to generate key and certificate files for $certName!"
                failures=1
            fi
        fi
    else
        echo "Certificate and key files for $certName are up-to-date."
    fi

    # Generate PFX file if requested
    if [ "$pfxGenerate" = "true" ]; then
        pfxFile="$OUTPUT_DIR/${certName}.pfx"
        pfxRegenerate=$regenerate
        
        # First check if the PFX file doesn't exist
        if [ ! -f "$pfxFile" ]; then
        
            echo "PFX file does not exist, will generate."
            pfxRegenerate=1
        # Then check if password can decrypt existing file
        elif [ -n "$pfxPassword" ]; then
            # Test if the provided password can decrypt the existing PFX
            if ! openssl pkcs12 -in "$pfxFile" -passin "pass:$pfxPassword" -noout 2>/dev/null; then
                echo "Cannot decrypt existing PFX with provided password, will regenerate."
                pfxRegenerate=1
            fi
        fi
        
        if [ $pfxRegenerate -eq 1 ]; then
            # Create the PFX file
            if [ -z "$pfxPassword" ]; then
                echo "Generating unprotected PFX file for $certName..."
                openssl pkcs12 -export -out "$pfxFile" -inkey "$keyFile" -in "$certFile" -nodes
            else
                echo "Generating password protected PFX file for $certName..."
                openssl pkcs12 -export -out "$pfxFile" -inkey "$keyFile" -in "$certFile" -passout "pass:$pfxPassword"
            fi
            if [ $? -ne 0 ]; then
                echo "Failed to generate PFX file for $certName!"
                failures=1
            else
                echo "PFX file generated successfully."
            fi
        else
            echo "PFX file for $certName is up-to-date."
        fi
    fi

done

# Print success message only if there were no failures
if [ $failures -eq 0 ]; then
    echo "All files are now up-to-date."
fi