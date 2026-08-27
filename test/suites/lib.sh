# Shared helpers for the cert-generator test suites.
#
# Sourced, not executed. Each suite tracks its own failure count and calls
# finish() to report and set its exit status; run-tests.sh aggregates those.

IMAGE="${IMAGE:-cert-generator:test}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

failures=0
checks=0

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_GREEN=''; C_BOLD=''; C_OFF=''
fi

suite() { printf '\n%s=== %s ===%s\n' "$C_BOLD" "$1" "$C_OFF"; }
info()  { printf '\n%s--> %s%s\n' "$C_BOLD" "$1" "$C_OFF"; }
detail(){ printf '        %s\n' "$1"; }

pass() {
    checks=$((checks + 1))
    printf '  %sPASS%s %s\n' "$C_GREEN" "$C_OFF" "$1"
}

fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$1"
}

require_image() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 || {
        echo "Image '$IMAGE' not found. Build it first:  docker build -t $IMAGE ." >&2
        exit 1
    }
}

# The container runs as root and writes root-owned files into the bind mount.
# Hand ownership back so the host can read them with openssl and delete them.
reown() {
    docker run --rm -v "$1:/certs" --entrypoint chown "$IMAGE" \
        -R "$(id -u):$(id -g)" /certs >/dev/null 2>&1 || true
}

# Run the generator against a mounted directory. Prints combined output;
# returns the container's exit status.
run_generator() {
    local workdir="$1"; shift
    docker run --rm -v "$workdir:/certs" "$IMAGE" "$@" 2>&1
}

# Same, but keeps the streams apart so tests can assert which one a message
# went to. Sets RUN_STDOUT and RUN_STDERR; returns the container's status.
RUN_STDOUT=""
RUN_STDERR=""
run_generator_split() {
    local workdir="$1"; shift
    local errfile status
    errfile="$(mktemp)"
    RUN_STDOUT="$(docker run --rm -v "$workdir:/certs" "$IMAGE" "$@" 2>"$errfile")" \
        && status=0 || status=$?
    RUN_STDERR="$(cat "$errfile")"
    rm -f "$errfile"
    return "$status"
}

# SHA-256 fingerprint of a certificate, via openssl.
fingerprint() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

finish() {
    echo
    if [ "$failures" -eq 0 ]; then
        printf '%s%s: all %d checks passed.%s\n' "$C_GREEN" "$1" "$checks" "$C_OFF"
        exit 0
    fi
    printf '%s%s: %d of %d checks failed.%s\n' "$C_RED" "$1" "$failures" "$checks" "$C_OFF"
    exit 1
}
