#!/bin/sh

# Ensure a configuration file is provided.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 config.yaml|config.json"
    exit 1
fi

CONFIG_FILE="$1"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file '$CONFIG_FILE' not found."
    exit 3
fi

# Convert the configuration file to JSON to use jsonschema for validation.
CONFIG_JSON=$(mktemp)
trap 'rm -f "$CONFIG_JSON"' EXIT
if ! yq eval -o=json "." "$CONFIG_FILE" > "$CONFIG_JSON"; then
    echo "Error: Configuration file contains malformed JSON or YAML."
    exit 4
fi

# Validate configuration against the schema.
validation_output=$(jsonschema -i "$CONFIG_JSON" /config.schema.json 2>&1)
validation_exit_code=$?
if [ $validation_exit_code -ne 0 ]; then
    echo "Error: Configuration file is invalid:"
    # strip the first line of the output which contains the meaningless temp file name.
    echo "$validation_output" | tail -n +2
    exit 5
fi

# Determine mkcert CA directory.
ca_root=$(mkcert -CAROOT)
ca_cert_pem="${ca_root}/rootCA.pem"

# If the CA certificate is not found, run mkcert -install to create it.
if [ ! -f "$ca_cert" ]; then
    echo "CA certificate not found in ${ca_root}. Running 'mkcert -install' to generate it."
    mkcert -install
fi

# Verify again that the CA certificate now exists.
if [ -f "$ca_cert_pem" ]; then
  cp "$ca_cert_pem" ./rootCA.crt
  echo "CA certificate copied to ./rootCA.crt"
else
  echo "Error: CA certificate still not found in ${ca_root} after mkcert -install"
  exit 6
fi

# Extract additional hosts (if any) as a space-separated list.
additional_hosts=$(yq e '.["additional-hosts"] // [] | join(" ")' "$CONFIG_FILE")

# Get the number of certificate configurations.
cert_count=$(yq e '.certs | length' "$CONFIG_FILE")

if [ "$cert_count" -eq 0 ]; then
    echo "No certificates defined in configuration."
    exit 7
fi

# Track failures
failures=0

# Process each certificate configuration.
for i in $(seq 0 $((cert_count - 1))); do
    name=$(yq e ".certs[$i].name" "$CONFIG_FILE")
    # Default to false if the client property is not provided.
    client=$(yq e ".certs[$i].client // false" "$CONFIG_FILE")
    pfx=$(yq e ".certs[$i].pfx // false" "$CONFIG_FILE")
    # Extract the required hosts list and join into a space-separated string.
    cert_hosts=$(yq e ".certs[$i].hosts // [] | join(\" \")" "$CONFIG_FILE" 2>/dev/null || echo "")

    # If hosts array is empty or not defined, use the name field as the host.
    if [ -z "$cert_hosts" ];then
        cert_hosts="$name"
    fi

    # Combine certificate hosts with additional hosts.
    if [ -n "$additional_hosts" ]; then
        all_hosts="$cert_hosts $additional_hosts"
    else
        all_hosts="$cert_hosts"
    fi

    echo "Generating certificate for '$name' (client: $client) with hosts: $all_hosts..."

    # Build the mkcert command.
    cmd="mkcert -key-file ${name}.key"
    if [ "$client" = "true" ]; then
        cmd="$cmd -client"
    fi
    if [ "$pfx" = "true" ]; then
        cmd="$cmd -pkcs12 -p12-file ${name}.pfx"
    else
        cmd="$cmd -cert-file ${name}.crt"
    fi 
    cmd="$cmd $all_hosts"
    
    echo "Running: $cmd"
    eval "$cmd"
    if [ $? -ne 0 ]; then
        echo "Failed to generate self-signed certificate for $name!"
        failures=1
    fi

done

# Print success message only if there were no failures
if [ $failures -ne 0 ]; then
    echo "Unable to update all certifictes."
    exit 2
fi

echo "All files are now up-to-date."
