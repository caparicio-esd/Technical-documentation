#!/bin/bash
# Creates a local venv, installs the requirements and opens the notebook in JupyterLab.
# The MVD must already be up: ../deploy-local-mvd.sh up
set -e

cd "$(dirname "$0")"

VENV_DIR="venv"

if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

echo "Installing requirements..."
pip install -q -r requirements.txt

echo "Starting JupyterLab..."
jupyter lab 00_environment.ipynb
