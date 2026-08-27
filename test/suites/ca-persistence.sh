#!/usr/bin/env bash
#
# Verifies that the root CA -- and therefore the trust chain of every leaf
# certificate -- survives repeated runs of the container against a single
# mounted directory.
#
# The premise under test is the documented usage: the user bind-mounts one
# directory to /certs, and re-running reuses what is already there rather than
# starting over with a fresh certificate authority.

set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

suite "CA persistence"
require_image

WORKDIR="$(mktemp -d)"
SNAPSHOT="$(mktemp -d)"
cleanup() { reown "$WORKDIR"; rm -rf "$WORKDIR" "$SNAPSHOT"; }
trap cleanup EXIT

cp "$REPO_ROOT/example/config.yml" "$WORKDIR/config.yml"

for run in 1 2; do
    info "Container run $run"
    if ! output="$(run_generator "$WORKDIR" /certs/config.yml)"; then
        fail "container run $run exited non-zero"
        echo "$output" | tail -n 5
        finish "CA persistence"
    fi
    echo "$output" | grep -E "Reusing existing CA|No CA found" | sed 's/^/        /'
    reown "$WORKDIR"
    [ "$run" = 1 ] && cp -a "$WORKDIR/." "$SNAPSHOT/"
done

info "Results"

# 1. The CA the container exports must be identical across runs.
fp1="$(fingerprint "$SNAPSHOT/rootCA.crt")"
fp2="$(fingerprint "$WORKDIR/rootCA.crt")"
if [ -z "$fp1" ] || [ -z "$fp2" ]; then
    fail "rootCA.crt missing or unparseable (run1='$fp1' run2='$fp2')"
elif [ "$fp1" = "$fp2" ]; then
    pass "rootCA.crt is identical across runs"
    detail "$fp1"
else
    fail "rootCA.crt changed between runs"
    detail "run 1: $fp1"
    detail "run 2: $fp2"
fi

# 2. The CA key material must live inside the single mount, or a later run has
#    nothing to reuse.
if [ -f "$WORKDIR/ca/rootCA-key.pem" ]; then
    pass "CA private key persisted inside the mount at ca/rootCA-key.pem"
else
    found="$(find "$WORKDIR" -name 'rootCA-key.pem' -print -quit 2>/dev/null)"
    if [ -n "$found" ]; then
        fail "CA key is at an unexpected path: ${found#"$WORKDIR"/}"
    else
        fail "no rootCA-key.pem inside the mount; the CA cannot be reused"
    fi
fi

# 3. The second run must report reuse rather than generating a new authority.
if echo "$output" | grep -q "Reusing existing CA"; then
    pass "second run reports reusing the existing CA"
else
    fail "second run did not report reusing the existing CA"
fi

# 4. Leaf certificates issued by run 1 must still chain to the CA published by
#    run 2. This is the failure users actually hit: already-deployed
#    certificates stop validating against the newly published CA.
if verify_out="$(openssl verify -CAfile "$WORKDIR/rootCA.crt" "$SNAPSHOT/service1.crt" 2>&1)"; then
    pass "run-1 leaf certificate still verifies against the run-2 CA"
else
    fail "run-1 leaf certificate does NOT verify against the run-2 CA"
    detail "$(echo "$verify_out" | tail -n 1)"
fi

# 5. The issuer named by the leaf certificates must not drift.
iss1="$(openssl x509 -in "$SNAPSHOT/service1.crt" -noout -issuer 2>/dev/null)"
iss2="$(openssl x509 -in "$WORKDIR/service1.crt" -noout -issuer 2>/dev/null)"
if [ -n "$iss1" ] && [ "$iss1" = "$iss2" ]; then
    pass "leaf issuer is stable across runs"
    detail "$iss1"
else
    fail "leaf issuer drifted between runs"
    detail "run 1: $iss1"
    detail "run 2: $iss2"
fi

# 6. The exported trust bundle must contain the persisted CA.
if [ -f "$WORKDIR/ca-certificates.crt" ] && [ -f "$WORKDIR/rootCA.crt" ] && \
   grep -qF "$(sed -n '2p' "$WORKDIR/rootCA.crt")" "$WORKDIR/ca-certificates.crt" 2>/dev/null; then
    pass "ca-certificates.crt bundle contains the current root CA"
else
    fail "ca-certificates.crt bundle does not contain the current root CA"
fi

finish "CA persistence"
