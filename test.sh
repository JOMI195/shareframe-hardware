#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM="$ROOT/tests/system/sim.sh"
BOARD="${SHAREFRAME_BOARD_DIR:-$(cd "$ROOT/.." && pwd)/shareframe-board}"
IMAGE=shareframe-hardware-test
REPORTS="$ROOT/build/test-reports"

usage() {
    cat <<'USAGE'
Usage: ./test.sh <command> [--keep] [extra args]

  lint          shellcheck over every script (busybox ash for the image, bash for the tooling)
  unit          lint + one .bats per script under busybox ash, in tests/docker
  contract      formats shared with shareframe-board: goldens this repo produces, and the
                board's goldens fed to these scripts (needs ../shareframe-board)
  contract --update-golden   rewrite this repo's goldens from what the scripts produce now
  build         release and provisioning tools, the s6-rc graph, kernel patches (--strict: no skips)
  all           lint, unit, contract, build
  everything    all, then ../shareframe-board/test.sh all, then system; a summary at the end
  shell         a shell in the test container, repo at /src (read-only)
  system        real image under QEMU: up → tests/system/specs → down
  system <cmd>  any tests/system/sim.sh command (build, up, down, check, wifi ..., see sim.sh help)

  --keep        system: leave the simulator running afterwards
  extra args    forwarded to bats or Playwright,
                e.g. ./test.sh unit -f commit   ./test.sh system --grep rollback
USAGE
}

cmd="${1:-}"
[[ -n "$cmd" && "$cmd" != "-h" && "$cmd" != "--help" ]] || { usage; exit 0; }
shift

keep=0
args=()
for a in "$@"; do
    case "$a" in
        --keep) keep=1 ;;
        *) args+=("$a") ;;
    esac
done

# The repo is mounted read-only: a test that writes outside its temp dir fails.
in_container() { # [docker args] -- <command>
    docker build -q -f "$ROOT/tests/docker/Dockerfile" -t "$IMAGE" "$ROOT/br2-external/configs" >/dev/null
    local extra=()
    while [[ "$1" != -- ]]; do extra+=("$1"); shift; done
    shift
    local tty=()
    [[ -t 0 && -t 1 ]] && tty=(-it)
    docker run --rm "${tty[@]}" -u "$(id -u):$(id -g)" -v "$ROOT:/src:ro" "${extra[@]}" "$IMAGE" "$@"
}

# Scripts for the image are checked as busybox ash; build and release tooling as bash.
lint_targets() {
    cd "$ROOT"
    grep -rlE '^#!(/bin/sh|/usr/bin/env sh)' br2-external/overlay br2-external/package configs/sim/overlay 2>/dev/null \
        | sed 's/^/sh /'
    { ls automation.sh test.sh scripts/*.sh tests/system/sim.sh br2-external/board/*/*.sh; } 2>/dev/null \
        | sed 's/^/bash /'
}

run_lint() {
    local sh=() bash=() shell file
    while read -r shell file; do
        if [[ $shell == sh ]]; then sh+=("$file"); else bash+=("$file"); fi
    done < <(lint_targets)
    in_container -- shellcheck -x -s busybox -S warning "${sh[@]}" &&
        in_container -- shellcheck -x -s bash -S warning "${bash[@]}"
}

run_unit() {
    rm -rf "$REPORTS/unit" && mkdir -p "$REPORTS/unit"
    in_container -v "$REPORTS/unit:/reports" -- \
        bats -r --report-formatter junit --output /reports "${args[@]}" tests/unit
}

run_contract() {
    [[ -d "$BOARD/tests/contract/golden" ]] || {
        echo "shareframe-board not found at $BOARD (set SHAREFRAME_BOARD_DIR)" >&2; return 2; }
    local update=() rest=()
    for a in "${args[@]}"; do
        if [[ "$a" == --update-golden ]]; then update=(-e UPDATE_GOLDEN=1 -v "$ROOT/tests/contract/golden:/golden"); else rest+=("$a"); fi
    done
    rm -rf "$REPORTS/contract" && mkdir -p "$REPORTS/contract"
    in_container -v "$REPORTS/contract:/reports" -v "$BOARD:/board:ro" -e BOARD=/board "${update[@]}" -- \
        bats -r --filter-tags contract --report-formatter junit --output /reports "${rest[@]}" tests/unit tests/contract
}

run_build() {
    local strict=() rest=()
    for a in "${args[@]}"; do
        if [[ "$a" == --strict ]]; then strict=(-e STRICT=1); else rest+=("$a"); fi
    done
    rm -rf "$REPORTS/build" && mkdir -p "$REPORTS/build"
    in_container -v "$REPORTS/build:/reports" "${strict[@]}" -- \
        bats -r --report-formatter junit --output /reports "${rest[@]}" tests/build
}

# Every stage runs even after a failure; the exit code says whether any failed.
run_everything() {
    local stage status=0 results=()
    args=()
    for stage in "lint" "unit" "contract" "build" "board" "system"; do
        local rc=0
        case "$stage" in
            lint) run_lint || rc=$? ;;
            unit) run_unit || rc=$? ;;
            contract) run_contract || rc=$? ;;
            build) run_build || rc=$? ;;
            board) "$BOARD/test.sh" all || rc=$? ;;
            system) run_system || rc=$? ;;
        esac
        results+=("$(printf '%-9s %s' "$stage" "$([[ $rc == 0 ]] && echo ok || echo "FAILED ($rc)")")")
        (( rc == 0 )) || status=1
    done
    printf '\n== everything\n'
    printf '%s\n' "${results[@]}"
    return $status
}

run_system() {
    local status=0 started=0
    if ! "$SIM" status 2>/dev/null | grep -q '^== board'; then
        "$SIM" up
        started=1
    fi
    "$SIM" test "${args[@]}" || status=$?
    if (( keep )) || (( ! started )); then
        echo "Simulator left running. Stop it with: tests/system/sim.sh down"
    else
        "$SIM" down
    fi
    return $status
}

case "$cmd" in
    lint) run_lint ;;
    unit) run_lint && run_unit ;;
    contract) run_contract ;;
    build) run_build ;;
    all) run_lint && run_unit && run_contract && run_build ;;
    everything) run_everything ;;
    shell) in_container -- bash ;;
    system)
        if [[ ${#args[@]} -gt 0 && "${args[0]}" != -* ]]; then
            exec "$SIM" "${args[@]}"
        fi
        run_system
        ;;
    *) usage; exit 2 ;;
esac
