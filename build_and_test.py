#!/usr/bin/env python3
"""
build_and_test.py - Chaine de compilation et de test (equivalent Python de
build_and_test.sh)

Etapes : clean -> configure -> build -> test

Usage :
  ./build_and_test.py                             # execute toutes les etapes
  ./build_and_test.py clean build                 # seulement les etapes listees
  ./build_and_test.py --debug_level DEBUG build   # niveau de log (defaut : INFO)
  ./build_and_test.py -h                          # affiche l'aide
"""

import argparse
import logging
import os
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration (a adapter)
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = Path(os.environ.get("PROJECT_DIR") or SCRIPT_DIR).resolve()
LOG_DIR = Path(os.environ.get("LOG_DIR") or PROJECT_DIR / "logs").resolve()
JOBS = int(os.environ.get("JOBS") or os.cpu_count() or 1)

ALL_STEPS = ["clean", "configure", "build", "test"]
DEBUG_LEVELS = ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]
DEFAULT_DEBUG_LEVEL = "INFO"

log = logging.getLogger("build_and_test")


# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------
def die(msg):
    log.error(msg)
    sys.exit(1)


def run(cmd, logfile):
    """Execute une commande dans le projet, sortie affichee et journalisee."""
    log.debug("Commande : %s", cmd)
    with subprocess.Popen(cmd, shell=True, cwd=PROJECT_DIR, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as proc:
        for line in proc.stdout:
            sys.stdout.write(line)
            logfile.write(line)
    if proc.returncode != 0:
        die(f"Echec de la commande '{cmd}' (code {proc.returncode})")


# ---------------------------------------------------------------------------
# Etapes (a remplir avec vos commandes make ...)
# ---------------------------------------------------------------------------
def step_clean(logfile):
    # TODO : commandes de nettoyage
    # run("make clean", logfile)
    pass


def step_configure(logfile):
    # TODO : commandes de configuration
    # run("make config", logfile)
    pass


def step_build(logfile):
    # TODO : commandes de compilation
    # run(f"make -j{JOBS} all", logfile)
    pass


def step_test(logfile):
    # TODO : commandes d'execution des tests
    # run("make test", logfile)
    pass


STEPS = {
    "clean": step_clean,
    "configure": step_configure,
    "build": step_build,
    "test": step_test,
}


# Execute une etape en journalisant sa sortie et sa duree
def run_step(step):
    log.info("=== Debut etape : %s ===", step)
    start = time.time()
    with open(LOG_DIR / f"{step}.log", "w") as logfile:
        STEPS[step](logfile)
    log.info("=== Fin etape : %s (%ds) ===", step, time.time() - start)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Chaine de compilation et de test.")
    # Argument facultatif : s'il n'est pas fourni, il vaut DEFAULT_DEBUG_LEVEL
    parser.add_argument("--debug_level", type=str.upper, choices=DEBUG_LEVELS,
                        default=DEFAULT_DEBUG_LEVEL,
                        help="Niveau de log (defaut : %(default)s)")
    parser.add_argument("steps", nargs="*", choices=ALL_STEPS, metavar="etape",
                        help=f"Etapes a executer parmi {ALL_STEPS} "
                             "(defaut : toutes, dans l'ordre)")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, args.debug_level),
        format="[%(asctime)s] %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
    )
    log.debug("Niveau de debug : %s", args.debug_level)

    LOG_DIR.mkdir(parents=True, exist_ok=True)

    global_start = time.time()
    for step in args.steps or ALL_STEPS:
        run_step(step)
    log.info("Chaine terminee avec succes en %ds", time.time() - global_start)


if __name__ == "__main__":
    main()
