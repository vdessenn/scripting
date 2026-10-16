#!/usr/bin/env bash
#
# build_and_test.sh - Chaine de compilation et de test
#
# Etapes : clean -> configure -> build -> test
#
# Usage :
#   ./build_and_test.sh              # execute toutes les etapes
#   ./build_and_test.sh clean build  # execute seulement les etapes listees
#   ./build_and_test.sh --debug_level DEBUG build  # niveau de log (defaut : INFO)
#   ./build_and_test.sh -h           # affiche l'aide
#

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration (a adapter)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${PROJECT_DIR:-$SCRIPT_DIR}" && pwd)"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 1)}"
DEFAULT_DEBUG_LEVEL="INFO"
DEBUG_LEVEL="$DEFAULT_DEBUG_LEVEL"

ALL_STEPS=(clean configure build test)

# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------
# Niveaux de log (meme ordre que le module logging de Python)
declare -A LEVELS=([DEBUG]=10 [INFO]=20 [WARNING]=30 [ERROR]=40 [CRITICAL]=50)

# log NIVEAU message... : affiche seulement si NIVEAU >= DEBUG_LEVEL
log() {
    local level="$1"; shift
    (( ${LEVELS[$level]} >= ${LEVELS[$DEBUG_LEVEL]} )) || return 0
    printf '[%s] %-7s %s\n' "$(date '+%H:%M:%S')" "$level" "$*"
}
debug() { log DEBUG "$@"; }
info()  { log INFO "$@"; }
warn()  { log WARNING "$@" >&2; }
error() { log ERROR "$@" >&2; }

die() {
    error "$*"
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--debug_level NIVEAU] [etape ...]

Etapes disponibles : ${ALL_STEPS[*]}
Sans etape, toutes les etapes sont executees dans l'ordre.

Options :
  --debug_level NIVEAU  DEBUG, INFO, WARNING, ERROR ou CRITICAL
                        (facultatif, defaut : $DEFAULT_DEBUG_LEVEL)
  -h, --help            Affiche cette aide

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

    # Execution dans le shell courant (pas de sous-shell) pour que les
    # variables exportees par une etape restent visibles pour les suivantes
    "step_$step" > >(tee "$logfile") 2>&1
    wait $! 2>/dev/null || true

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

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --debug_level)
                [[ $# -ge 2 ]] || die "L'option $1 attend une valeur"
                DEBUG_LEVEL="${2^^}"; shift 2 ;;
            --debug_level=*) DEBUG_LEVEL="${1#*=}"; DEBUG_LEVEL="${DEBUG_LEVEL^^}"; shift ;;
            clean|configure|build|test) steps+=("$1"); shift ;;
            *) usage; die "Argument inconnu : $1" ;;
        esac
    done

    # Niveau non fourni -> reste a la valeur par defaut (INFO)
    if [[ -z "${LEVELS[$DEBUG_LEVEL]:-}" ]]; then
        local bad="$DEBUG_LEVEL"
        DEBUG_LEVEL="$DEFAULT_DEBUG_LEVEL"
        die "Niveau de debug invalide : $bad (choix : ${!LEVELS[*]})"
    fi
    debug "Niveau de debug : $DEBUG_LEVEL"

    [[ ${#steps[@]} -eq 0 ]] && steps=("${ALL_STEPS[@]}")

    local global_start=$(date +%s)
    for step in "${steps[@]}"; do
        run_step "$step"
    done
    info "Chaine terminee avec succes en $(( $(date +%s) - global_start ))s"
}

main "$@"
