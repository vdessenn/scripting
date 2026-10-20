#!/usr/bin/env bash
#
# setup_poetry.sh - Mise en place de Poetry (1.1.x, Python 3.6) sur un depot existant
#
# Etapes : pkginfo -> init -> config -> source -> credentials -> deps -> devtools -> install
#
#   pkginfo      Corrige pkginfo pour lire les metadonnees 2.4 (voir step_pkginfo)
#   init         Cree le pyproject.toml (ensemble de dependances, pas un paquet)
#   config       virtualenvs.in-project et ancien installeur, en global
#                (~/.config/pypoetry) et en local (poetry.toml) ; certificat
#                Artifactory en global uniquement (auth.toml)
#   source       Source Artifactory unique par defaut ([[tool.poetry.source]])
#   credentials  Utilisateur + jeton Artifactory (JFrog CLI ou navigateur),
#                stockes en clair dans ~/.config/pypoetry/auth.toml
#   deps         Propose PyQt5 (+ LD_LIBRARY_PATH dans .venv/bin/activate)
#                et dataclasses (backport Python 3.6)
#   devtools     Outils de dev (pytest, black, ...) et pre-commit
#   install      poetry install --no-root
#
# Usage :
#   ./setup_poetry.sh                     # execute toutes les etapes
#   ./setup_poetry.sh source credentials  # execute seulement les etapes listees
#   ./setup_poetry.sh -d chemin/projet    # projet ailleurs qu'a la racine du depot
#   ./setup_poetry.sh -h                  # affiche l'aide
#

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration (a adapter)
# ---------------------------------------------------------------------------
ARTIFACTORY_URL="${ARTIFACTORY_URL:-https://artifactory.example.com}"
ARTIFACTORY_REPO="${ARTIFACTORY_REPO:-pypi-remote}"
SOURCE_NAME="${SOURCE_NAME:-artifactory}"
SOURCE_URL="${SOURCE_URL:-$ARTIFACTORY_URL/artifactory/api/pypi/$ARTIFACTORY_REPO/simple}"
JF_SERVER_ID="${JF_SERVER_ID:-$SOURCE_NAME}"

# certificates.<source>.cert : "false" (Poetry >= 1.2) ou chemin d'un bundle CA
ARTIFACTORY_CERT="${ARTIFACTORY_CERT:-false}"

PYTHON_CONSTRAINT="${PYTHON_CONSTRAINT:->=3.6.8,<3.7}"

# Versions epinglees : Poetry 1.1 choisit sinon la derniere version publiee,
# meme si elle ne supporte plus Python 3.6
# Poetry 1.1 ne lit pas les dependances de PyQt5 depuis une source "legacy"
# (Artifactory) : PyQt5-Qt5 et PyQt5-sip doivent etre listes explicitement.
# PyQt5-Qt5 > 5.15.2 : pas de wheel Linux ; PyQt5-sip > 12.9.1 : Python >= 3.7
PYQT5_DEPS=(PyQt5==5.15.6 PyQt5-Qt5==5.15.2 PyQt5-sip==12.9.1)
DATACLASSES_DEP="dataclasses==0.8"
DEV_TOOLS=(
    pytest==7.0.1
    pytest-cov==4.0.0
    coverage==6.2
    black==22.8.0
    isort==5.10.1
    pylint==2.13.9
    mypy==0.971
    pre-commit==2.17.0
    pre-commit-hooks==4.1.0
)

POETRY_CONFIG_DIR="${POETRY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/pypoetry}"

ALL_STEPS=(pkginfo init config source credentials deps devtools install)

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
Usage: $(basename "$0") [-d repertoire] [etape ...]

Etapes disponibles : ${ALL_STEPS[*]}
Sans argument, toutes les etapes sont executees dans l'ordre.

Options :
  -d, --project-dir DIR  Repertoire du projet Python (defaut : racine du depot git)
  -h, --help             Affiche cette aide

Source Artifactory : $SOURCE_URL
(a modifier en tete de script ou via ARTIFACTORY_URL / ARTIFACTORY_REPO)
EOF
}

on_error() {
    error "Echec a la ligne $1 (code $2)"
}
trap 'on_error $LINENO $?' ERR

# ask <variable> <question> [defaut] : lit une valeur, garde le defaut si vide
ask() {
    local __var="$1" question="$2" default="${3:-}" answer=""
    read -r -p "$question${default:+ [$default]} : " answer || true
    printf -v "$__var" '%s' "${answer:-$default}"
}

# ask_secret <variable> <question> : saisie masquee
ask_secret() {
    local __var="$1" question="$2" answer=""
    read -r -s -p "$question : " answer || true
    echo
    printf -v "$__var" '%s' "$answer"
}

# confirm <question> [y|n] : retourne 0 si oui
confirm() {
    local question="$1" default="${2:-n}" answer="" hint="[y/N]"
    [[ "$default" == y ]] && hint="[Y/n]"
    read -r -p "$question $hint " answer || true
    [[ "${answer:-$default}" =~ ^[yYoO] ]]
}

open_url() {
    local url="$1"
    info "-> $url"
    if command -v xdg-open >/dev/null 2>&1 && confirm "Ouvrir dans le navigateur ?" y; then
        xdg-open "$url" >/dev/null 2>&1 &
    fi
}

# version_ge <version> <minimum>
version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# poetry_config <args...> : applique un reglage en global puis en local
poetry_config() {
    poetry config "$@"
    poetry config --local "$@"
}

require_pyproject() {
    [[ -f "$PROJECT_DIR/pyproject.toml" ]] \
        || die "Pas de pyproject.toml dans $PROJECT_DIR (lancer l'etape init)"
}

# toml_has_section <section> : la section existe-t-elle dans pyproject.toml ?
toml_has_section() {
    grep -qF "[$1]" "$PROJECT_DIR/pyproject.toml"
}

has_dependency() {
    grep -qiE "^\"?$1\"? *=" "$PROJECT_DIR/pyproject.toml"
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
    if [[ -f pyproject.toml ]] && toml_has_section tool.poetry; then
        info "pyproject.toml avec une section [tool.poetry] deja present, ignore"
        return
    fi
    [[ -f pyproject.toml ]] && warn "pyproject.toml sans section Poetry : poetry init le completera"

    local name version description author python
    local git_author
    git_author="$(git config user.name 2>/dev/null || true)"
    [[ -n "$git_author" ]] && git_author="$git_author <$(git config user.email 2>/dev/null || true)>"

    ask name "Nom du projet" "$(basename "$PROJECT_DIR" | tr '[:upper:]_ ' '[:lower:]--')"
    ask version "Version" "0.1.0"
    ask description "Description" ""
    ask author "Auteur" "$git_author"
    ask python "Contrainte de version Python" "$PYTHON_CONSTRAINT"

    info "Initialisation du projet '$name' (python $python)"
    local args=(--no-interaction --name "$name" --description "$description" --python "$python")
    [[ -n "$author" ]] && args+=(--author "$author")
    poetry init "${args[@]}"
    poetry version "$version"
}

# Fichier pkginfo/distribution.py charge par Poetry (vendorise ou dans son interpreteur)
find_pkginfo() {
    local poetry_bin shebang interp candidate
    poetry_bin="$(readlink -f "$(command -v poetry)")"

    # Installation get-poetry.py : dependances vendorisees dans ~/.poetry/lib
    for candidate in "$(dirname "$poetry_bin")"/../lib/poetry/_vendor/py3*/pkginfo/distribution.py; do
        [[ -f "$candidate" ]] && { realpath "$candidate"; return; }
    done

    # Installation pip / install-poetry.py : pkginfo de l'interpreteur de Poetry
    shebang="$(head -n1 "$poetry_bin")"
    read -r -a interp <<< "${shebang#\#!}"
    "${interp[@]}" -c 'import pkginfo.distribution as d; print(d.__file__)' 2>/dev/null
}

# pkginfo 1.10 (dernier compatible Python 3.6) ignore les metadonnees de version
# inconnue (2.4, 2.5, ...) : Poetry 1.1 ne voit alors pas le Requires-Python des
# paquets recents et choisit des versions incompatibles avec Python 3.6.
# Correctif : lire une version inconnue comme la plus recente connue.
step_pkginfo() {
    local file
    local original="return HEADER_ATTRS.get(self.metadata_version, [])"
    local patched="return HEADER_ATTRS.get(self.metadata_version, max(HEADER_ATTRS.items())[1])"

    file="$(find_pkginfo)"
    [[ -n "$file" && -f "$file" ]] || { warn "pkginfo de Poetry introuvable, etape ignoree"; return; }

    if grep -qF "$patched" "$file"; then
        info "pkginfo deja corrige ($file)"
        return
    fi
    if ! grep -qF "$original" "$file"; then
        info "$file ne necessite pas de correctif"
        return
    fi

    warn "pkginfo ignore les metadonnees recentes (2.4+) : Poetry peut choisir des versions"
    warn "incompatibles avec Python 3.6 (ex : attrs 26.1.0 qui requiert Python >= 3.9)"
    confirm "Corriger $file (sauvegarde en .orig) ?" y || return 0

    local sudo=""
    [[ -w "$file" ]] || sudo="sudo"
    $sudo cp -n "$file" "$file.orig"
    $sudo sed -i 's/return HEADER_ATTRS\.get(self\.metadata_version, \[\])/return HEADER_ATTRS.get(self.metadata_version, max(HEADER_ATTRS.items())[1])/' "$file"
    grep -qF "$patched" "$file" || die "Echec du correctif de $file"
    info "Correctif applique"

    # Les metadonnees deja en cache ont ete lues sans Requires-Python
    local cache_dir
    cache_dir="$(poetry config cache-dir | tr -d '"')"
    if [[ -d "$cache_dir/cache/repositories/$SOURCE_NAME" ]]; then
        info "Purge du cache Poetry de la source '$SOURCE_NAME'"
        rm -rf "${cache_dir:?}/cache/repositories/$SOURCE_NAME"
    fi
}

# Chemin du certificat : Poetry 1.1 ne sait pas desactiver la verification
resolve_cert() {
    if [[ "$ARTIFACTORY_CERT" != false ]] || version_ge "$POETRY_VERSION" 1.2; then
        return
    fi

    info "Poetry $POETRY_VERSION ne supporte pas 'certificates.$SOURCE_NAME.cert false' (Poetry >= 1.2) :"
    info "utilisation du bundle CA qui valide le certificat d'Artifactory"

    if [[ -n "${REQUESTS_CA_BUNDLE:-}" ]]; then
        [[ -f "$REQUESTS_CA_BUNDLE" ]] || die "REQUESTS_CA_BUNDLE introuvable : $REQUESTS_CA_BUNDLE"
        info "Bundle CA de REQUESTS_CA_BUNDLE : $REQUESTS_CA_BUNDLE"
        ARTIFACTORY_CERT="$REQUESTS_CA_BUNDLE"
        return
    fi

    warn "REQUESTS_CA_BUNDLE non defini"
    local default="" candidate
    for candidate in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
        [[ -f "$candidate" ]] && { default="$candidate"; break; }
    done
    ask ARTIFACTORY_CERT "Chemin du bundle CA (vide pour ne rien configurer)" "$default"

    if [[ -n "$ARTIFACTORY_CERT" && ! -f "$ARTIFACTORY_CERT" ]]; then
        die "Fichier introuvable : $ARTIFACTORY_CERT"
    fi
}

step_config() {
    require_pyproject

    info "virtualenvs.in-project = true"
    poetry_config virtualenvs.in-project true

    info "experimental.new-installer = false"
    poetry_config experimental.new-installer false

    resolve_cert
    if [[ -n "$ARTIFACTORY_CERT" ]]; then
        # Poetry 1.1 ecrit certificates.* dans auth.toml, meme avec --local
        info "certificates.$SOURCE_NAME.cert = $ARTIFACTORY_CERT (global, auth.toml)"
        poetry config "certificates.$SOURCE_NAME.cert" "$ARTIFACTORY_CERT"
    fi

    if ! grep -qsxE '/?\.venv/?' .gitignore; then
        info "Ajout de .venv/ a .gitignore"
        echo ".venv/" >> .gitignore
    fi
}

step_source() {
    require_pyproject

    if grep -qE "^name = \"$SOURCE_NAME\"" pyproject.toml; then
        info "Source '$SOURCE_NAME' deja definie dans pyproject.toml"
        grep -qF "url = \"$SOURCE_URL\"" pyproject.toml \
            || warn "Son URL differe de $SOURCE_URL, a verifier dans pyproject.toml"
        return
    fi

    # Poetry 1.1 n'a pas de commande 'poetry source add'
    info "Ajout de la source '$SOURCE_NAME' par defaut (remplace PyPI) : $SOURCE_URL"
    cat >> pyproject.toml <<EOF

[[tool.poetry.source]]
name = "$SOURCE_NAME"
url = "$SOURCE_URL"
default = true
EOF
}

# Jeton via la JFrog CLI (configuration du serveur au besoin)
credentials_via_jf() {
    if ! jf config show "$JF_SERVER_ID" >/dev/null 2>&1; then
        info "Configuration du serveur JFrog '$JF_SERVER_ID' (choisir 'Web Login' si propose)"
        jf config add "$JF_SERVER_ID" --url="$ARTIFACTORY_URL" --interactive=true || return 1
    fi

    info "Creation d'un jeton d'acces via la JFrog CLI"
    local json
    json="$(jf access-token-create --server-id="$JF_SERVER_ID")" || return 1
    ARTIFACTORY_TOKEN="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["access_token"])' <<< "$json")"
}

# Renvoie vers l'interface web pour se connecter et recuperer le jeton
credentials_via_browser() {
    info "1. Se connecter a Artifactory :"
    open_url "$ARTIFACTORY_URL/ui/login/"
    info "2. Generer un jeton (Edit Profile > Generate an Identity Token) :"
    open_url "$ARTIFACTORY_URL/ui/user_profile"
    info "   ou via 'Set Me Up' du depot $ARTIFACTORY_REPO :"
    info "   $ARTIFACTORY_URL/ui/repos/tree/General/$ARTIFACTORY_REPO"
    ask_secret ARTIFACTORY_TOKEN "Jeton Artifactory"
}

step_credentials() {
    local auth_file="$POETRY_CONFIG_DIR/auth.toml"
    if grep -qsF "[http-basic.$SOURCE_NAME]" "$auth_file" \
        && ! confirm "Identifiants '$SOURCE_NAME' deja presents dans $auth_file, les remplacer ?" n; then
        return
    fi

    local user
    ask user "Utilisateur Artifactory" "${USER:-}"

    ARTIFACTORY_TOKEN=""
    if command -v jf >/dev/null 2>&1 && confirm "Generer le jeton avec la JFrog CLI ?" y; then
        credentials_via_jf || warn "Echec de la JFrog CLI, passage par le navigateur"
    fi
    [[ -n "$ARTIFACTORY_TOKEN" ]] || credentials_via_browser
    [[ -n "$ARTIFACTORY_TOKEN" ]] || die "Aucun jeton saisi"

    # Backend keyring 'fail' : Poetry ecrit alors le jeton en clair dans auth.toml
    info "Enregistrement dans $auth_file"
    PYTHON_KEYRING_BACKEND=keyring.backends.fail.Keyring \
        poetry config "http-basic.$SOURCE_NAME" "$user" "$ARTIFACTORY_TOKEN"
    chmod 600 "$auth_file"

    local curl_opts=(-fsS -o /dev/null -u "$user:$ARTIFACTORY_TOKEN")
    case "$ARTIFACTORY_CERT" in
        false) curl_opts+=(-k) ;;
        "")    ;;
        *)     curl_opts+=(--cacert "$ARTIFACTORY_CERT") ;;
    esac
    if curl "${curl_opts[@]}" "$SOURCE_URL/"; then
        info "Connexion a $SOURCE_URL reussie"
    else
        warn "Impossible d'acceder a $SOURCE_URL avec ces identifiants"
    fi
}

# Ajoute a .venv/bin/activate l'export de LD_LIBRARY_PATH vers les libs Qt5
setup_pyqt5_env() {
    local activate="$PROJECT_DIR/.venv/bin/activate"
    local marker="# >>> setup_poetry PyQt5 >>>"

    [[ -f "$activate" ]] || { warn "$activate introuvable"; return; }
    grep -qF "$marker" "$activate" && return

    info "Ajout de LD_LIBRARY_PATH (libs Qt5) a $activate"
    cat >> "$activate" <<'EOF'

# >>> setup_poetry PyQt5 >>>
_pyqt5_lib="$(python3 -c "import PyQt5, os; print(os.path.join(os.path.dirname(PyQt5.__file__), 'Qt5', 'lib'))" 2>/dev/null)"
if [ -n "$_pyqt5_lib" ]; then
    export LD_LIBRARY_PATH="$_pyqt5_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
unset _pyqt5_lib
# <<< setup_poetry PyQt5 <<<
EOF
}

step_deps() {
    require_pyproject

    if confirm "Installer ${PYQT5_DEPS[*]} ?" n; then
        poetry add "${PYQT5_DEPS[@]}"
        setup_pyqt5_env
    fi

    if confirm "Installer $DATACLASSES_DEP (backport Python 3.6) ?" n; then
        # Marqueur python < 3.7 : rien a changer lors d'un passage a Python >= 3.7
        poetry add "$DATACLASSES_DEP" --python "<3.7"
    fi
}

# Reglages des outils de dev pour Python 3.6, ajoutes s'ils sont absents
write_tools_config() {
    toml_has_section tool.black || cat >> pyproject.toml <<'EOF'

[tool.black]
target-version = ["py36"]
EOF
    toml_has_section tool.isort || cat >> pyproject.toml <<'EOF'

[tool.isort]
profile = "black"
EOF
    toml_has_section tool.mypy || cat >> pyproject.toml <<'EOF'

[tool.mypy]
python_version = "3.6"
EOF
    toml_has_section tool.pylint.master || cat >> pyproject.toml <<'EOF'

[tool.pylint.master]
py-version = "3.6"
EOF
    toml_has_section tool.coverage.run || cat >> pyproject.toml <<'EOF'

[tool.coverage.run]
branch = true
EOF
}

# Configuration pre-commit 'repo: local' : les hooks utilisent les outils du .venv
write_precommit_config() {
    local config="$1" venv_bin="$2"
    cat > "$config" <<EOF
repos:
  - repo: local
    hooks:
      - id: trailing-whitespace
        name: trailing-whitespace
        entry: $venv_bin/trailing-whitespace-fixer
        language: system
        types: [text]
      - id: end-of-file-fixer
        name: end-of-file-fixer
        entry: $venv_bin/end-of-file-fixer
        language: system
        types: [text]
      - id: check-yaml
        name: check-yaml
        entry: $venv_bin/check-yaml
        language: system
        types: [yaml]
      - id: check-toml
        name: check-toml
        entry: $venv_bin/check-toml
        language: system
        types: [toml]
      - id: check-added-large-files
        name: check-added-large-files
        entry: $venv_bin/check-added-large-files
        language: system
      - id: isort
        name: isort
        entry: $venv_bin/isort
        language: system
        types: [python]
      - id: black
        name: black
        entry: $venv_bin/black
        language: system
        types: [python]
      - id: pylint
        name: pylint
        entry: $venv_bin/pylint
        language: system
        types: [python]
      - id: mypy
        name: mypy
        entry: $venv_bin/mypy
        language: system
        types: [python]
EOF
}

step_devtools() {
    require_pyproject

    info "Outils de dev : ${DEV_TOOLS[*]}"
    if confirm "Ajouter ces outils au groupe dev ?" y; then
        poetry add --dev "${DEV_TOOLS[@]}"
        write_tools_config
    fi

    local git_root
    if ! git_root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
        warn "Pas de depot git, configuration pre-commit ignoree"
        return
    fi

    local config="$git_root/.pre-commit-config.yaml" source_config=""
    ask source_config "Chemin du .pre-commit-config.yaml a reprendre (vide : config locale par defaut)" ""

    if [[ -n "$source_config" ]]; then
        source_config="${source_config/#\~/$HOME}"
        [[ -f "$source_config" ]] || die "Fichier introuvable : $source_config"
        if [[ "$(realpath "$source_config")" != "$(realpath -m "$config")" ]]; then
            if [[ ! -f "$config" ]] || confirm "Ecraser $config ?" n; then
                info "Copie de $source_config vers $config"
                cp "$source_config" "$config"
            fi
        fi
    elif [[ ! -f "$config" ]] || confirm "Ecraser $config par la config locale par defaut ?" n; then
        # Chemin du .venv relatif a la racine du depot, d'ou pre-commit lance les hooks
        local venv_bin
        venv_bin="$(realpath -m --relative-to="$git_root" "$PROJECT_DIR/.venv/bin")"
        info "Creation de $config"
        write_precommit_config "$config" "$venv_bin"
    fi

    info "Installation du hook git pre-commit"
    poetry run pre-commit install
}

step_install() {
    require_pyproject
    info "Installation des dependances"
    poetry install --no-root

    # Le .venv a pu etre recree : on remet l'export LD_LIBRARY_PATH
    if has_dependency pyqt5; then
        setup_pyqt5_env
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local steps=()
    PROJECT_DIR=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -d|--project-dir)
                [[ $# -ge 2 ]] || die "Option $1 : repertoire manquant"
                PROJECT_DIR="$2"
                shift
                ;;
            pkginfo|init|config|source|credentials|deps|devtools|install) steps+=("$1") ;;
            *) usage; die "Argument inconnu : $1" ;;
        esac
        shift
    done

    [[ ${#steps[@]} -eq 0 ]] && steps=("${ALL_STEPS[@]}")

    [[ -t 0 ]] || die "Script interactif : a lancer depuis un terminal"
    command -v poetry >/dev/null 2>&1 || die "Poetry introuvable"

    if [[ -z "$PROJECT_DIR" ]]; then
        PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    mkdir -p "$PROJECT_DIR"
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

    POETRY_VERSION="$(poetry --version | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)"
    [[ "$POETRY_VERSION" == 1.1.* ]] \
        || warn "Script prevu pour Poetry 1.1.x, version detectee : $POETRY_VERSION"
    info "Poetry $POETRY_VERSION, projet : $PROJECT_DIR"

    local global_start
    global_start=$(date +%s)
    for step in "${steps[@]}"; do
        run_step "$step"
    done
    info "Setup termine avec succes en $(( $(date +%s) - global_start ))s"
}

main "$@"
