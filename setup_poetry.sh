#!/usr/bin/env bash
#
# setup_poetry.sh - Mise en place de Poetry sur un projet existant
#
# Etapes : init -> config -> source -> credentials -> deps -> devtools -> install
#
#   init         Cree le pyproject.toml (poetry init) s'il n'existe pas encore
#   config       virtualenvs.in-project = true (poetry.toml), certificat
#                Artifactory non verifie, nouvel installeur desactive
#   source       Ajoute la source Artifactory ([[tool.poetry.source]])
#   credentials  Identifiants Artifactory (JFrog CLI ou navigateur + saisie)
#   deps         Propose PyQt5 (+ LD_LIBRARY_PATH) et dataclasses (Python 3.6)
#   devtools     Outils de dev (pre-commit, ...) dans le groupe dev
#   install      poetry install --no-root
#
# Usage :
#   ./setup_poetry.sh                    # execute toutes les etapes
#   ./setup_poetry.sh source credentials # execute seulement les etapes listees
#   ./setup_poetry.sh -y                 # mode non interactif (valeurs par defaut)
#   ./setup_poetry.sh -h                 # affiche l'aide
#

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration (a adapter ou a surcharger par variables d'environnement)
# ---------------------------------------------------------------------------
PROJECT_DIR="$(cd "${PROJECT_DIR:-$PWD}" && pwd)"

ARTIFACTORY_URL="${ARTIFACTORY_URL:-https://artifactory.example.com}"
ARTIFACTORY_REPO="${ARTIFACTORY_REPO:-pypi-remote}"
SOURCE_NAME="${SOURCE_NAME:-artifactory}"
SOURCE_URL="${SOURCE_URL:-}"            # defaut : deduit de l'URL et du depot
ARTIFACTORY_USER="${ARTIFACTORY_USER:-}"
ARTIFACTORY_TOKEN="${ARTIFACTORY_TOKEN:-}"
JF_SERVER_ID="${JF_SERVER_ID:-$SOURCE_NAME}"

PYTHON_BIN="${PYTHON_BIN:-}"            # interpreteur du virtualenv (ex : python3.6)
PYTHON_CONSTRAINT="${PYTHON_CONSTRAINT:-}"
CERT_VERIFY="${CERT_VERIFY:-false}"     # certificates.<source>.cert
NEW_INSTALLER="${NEW_INSTALLER:-false}" # Poetry < 2.0 uniquement

INSTALL_PYQT5="${INSTALL_PYQT5:-}"      # yes / no (vide : question)
INSTALL_DATACLASSES="${INSTALL_DATACLASSES:-}"
PYQT5_QT5_VERSION="${PYQT5_QT5_VERSION:-5.15.2}" # derniere version avec wheels Linux
DEV_TOOLS="${DEV_TOOLS:-pre-commit}"

ASSUME_YES="${ASSUME_YES:-0}"

ALL_STEPS=(init config source credentials deps devtools install)

# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------
log()   { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
info()  { log "INFO  $*"; }
warn()  { log "WARN  $*" >&2; }
error() { log "ERROR $*" >&2; }

die() {
    error "$*"
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [-y] [etape ...]

Etapes disponibles : ${ALL_STEPS[*]}
Sans argument, toutes les etapes sont executees dans l'ordre.

Options :
  -y, --yes    Mode non interactif : les questions prennent leur valeur par defaut
  -h, --help   Affiche cette aide

Variables d'environnement :
  PROJECT_DIR          Repertoire du projet Python    (defaut : repertoire courant)
  ARTIFACTORY_URL      URL de la plateforme JFrog     (defaut : $ARTIFACTORY_URL)
  ARTIFACTORY_REPO     Depot PyPI Artifactory         (defaut : $ARTIFACTORY_REPO)
  SOURCE_NAME          Nom de la source Poetry        (defaut : $SOURCE_NAME)
  SOURCE_URL           URL complete de l'index        (defaut : deduite)
  ARTIFACTORY_USER     Identifiant Artifactory        (defaut : question)
  ARTIFACTORY_TOKEN    Cle API / jeton Artifactory    (defaut : question)
  JF_SERVER_ID         Server ID JFrog CLI            (defaut : \$SOURCE_NAME)
  PYTHON_BIN           Interpreteur du virtualenv     (defaut : celui de Poetry)
  PYTHON_CONSTRAINT    Contrainte Python du projet    (defaut : >=X.Y detecte)
  CERT_VERIFY          Verification du certificat     (defaut : $CERT_VERIFY)
  NEW_INSTALLER        Nouvel installeur Poetry < 2.0 (defaut : $NEW_INSTALLER)
  INSTALL_PYQT5        yes/no                         (defaut : question)
  INSTALL_DATACLASSES  yes/no                         (defaut : question)
  PYQT5_QT5_VERSION    Version epinglee de PyQt5-Qt5  (defaut : $PYQT5_QT5_VERSION)
  DEV_TOOLS            Outils du groupe dev           (defaut : $DEV_TOOLS)
EOF
}

on_error() {
    error "Echec a la ligne $1 (code $2)"
}
trap 'on_error $LINENO $?' ERR

is_interactive() {
    [[ "$ASSUME_YES" != 1 && -t 0 ]]
}

# ask <variable> <question> [defaut] : lit une valeur, garde le defaut sinon
ask() {
    local __var="$1" question="$2" default="${3:-}" answer=""
    if is_interactive; then
        read -r -p "$question${default:+ [$default]} : " answer || true
    fi
    printf -v "$__var" '%s' "${answer:-$default}"
}

# ask_secret <variable> <question> : saisie masquee
ask_secret() {
    local __var="$1" question="$2" answer=""
    is_interactive || die "Saisie de '$question' impossible en mode non interactif"
    read -r -s -p "$question : " answer || true
    echo
    printf -v "$__var" '%s' "$answer"
}

# confirm <question> [y|n] : retourne 0 si oui
confirm() {
    local question="$1" default="${2:-n}" answer=""
    if is_interactive; then
        local hint="[y/N]"
        [[ "$default" == y ]] && hint="[Y/n]"
        read -r -p "$question $hint " answer || true
    fi
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[yYoO] ]]
}

# yes_no <valeur> <question> <defaut> : valeur imposee (yes/no) ou question
yes_no() {
    case "${1,,}" in
        y|yes|o|oui|1|true) return 0 ;;
        n|no|non|0|false)   return 1 ;;
        *) confirm "$2" "$3" ;;
    esac
}

open_url() {
    local url="$1" opener=""
    info "Ouvrir : $url"
    for cmd in xdg-open open wslview; do
        command -v "$cmd" >/dev/null 2>&1 && { opener="$cmd"; break; }
    done
    if [[ -n "$opener" ]] && is_interactive && confirm "Ouvrir dans le navigateur ?" y; then
        "$opener" "$url" >/dev/null 2>&1 &
    fi
}

# version_ge <version> <minimum>
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

poetry_version() {
    poetry --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1
}

has_pyproject() {
    [[ -f "$PROJECT_DIR/pyproject.toml" ]]
}

require_pyproject() {
    has_pyproject || die "Pas de pyproject.toml dans $PROJECT_DIR (lancer l'etape init)"
}

# Groupe dev : --group dev (Poetry >= 1.2) ou --dev (Poetry 1.1)
dev_group_args() {
    if version_ge "$POETRY_VERSION" 1.2; then
        echo "--group dev"
    else
        echo "--dev"
    fi
}

run_step() {
    local step="$1"
    info "=== Debut etape : $step ==="
    cd "$PROJECT_DIR"
    "step_$step"
    info "=== Fin etape : $step ==="
}

# ---------------------------------------------------------------------------
# Etapes
# ---------------------------------------------------------------------------
step_init() {
    if has_pyproject; then
        info "pyproject.toml deja present, initialisation ignoree"
        return
    fi

    local name default_python python_constraint
    name="$(basename "$PROJECT_DIR" | tr '[:upper:]_ ' '[:lower:]--')"
    default_python="$("${PYTHON_BIN:-python3}" -c 'import sys; print(">=%d.%d" % sys.version_info[:2])')"

    ask name "Nom du projet" "$name"
    ask python_constraint "Contrainte de version Python" "${PYTHON_CONSTRAINT:-$default_python}"
    PYTHON_CONSTRAINT="$python_constraint"

    info "Initialisation du projet '$name' (python $PYTHON_CONSTRAINT)"
    poetry init --no-interaction --name "$name" --python "$PYTHON_CONSTRAINT"

    # Le depot n'est pas forcement un paquet Python : pas d'installation du projet lui-meme
    if version_ge "$POETRY_VERSION" 1.8 && ! grep -q '^package-mode' pyproject.toml; then
        if grep -q '^\[tool\.poetry\]' pyproject.toml; then
            sed -i '/^\[tool\.poetry\]/a package-mode = false' pyproject.toml
        else
            printf '\n[tool.poetry]\npackage-mode = false\n' >> pyproject.toml
        fi
    fi
}

step_config() {
    require_pyproject

    info "virtualenvs.in-project = true (poetry.toml)"
    poetry config --local virtualenvs.in-project true

    info "certificates.$SOURCE_NAME.cert = $CERT_VERIFY"
    poetry config "certificates.$SOURCE_NAME.cert" "$CERT_VERIFY"

    if version_ge "$POETRY_VERSION" 2.0; then
        info "Poetry $POETRY_VERSION : plus d'option pour l'ancien installeur, ignore"
    elif version_ge "$POETRY_VERSION" 1.4; then
        info "installer.modern-installation = $NEW_INSTALLER"
        poetry config installer.modern-installation "$NEW_INSTALLER"
    else
        info "experimental.new-installer = $NEW_INSTALLER"
        poetry config experimental.new-installer "$NEW_INSTALLER"
    fi

    if [[ -n "$PYTHON_BIN" ]]; then
        info "Virtualenv base sur $PYTHON_BIN"
        poetry env use "$PYTHON_BIN"
    fi

    local gitignore="$PROJECT_DIR/.gitignore"
    if ! grep -qsxE '/?\.venv/?' "$gitignore"; then
        info "Ajout de .venv/ a $gitignore"
        echo ".venv/" >> "$gitignore"
    fi
}

step_source() {
    require_pyproject

    if grep -qE "^name = \"$SOURCE_NAME\"" pyproject.toml; then
        info "Source '$SOURCE_NAME' deja definie dans pyproject.toml"
        return
    fi

    info "Ajout de la source '$SOURCE_NAME' : $SOURCE_URL"
    if version_ge "$POETRY_VERSION" 1.5; then
        poetry source add --priority=primary "$SOURCE_NAME" "$SOURCE_URL"
    elif version_ge "$POETRY_VERSION" 1.2; then
        poetry source add --default "$SOURCE_NAME" "$SOURCE_URL"
    else
        # Poetry 1.1 : pas de commande 'source', ecriture directe
        cat >> pyproject.toml <<EOF

[[tool.poetry.source]]
name = "$SOURCE_NAME"
url = "$SOURCE_URL"
default = true
EOF
    fi
}

# Recupere un jeton via la JFrog CLI (configuration du serveur si besoin)
credentials_via_jf() {
    if ! jf config show "$JF_SERVER_ID" >/dev/null 2>&1; then
        info "Configuration du serveur JFrog '$JF_SERVER_ID' (choisir 'Web Login' si propose)"
        jf config add "$JF_SERVER_ID" --url="$ARTIFACTORY_URL" --interactive=true
    fi

    info "Creation d'un jeton d'acces Artifactory via la JFrog CLI"
    local json
    json="$(jf access-token-create --server-id="$JF_SERVER_ID")" || return 1
    ARTIFACTORY_TOKEN="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["access_token"])' <<< "$json")" || return 1
}

# Renvoie vers l'interface web pour se connecter et recuperer la cle API
credentials_via_browser() {
    info "1. Se connecter a Artifactory"
    open_url "$ARTIFACTORY_URL/ui/login/"
    info "2. Recuperer la cle API / generer un Identity Token (Edit Profile)"
    open_url "$ARTIFACTORY_URL/ui/user_profile"
    info "   ou via 'Set Me Up' du depot $ARTIFACTORY_REPO :"
    info "   $ARTIFACTORY_URL/ui/repos/tree/General/$ARTIFACTORY_REPO"
    ask_secret ARTIFACTORY_TOKEN "Cle API / jeton Artifactory"
}

step_credentials() {
    local curl_opts=(-fsS -o /dev/null)
    [[ "$CERT_VERIFY" == false ]] && curl_opts+=(-k)

    if [[ -z "$ARTIFACTORY_TOKEN" ]]; then
        if ! is_interactive; then
            warn "ARTIFACTORY_TOKEN non defini en mode non interactif, etape ignoree"
            return
        fi
        if ! confirm "Configurer les identifiants Artifactory pour '$SOURCE_NAME' ?" y; then
            return
        fi
    fi

    [[ -n "$ARTIFACTORY_USER" ]] || ask ARTIFACTORY_USER "Identifiant Artifactory" "${USER:-}"

    if [[ -z "$ARTIFACTORY_TOKEN" ]]; then
        if command -v jf >/dev/null 2>&1 && confirm "JFrog CLI detectee, l'utiliser pour generer un jeton ?" y; then
            credentials_via_jf || warn "Echec de la JFrog CLI, passage par le navigateur"
        fi
        [[ -n "$ARTIFACTORY_TOKEN" ]] || credentials_via_browser
    fi
    [[ -n "$ARTIFACTORY_TOKEN" ]] || die "Aucun jeton saisi"

    info "Enregistrement des identifiants (http-basic.$SOURCE_NAME)"
    poetry config "http-basic.$SOURCE_NAME" "$ARTIFACTORY_USER" "$ARTIFACTORY_TOKEN"

    if command -v curl >/dev/null 2>&1; then
        if curl "${curl_opts[@]}" -u "$ARTIFACTORY_USER:$ARTIFACTORY_TOKEN" "${SOURCE_URL%/}/"; then
            info "Connexion a $SOURCE_URL reussie"
        else
            warn "Impossible d'acceder a $SOURCE_URL avec ces identifiants"
        fi
    fi
}

# Ajoute a l'activate du virtualenv l'export de LD_LIBRARY_PATH vers les libs Qt5
setup_pyqt5_env() {
    local activate="$PROJECT_DIR/.venv/bin/activate"
    local marker="# >>> setup_poetry PyQt5 >>>"

    if [[ ! -f "$activate" ]]; then
        warn "$activate introuvable, a ajouter manuellement :"
        warn "  export LD_LIBRARY_PATH=\"\$(python3 -c \"import PyQt5, os; print(os.path.join(os.path.dirname(PyQt5.__file__), 'Qt5', 'lib'))\"):\$LD_LIBRARY_PATH\""
        return
    fi
    grep -qF "$marker" "$activate" && return

    info "Ajout de LD_LIBRARY_PATH (libs Qt5) a $activate"
    cat >> "$activate" <<'EOF'

# >>> setup_poetry PyQt5 >>>
_pyqt5_lib="$(python -c "import PyQt5, os; print(os.path.join(os.path.dirname(PyQt5.__file__), 'Qt5', 'lib'))" 2>/dev/null)"
if [ -n "$_pyqt5_lib" ]; then
    export LD_LIBRARY_PATH="$_pyqt5_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
unset _pyqt5_lib
# <<< setup_poetry PyQt5 <<<
EOF
}

step_deps() {
    require_pyproject

    if yes_no "$INSTALL_PYQT5" "Installer PyQt5 ?" n; then
        info "Ajout de PyQt5 (PyQt5-Qt5 epingle en $PYQT5_QT5_VERSION)"
        poetry add PyQt5 "PyQt5-Qt5==$PYQT5_QT5_VERSION"
        setup_pyqt5_env
    fi

    if yes_no "$INSTALL_DATACLASSES" "Installer dataclasses (backport Python 3.6) ?" n; then
        info "Ajout de dataclasses pour Python < 3.7"
        poetry add dataclasses --python "<3.7"
    fi
}

step_devtools() {
    require_pyproject

    local tools extra
    read -r -a tools <<< "$DEV_TOOLS"
    ask extra "Outils de dev supplementaires (ex : pytest black flake8)" ""
    [[ -n "$extra" ]] && read -r -a tools <<< "${tools[*]} $extra"

    if [[ ${#tools[@]} -gt 0 ]]; then
        info "Ajout au groupe dev : ${tools[*]}"
        # shellcheck disable=SC2046
        poetry add $(dev_group_args) "${tools[@]}"
    fi

    [[ " ${tools[*]} " == *" pre-commit "* ]] || return 0

    local git_root
    if ! git_root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
        warn "Pas de depot git, 'pre-commit install' ignore"
        return
    fi

    local config="$git_root/.pre-commit-config.yaml"
    if [[ ! -f "$config" ]]; then
        info "Creation de $config"
        cat > "$config" <<'EOF'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-toml
      - id: check-added-large-files
EOF
    fi

    info "Installation du hook git pre-commit"
    poetry run pre-commit install
}

step_install() {
    require_pyproject
    info "Installation des dependances"
    poetry install --no-root
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local steps=()

    for arg in "$@"; do
        case "$arg" in
            -h|--help) usage; exit 0 ;;
            -y|--yes) ASSUME_YES=1 ;;
            init|config|source|credentials|deps|devtools|install) steps+=("$arg") ;;
            *) usage; die "Etape inconnue : $arg" ;;
        esac
    done

    [[ ${#steps[@]} -eq 0 ]] && steps=("${ALL_STEPS[@]}")

    command -v poetry >/dev/null 2>&1 \
        || die "Poetry introuvable (https://python-poetry.org/docs/#installation)"
    POETRY_VERSION="$(poetry_version)"
    info "Poetry $POETRY_VERSION, projet : $PROJECT_DIR"

    if is_interactive && [[ " ${steps[*]} " =~ \ (source|credentials)\  ]]; then
        ask ARTIFACTORY_URL "URL Artifactory" "$ARTIFACTORY_URL"
        ask ARTIFACTORY_REPO "Depot PyPI Artifactory" "$ARTIFACTORY_REPO"
    fi
    ARTIFACTORY_URL="${ARTIFACTORY_URL%/}"
    SOURCE_URL="${SOURCE_URL:-$ARTIFACTORY_URL/artifactory/api/pypi/$ARTIFACTORY_REPO/simple}"

    local global_start
    global_start=$(date +%s)
    for step in "${steps[@]}"; do
        run_step "$step"
    done
    info "Setup termine avec succes en $(( $(date +%s) - global_start ))s"
}

main "$@"
