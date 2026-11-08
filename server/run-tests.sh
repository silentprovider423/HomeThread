#!/bin/sh
# Server-Tests in einem Wegwerf-Container (frische Datenbank, kein Netz nötig)
cd "$(dirname "$0")"
docker run --rm -v "$PWD:/w" -w /w python:3.12-slim sh -c \
  "pip -q install --root-user-action=ignore -r app/requirements.txt httpx==0.28.1 >/dev/null 2>&1; PYTHONPATH=app python -m unittest discover -s tests $*"
