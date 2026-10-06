#!/bin/bash
set -e
cd "$(dirname "$0")"

PYTHON="$(command -v python3.12 || true)"
if [ -z "$PYTHON" ]; then
    echo "Python 3.12 not found. Install it with: brew install python@3.12" >&2
    exit 1
fi

"$PYTHON" -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

echo "Pre-downloading the Parakeet model (this pulls ~2.5GB, one time only)..."
.venv/bin/python3 -c "from parakeet_mlx import from_pretrained; from_pretrained('mlx-community/parakeet-tdt-0.6b-v2')"

echo "Setup complete."
