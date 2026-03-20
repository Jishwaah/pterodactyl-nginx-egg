#!/usr/bin/env bash
set -e

APPDEPLOY_SCRIPT="${APPDEPLOY_SCRIPT:-/home/container/www/deploy.sh}"

if [[ -x "$APPDEPLOY_SCRIPT" ]]; then
  "$APPDEPLOY_SCRIPT"
elif [[ -f "$APPDEPLOY_SCRIPT" ]]; then
  bash "$APPDEPLOY_SCRIPT"
else
  echo "[AppDeploy] Script not found: $APPDEPLOY_SCRIPT"
fi