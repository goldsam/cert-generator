#!/usr/bin/env bash
#
# Verifies that configuration files are accepted or rejected correctly, that
# each failure mode reports its own distinct exit code, and that schema
# violations are explained rather than swallowed.
#
# Exit codes defined by generate-certs.sh:
#   0  success                     4  malformed YAML/JSON
#   1  wrong number of arguments   5  fails schema validation
#   3  config file not found       7  no certificates defined

set -u
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

suite "Config validation"
require_image

WORKDIR="$(mktemp -d)"
cleanup() { reown "$WORKDIR"; rm -rf "$WORKDIR"; }
trap cleanup EXIT

LAST_OUTPUT=""
LAST_STDOUT=""
LAST_STDERR=""

# assert_exit <description> <expected-status> [args-to-generator...]
assert_exit() {
    local desc="$1" expected="$2"; shift 2
    local status
    run_generator_split "$WORKDIR" "$@" && status=0 || status=$?
    LAST_STDOUT="$RUN_STDOUT"
    LAST_STDERR="$RUN_STDERR"
    LAST_OUTPUT="$RUN_STDOUT
$RUN_STDERR"
    if [ "$status" -eq "$expected" ]; then
        pass "$desc (exit $status)"
    else
        fail "$desc: expected exit $expected, got $status"
        echo "$LAST_OUTPUT" | tail -n 6 | sed "s/^/        /"
    fi
}

# Assert the previous run reported its failure on stderr and left stdout clean.
assert_error_on_stderr() {
    local desc="$1" needle="$2"
    if echo "$LAST_STDERR" | grep -qF "$needle"; then
        pass "$desc is reported on stderr"
    else
        fail "$desc is not on stderr"
        detail "stderr: $(echo "$LAST_STDERR" | head -n 1)"
    fi
    if echo "$LAST_STDOUT" | grep -qF "$needle"; then
        fail "$desc also leaked to stdout"
        detail "stdout: $(echo "$LAST_STDOUT" | grep -F "$needle" | head -n 1)"
    else
        pass "$desc does not leak to stdout"
    fi
}

write_config() { printf '%s' "$2" > "$WORKDIR/$1"; }

info "Accepted configurations"

cp "$REPO_ROOT/example/config.yml" "$WORKDIR/valid.yml"
assert_exit "the example YAML configuration is accepted" 0 /certs/valid.yml

write_config valid.json '{
  "additional-hosts": ["localhost", "127.0.0.1"],
  "certs": [{"name": "json-service", "hosts": ["json.example.com"]}]
}'
assert_exit "an equivalent JSON configuration is accepted" 0 /certs/valid.json

if [ -f "$WORKDIR/json-service.crt" ]; then
    pass "the JSON configuration actually produced a certificate"
else
    fail "the JSON configuration produced no json-service.crt"
fi

info "Invocation and file errors"

assert_exit "too many arguments is rejected" 1 /certs/valid.yml extra-argument
assert_error_on_stderr "the usage message" "Usage:"

assert_exit "a nonexistent configuration file is rejected" 3 /certs/does-not-exist.yml
assert_error_on_stderr "the missing-file error" "not found"

write_config malformed.yml 'certs: [ { name: "unterminated
  - this is not valid yaml
'
assert_exit "malformed YAML is rejected" 4 /certs/malformed.yml
assert_error_on_stderr "the malformed-input error" "malformed JSON or YAML"

info "Schema violations"

write_config missing-name.yml 'certs:
  - hosts:
      - example.com
'
assert_exit "a cert entry without the required name is rejected" 5 /certs/missing-name.yml

assert_error_on_stderr "the schema validation error" "Error: Configuration file is invalid:"

# The error detail must survive the leading-line stripping in generate-certs.sh.
if echo "$LAST_STDERR" | grep -q "Error: Configuration file is invalid:"; then
    body="$(echo "$LAST_STDERR" | sed -n '/Error: Configuration file is invalid:/,$p' | tail -n +2)"
    if [ -n "$(echo "$body" | tr -d '[:space:]')" ]; then
        pass "the validation error explains the problem"
        detail "$(echo "$body" | grep -v '^\s*$' | head -n 1 | sed 's/^ *//')"
    else
        fail "the validation error was reported with no explanation"
    fi
else
    fail "no 'Configuration file is invalid' header in the output"
fi

if echo "$LAST_STDERR" | grep -qi "name"; then
    pass "the validation error names the offending property"
else
    fail "the validation error does not mention the offending property"
    echo "$LAST_OUTPUT" | tail -n 6 | sed 's/^/        /'
fi

write_config unknown-cert-key.yml 'certs:
  - name: service1
    notaproperty: true
'
assert_exit "an unknown property on a cert entry is rejected" 5 /certs/unknown-cert-key.yml

write_config unknown-top-key.yml 'certs:
  - name: service1
unexpected-top-level: true
'
assert_exit "an unknown top-level property is rejected" 5 /certs/unknown-top-key.yml

write_config wrong-type.yml 'certs:
  - name: service1
    client: "yes"
'
assert_exit "a non-boolean client flag is rejected" 5 /certs/wrong-type.yml

write_config empty-hosts.yml 'certs:
  - name: service1
    hosts: []
'
assert_exit "an empty hosts array is rejected (minItems)" 5 /certs/empty-hosts.yml

write_config no-certs-key.yml 'additional-hosts:
  - localhost
'
assert_exit "a config without the required certs property is rejected" 5 /certs/no-certs-key.yml

info "Schema-valid but unusable"

write_config empty-certs.yml 'certs: []
'
assert_exit "an empty certs array is reported as nothing to do" 7 /certs/empty-certs.yml

info "No invalid configuration exits zero"

# Degenerate inputs that are not obviously covered by the cases above. None of
# them describes a usable set of certificates, so none may exit 0.
write_config edge-empty.yml ''
write_config edge-comment-only.yml '# nothing but a comment
'
write_config edge-null.yml 'null
'
write_config edge-toplevel-list.yml '- a
- b
'
write_config edge-toplevel-scalar.yml 'just a bare string
'
write_config edge-multidoc.yml 'certs:
  - name: a
---
certs:
  - name: b
'
write_config edge-json-garbage.json '{"certs":[{"name":"x"}]} trailing garbage
'
write_config edge-certs-not-array.yml 'certs: "not an array"
'
write_config edge-cert-item-scalar.yml 'certs:
  - a string, not an object
'
write_config edge-name-not-string.yml 'certs:
  - name: 12345
'
mkdir -p "$WORKDIR/edge-a-directory"

for edge_case in edge-empty.yml edge-comment-only.yml edge-null.yml \
                 edge-toplevel-list.yml edge-toplevel-scalar.yml edge-multidoc.yml \
                 edge-json-garbage.json edge-certs-not-array.yml \
                 edge-cert-item-scalar.yml edge-name-not-string.yml \
                 edge-a-directory; do
    if run_generator_split "$WORKDIR" "/certs/$edge_case" >/dev/null 2>&1; then
        edge_status=0
    else
        edge_status=$?
    fi
    if [ "$edge_status" -ne 0 ]; then
        pass "$edge_case is rejected (exit $edge_status)"
    else
        fail "$edge_case was ACCEPTED with exit 0"
    fi
    if [ -z "$(echo "$RUN_STDERR" | tr -d '[:space:]')" ]; then
        fail "$edge_case was rejected without any message on stderr"
    fi
done

finish "Config validation"
