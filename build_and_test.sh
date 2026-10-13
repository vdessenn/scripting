#!/usr/bin/env bash
#
# build_and_test.sh - Chaine de compilation et de test
#
# Etapes : clean -> configure -> build -> test
#
# Le script est independant du projet : le projet a traiter est le
# repertoire courant, ou celui passe avec -p / PROJECT_DIR.
#
# Usage :
#   cd /chemin/projet && /chemin/build_and_test.sh   # toutes les etapes
#   ./build_and_test.sh -p /chemin/projet            # projet explicite
#   ./build_and_test.sh -p /chemin/projet clean build
#   ./build_and_test.sh -h                           # affiche l'aide
#

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration (a adapter)
# ---------------------------------------------------------------------------
PROJECT_DIR="${PROJECT_DIR:-$PWD}"
LOG_DIR="${LOG_DIR:-}"
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
Usage: $(basename "$0") [-p repertoire_projet] [etape ...]

Etapes disponibles : ${ALL_STEPS[*]}
Sans etape, toutes les etapes sont executees dans l'ordre.

Options :
  -p, --project DIR  Repertoire du projet (prioritaire sur PROJECT_DIR)
  -h, --help         Affiche cette aide

Variables d'environnement :
  PROJECT_DIR  Repertoire du projet (defaut : repertoire courant)
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
            -p|--project)
                [[ $# -ge 2 ]] || die "Option $1 : repertoire manquant"
                PROJECT_DIR="$2"
                shift ;;
            clean|configure|build|test) steps+=("$1") ;;
            *) usage; die "Argument inconnu : $1" ;;
        esac
        shift
    done

    [[ -z "${steps[*]:-}" ]] && steps=("${ALL_STEPS[@]}")

    # Chemins absolus : les etapes changent de repertoire courant
    [[ -d "$PROJECT_DIR" ]] || die "Repertoire projet introuvable : $PROJECT_DIR"
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
    LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
    mkdir -p "$LOG_DIR"
    LOG_DIR="$(cd "$LOG_DIR" && pwd)"
    info "Projet : $PROJECT_DIR"

    local global_start=$(date +%s)
    for step in "${steps[@]}"; do
        run_step "$step"
    done
    info "Chaine terminee avec succes en $(( $(date +%s) - global_start ))s"
}

main "$@"
