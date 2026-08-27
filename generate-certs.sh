#!/bin/sh

# Ensure a configuration file is provided.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 config.yaml|config.json" >&2
    exit 1
fi

CONFIG_FILE="$1"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file '$CONFIG_FILE' not found." >&2
    exit 3
fi

# Convert the configuration file to JSON to use jsonschema for validation.
CONFIG_JSON=$(mktemp)
trap 'rm -f "$CONFIG_JSON"' EXIT
if ! yq eval -o=json "." "$CONFIG_FILE" > "$CONFIG_JSON"; then
    echo "Error: Configuration file contains malformed JSON or YAML." >&2
    exit 4
fi

# Validate configuration against the schema.
validation_output=$(jsonschema validate /config.schema.json "$CONFIG_JSON" 2>&1)
validation_exit_code=$?
if [ $validation_exit_code -ne 0 ]; then
    echo "Error: Configuration file is invalid:" >&2
    # strip the first line of the output which contains the meaningless temp file name.
    echo "$validation_output" | tail -n +2 >&2
    exit 5
fi

# Determine the mkcert CA directory.
#
# Left to itself, mkcert puts CAROOT under $HOME, which lives in the
# container's ephemeral filesystem. Only the working directory is bind-mounted,
# so the CA key material would be discarded when the container exits and every
# run would mint a brand-new root CA -- silently invalidating every previously
# issued certificate. Anchor CAROOT inside the working directory instead so the
# CA survives across runs. An explicit CAROOT in the environment still wins.
CAROOT="${CAROOT:-$(pwd)/ca}"
export CAROOT
mkdir -p "$CAROOT"

ca_root=$(mkcert -CAROOT)
ca_cert_pem="${ca_root}/rootCA.pem"
ca_key_pem="${ca_root}/rootCA-key.pem"

if [ -f "$ca_cert_pem" ] && [ -f "$ca_key_pem" ]; then
    echo "Reusing existing CA in ${ca_root}."
elif [ -f "$ca_cert_pem" ]; then
    echo "Error: ${ca_cert_pem} exists but ${ca_key_pem} is missing; the CA cannot sign." >&2
    exit 6
else
    echo "No CA found in ${ca_root}. A new one will be generated."
fi

# mkcert -install only creates a CA when CAROOT has none, so this is a no-op
# for the key material on subsequent runs. It still has to run every time to
# add the CA to *this* container's trust store, which is what the
# update-ca-certificates bundle below exports.
if ! mkcert -install; then
    echo "Error: 'mkcert -install' failed." >&2
    exit 6
fi

# Verify the CA certificate now exists.
if [ -f "$ca_cert_pem" ]; then
  cp "$ca_cert_pem" ./rootCA.crt
  echo "CA certificate copied to ./rootCA.crt"
else
  echo "Error: CA certificate still not found in ${ca_root} after mkcert -install" >&2
  exit 6
fi

# Extract additional hosts (if any) as a space-separated list.
#
# Every extraction below forces -o=yaml. yq's default output format is "auto",
# which mirrors the input format, so reading a JSON config would yield
# JSON-quoted scalars: a name would come back as "svc" (quotes included) and a
# joined host list as a single quoted string. Both are documented as supported
# input formats, so pin the output format instead of letting it vary.
additional_hosts=$(yq e -o=yaml '.["additional-hosts"] // [] | join(" ")' "$CONFIG_FILE")

# Get the number of certificate configurations.
cert_count=$(yq e -o=yaml '.certs | length' "$CONFIG_FILE")

if [ "$cert_count" -eq 0 ]; then
    echo "No certificates defined in configuration." >&2
    exit 7
fi

# Track failures
failures=0

# Process each certificate configuration.
for i in $(seq 0 $((cert_count - 1))); do
    name=$(yq e -o=yaml ".certs[$i].name" "$CONFIG_FILE")
    # Default to false if the client property is not provided.
    client=$(yq e -o=yaml ".certs[$i].client // false" "$CONFIG_FILE")
    pfx=$(yq e -o=yaml ".certs[$i].pfx // false" "$CONFIG_FILE")
    # Extract the required hosts list and join into a space-separated string.
    cert_hosts=$(yq e -o=yaml ".certs[$i].hosts // [] | join(\" \")" "$CONFIG_FILE" 2>/dev/null || echo "")

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
    
    if ! eval "$cmd"; then
        echo "Failed to generate self-signed certificate for $name!" >&2
        failures=1
    elif [ "$pfx" != "true" ]; then
        chmod 644 "${name}.key"
    fi

done

# Print success message only if there were no failures
if [ $failures -ne 0 ]; then
    echo "Unable to update all certifictes." >&2
    exit 2
fi

echo "Updating CA certificates bundle..."
update-ca-certificates
cp /etc/ssl/certs/ca-certificates.crt ./ca-certificates.crt

echo "All files are now up-to-date."
