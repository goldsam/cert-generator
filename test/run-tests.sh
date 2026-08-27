#!/usr/bin/env bash
#
# Single entry point for the cert-generator test suites.
#
# Usage:
#   docker build -t cert-generator:test .
#   test/run-tests.sh [image-tag]
#
# Runs every suite against the given image and reports an aggregate result.
# Exits non-zero if any suite fails.

set -u

export IMAGE="${1:-${IMAGE:-cert-generator:test}}"
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/suites" && pwd)"

# shellcheck source=suites/lib.sh
. "$SUITE_DIR/lib.sh"

SUITES=(
    config-validation.sh
    ca-persistence.sh
)

require_image

printf '%sRunning cert-generator test suites against image %s%s\n' "$C_BOLD" "$IMAGE" "$C_OFF"

declare -a FAILED=()
for suite_script in "${SUITES[@]}"; do
    if ! "$SUITE_DIR/$suite_script"; then
        FAILED+=("$suite_script")
    fi
done

echo
printf '%s=== Summary ===%s\n' "$C_BOLD" "$C_OFF"
for suite_script in "${SUITES[@]}"; do
    if printf '%s\n' "${FAILED[@]+"${FAILED[@]}"}" | grep -qx "$suite_script"; then
        printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$suite_script"
    else
        printf '  %sPASS%s %s\n' "$C_GREEN" "$C_OFF" "$suite_script"
    fi
done

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
    printf '%sAll %d suites passed.%s\n' "$C_GREEN" "${#SUITES[@]}" "$C_OFF"
    exit 0
fi
printf '%s%d of %d suites failed.%s\n' "$C_RED" "${#FAILED[@]}" "${#SUITES[@]}" "$C_OFF"
exit 1
