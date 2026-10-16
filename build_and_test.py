#!/usr/bin/env python3
"""
build_and_test.py - Chaine de compilation et de test (equivalent Python de
build_and_test.sh)

Etapes : clean -> configure -> build -> test

Usage :
  ./build_and_test.py              # execute toutes les etapes
  ./build_and_test.py clean build  # execute seulement les etapes listees
  ./build_and_test.py -j 4 build   # option facultative (defaut : nb de CPU)
  ./build_and_test.py -h           # affiche l'aide
"""

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration (a adapter)
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent

# Valeurs par defaut, utilisees si l'option correspondante n'est pas passee
# (priorite : option en ligne de commande > variable d'environnement > defaut)
DEFAULT_PROJECT_DIR = os.environ.get("PROJECT_DIR") or str(SCRIPT_DIR)
DEFAULT_JOBS = int(os.environ.get("JOBS") or os.cpu_count() or 1)

ALL_STEPS = ["clean", "configure", "build", "test"]


# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------
def log(msg, stream=sys.stdout):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=stream, flush=True)


def info(msg):
    log(f"INFO  {msg}")


def error(msg):
    log(f"ERROR {msg}", stream=sys.stderr)


def die(msg):
    error(msg)
    sys.exit(1)


def positive_int(value):
    """Type argparse : entier strictement positif."""
    try:
        n = int(value)
    except ValueError:
        n = 0
    if n < 1:
        raise argparse.ArgumentTypeError(f"Nombre de jobs invalide : {value}")
    return n


def run(cmd, cfg, logfile):
    """Execute une commande dans le projet, sortie affichee et journalisee."""
    with subprocess.Popen(cmd, shell=True, cwd=cfg.project_dir, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as proc:
        for line in proc.stdout:
            sys.stdout.write(line)
            logfile.write(line)
    if proc.returncode != 0:
        die(f"Echec de la commande '{cmd}' (code {proc.returncode})")


# ---------------------------------------------------------------------------
# Etapes (a remplir avec vos commandes make ...)
# ---------------------------------------------------------------------------
def step_clean(cfg, logfile):
    # TODO : commandes de nettoyage
    # run("make clean", cfg, logfile)
    pass


def step_configure(cfg, logfile):
    # TODO : commandes de configuration
    # run("make config", cfg, logfile)
    pass


def step_build(cfg, logfile):
    # TODO : commandes de compilation
    # run(f"make -j{cfg.jobs} all", cfg, logfile)
    pass


def step_test(cfg, logfile):
    # TODO : commandes d'execution des tests
    # run("make test", cfg, logfile)
    pass


STEPS = {
    "clean": step_clean,
    "configure": step_configure,
    "build": step_build,
    "test": step_test,
}


# Execute une etape en journalisant sa sortie et sa duree
def run_step(step, cfg):
    info(f"=== Debut etape : {step} ===")
    start = time.time()
    with open(cfg.log_dir / f"{step}.log", "w") as logfile:
        STEPS[step](cfg, logfile)
    info(f"=== Fin etape : {step} ({int(time.time() - start)}s) ===")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Chaine de compilation et de test.",
        epilog="Variables d'environnement : PROJECT_DIR, LOG_DIR "
               "(defaut : $PROJECT_DIR/logs), JOBS",
    )
    # Arguments facultatifs : si non fournis -> valeur par defaut
    parser.add_argument("-p", "--project-dir", default=DEFAULT_PROJECT_DIR,
                        metavar="DIR",
                        help="Repertoire du projet (defaut : %(default)s)")
    parser.add_argument("-j", "--jobs", type=positive_int, default=DEFAULT_JOBS,
                        metavar="N",
                        help="Nombre de jobs make (defaut : %(default)s)")
    parser.add_argument("steps", nargs="*", choices=ALL_STEPS, metavar="etape",
                        help=f"Etapes a executer parmi {ALL_STEPS} "
                             "(defaut : toutes, dans l'ordre)")
    return parser.parse_args(argv)


def main(argv=None):
    cfg = parse_args(argv)

    cfg.project_dir = Path(cfg.project_dir).resolve()
    if not cfg.project_dir.is_dir():
        die(f"Repertoire projet introuvable : {cfg.project_dir}")

    cfg.log_dir = Path(os.environ.get("LOG_DIR") or cfg.project_dir / "logs").resolve()
    cfg.log_dir.mkdir(parents=True, exist_ok=True)

    info(f"Projet : {cfg.project_dir} | Jobs : {cfg.jobs} | Logs : {cfg.log_dir}")

    steps = cfg.steps or ALL_STEPS

    global_start = time.time()
    for step in steps:
        run_step(step, cfg)
    info(f"Chaine terminee avec succes en {int(time.time() - global_start)}s")


if __name__ == "__main__":
    main()
