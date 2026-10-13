#!/usr/bin/env bash
#
# build_and_test.sh - Chaine de compilation et de test
#
# Etapes : clean -> configure -> build -> test
#
# Usage :
#   ./build_and_test.sh              # execute toutes les etapes
#   ./build_and_test.sh clean build  # execute seulement les etapes listees
#   ./build_and_test.sh -h           # affiche l'aide
#

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration (a adapter)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$SCRIPT_DIR}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"

ALL_STEPS=(clean configure build test)

# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------
log()   { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
info()  { log "INFO  $*"; }
error() { log "ERROR $*" >&2; }

die() {
    error "$*"
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [etape ...]

Etapes disponibles : ${ALL_STEPS[*]}
Sans argument, toutes les etapes sont executees dans l'ordre.

Variables d'environnement :
  PROJECT_DIR  Repertoire du projet (defaut : $SCRIPT_DIR)
  LOG_DIR      Repertoire des logs  (defaut : \$PROJECT_DIR/logs)
  JOBS         Nombre de jobs make  (defaut : nombre de CPU)
EOF
}

on_error() {
    error "Echec a la ligne $1 (code $2)"
}
trap 'on_error $LINENO $?' ERR

# Execute une etape en journalisant sa sortie et sa duree
run_step() {
    local step="$1"
    local logfile="$LOG_DIR/$step.log"
    local start end

    info "=== Debut etape : $step ==="
    start=$(date +%s)

    "step_$step" 2>&1 | tee "$logfile"

    end=$(date +%s)
    info "=== Fin etape : $step ($((end - start))s) ==="
}

# ---------------------------------------------------------------------------
# Etapes (a remplir avec vos commandes make ...)
# ---------------------------------------------------------------------------
step_clean() {
    cd "$PROJECT_DIR"
    # TODO : commandes de nettoyage
    # make clean
    :
}

step_configure() {
    cd "$PROJECT_DIR"
    # TODO : commandes de configuration
    # make config
    :
}

step_build() {
    cd "$PROJECT_DIR"
    # TODO : commandes de compilation
    # make -j"$JOBS" all
    :
}

step_test() {
    cd "$PROJECT_DIR"
    # TODO : commandes d'execution des tests
    # make test
    :
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local steps=()

    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; exit 0 ;;
            clean|configure|build|test) steps+=("$arg") ;;
            *) usage; die "Etape inconnue : $arg" ;;
        esac
    done

    [[ ${#steps[@]} -eq 0 ]] && steps=("${ALL_STEPS[@]}")

    mkdir -p "$LOG_DIR"

    local global_start=$(date +%s)
    for step in "${steps[@]}"; do
        run_step "$step"
    done
    info "Chaine terminee avec succes en $(( $(date +%s) - global_start ))s"
}

main "$@"
