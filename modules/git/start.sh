#!/usr/bin/env bash
set -euo pipefail

BLUE='\033[0;34m'
BOLD_BLUE='\033[1;34m'
WHITE='\033[0;37m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

trap 'echo -e "${RED}[Git] Error on line $LINENO${NC}"' ERR

header() {
  echo -e "${BLUE}───────────────────────────────────────────────${NC}"
  echo -e "${BOLD_BLUE}$1${NC}"
}

GIT_STATUS="${GIT_STATUS:-false}"
GIT_DIR="${GIT_DIR:-/home/container/www}"
GIT_BRANCH="${GIT_BRANCH:-master}"
GIT_SSH_STRICT_HOST_CHECKING="${GIT_SSH_STRICT_HOST_CHECKING:-yes}"

# Exit immediately if git updates are disabled
if ! [[ "$GIT_STATUS" =~ ^(true|1)$ ]]; then
  exit 0
fi

header "[Git] Checking & Updating Repository"

# Ensure user info exists for current UID (needed by SSH)
if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
  if [ -w /etc/passwd ]; then
    echo "container:x:$(id -u):$(id -g):container:/home/container:/usr/sbin/nologin" >> /etc/passwd
  else
    echo -e "${YELLOW}[Git] Warning: no passwd entry for uid $(id -u), and /etc/passwd is not writable. Setting HOME=/tmp.${NC}"
    export HOME="/tmp"
  fi
fi

# Ensure we have a writable directory for SSH and git operations
if [ -z "${HOME:-}" ] || [ ! -d "${HOME}" ] || [ ! -w "${HOME}" ]; then
  HOME="/tmp"
fi
mkdir -p "$HOME"

SSH_DIR="$HOME/.ssh"
if ! mkdir -p "$SSH_DIR" 2>/dev/null; then
  SSH_DIR="/tmp/.ssh"
  mkdir -p "$SSH_DIR"
fi

# Ensure git exists
if ! command -v git >/dev/null 2>&1; then
  echo -e "${RED}[Git] Git not installed; skipping.${NC}"
  exit 0
fi

# Ensure repo exists
if [[ ! -d "$GIT_DIR/.git" ]]; then
  echo -e "${YELLOW}[Git] No Git repo in '$GIT_DIR'; skipping.${NC}"
  exit 0
fi

cd "$GIT_DIR"

CURRENT_URL="$(git config --get remote.origin.url || true)"

if [[ -z "$CURRENT_URL" ]]; then
  echo -e "${YELLOW}[Git] No remote URL found; skipping.${NC}"
  exit 0
fi

# SSH remote support
if [[ "$CURRENT_URL" =~ ^git@|^ssh:// ]]; then
  echo -e "${WHITE}[Git] SSH remote detected.${NC}"

  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"

  if [[ -z "${GIT_SSH_PRIVATE_KEY:-}" ]]; then
    echo -e "${RED}[Git] SSH remote is configured but GIT_SSH_PRIVATE_KEY is empty.${NC}"
    exit 1
  fi

  # Normalize CRLF and literal \n escapes from panel-pasted keys.
  KEY_CONTENT="${GIT_SSH_PRIVATE_KEY//$'\r'/}"
  KEY_CONTENT="$(printf '%s' "$KEY_CONTENT" | perl -pe 's/\\n/\n/g')"

  printf '%s\n' "$KEY_CONTENT" > "$SSH_DIR/id_ed25519"

  # Repair keys pasted as a single BEGIN/body/END line separated by spaces.
  if [ "$(wc -l < "$SSH_DIR/id_ed25519")" -eq 1 ]; then
    if grep -q "BEGIN OPENSSH PRIVATE KEY" "$SSH_DIR/id_ed25519" && grep -q "END OPENSSH PRIVATE KEY" "$SSH_DIR/id_ed25519"; then
      perl -0777 -i -pe '
        if (/-----BEGIN OPENSSH PRIVATE KEY-----(.*?)-----END OPENSSH PRIVATE KEY-----/s) {
          $body = $1;
          $body =~ s/\s+//g;
          $body = join("\n", ($body =~ /(.{1,70})/g));
          s/-----BEGIN OPENSSH PRIVATE KEY-----(.*?)-----END OPENSSH PRIVATE KEY-----/-----BEGIN OPENSSH PRIVATE KEY-----\n$body\n-----END OPENSSH PRIVATE KEY-----/s;
        }
      ' "$SSH_DIR/id_ed25519"
    fi
  fi

  if ! grep -q "BEGIN .*PRIVATE KEY" "$SSH_DIR/id_ed25519"; then
    echo -e "${RED}[Git] SSH private key does not contain a BEGIN marker.${NC}"
    exit 1
  fi

  if ! grep -q "END .*PRIVATE KEY" "$SSH_DIR/id_ed25519"; then
    echo -e "${RED}[Git] SSH private key does not contain an END marker.${NC}"
    exit 1
  fi

  chmod 600 "$SSH_DIR/id_ed25519"

  if ! ssh-keygen -y -f "$SSH_DIR/id_ed25519" >/dev/null 2>&1; then
    echo -e "${RED}[Git] SSH private key is invalid after normalization. Check GIT_SSH_PRIVATE_KEY formatting.${NC}"
    exit 1
  fi

  if [[ -n "${GIT_SSH_KNOWN_HOSTS:-}" ]]; then
    echo "${GIT_SSH_KNOWN_HOSTS}" > "$SSH_DIR/known_hosts"
  else
    if command -v ssh-keyscan >/dev/null 2>&1; then
      ssh-keyscan -H github.com > "$SSH_DIR/known_hosts" 2>/dev/null
    else
      echo -e "${RED}[Git] ssh-keyscan is not available and GIT_SSH_KNOWN_HOSTS is empty.${NC}"
      exit 1
    fi
  fi
  chmod 600 "$SSH_DIR/known_hosts"

  export GIT_SSH_COMMAND="ssh -i $SSH_DIR/id_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=${GIT_SSH_STRICT_HOST_CHECKING} -o UserKnownHostsFile=$SSH_DIR/known_hosts"

# HTTPS token auth fallback
else
  if [[ -n "${ACCESS_TOKEN:-}" ]]; then
    echo -e "${WHITE}[Git] HTTPS remote detected; applying token auth…${NC}"

    CLEAN_URL="$(echo "$CURRENT_URL" | sed -E 's|https://[^@]*@|https://|')"
    GIT_DOMAIN="$(echo "$CLEAN_URL" | sed -E 's|https://([^/]+)/.*|\1|')"
    GIT_REPO="$(echo "$CLEAN_URL" | sed -E 's|https://[^/]+/(.*)|\1|')"
    GIT_HTTPS_USERNAME="${USERNAME:-x-access-token}"
    NEW_URL="https://${GIT_HTTPS_USERNAME}:${ACCESS_TOKEN}@${GIT_DOMAIN}/${GIT_REPO}"

    git remote set-url origin "$NEW_URL"
    echo -e "${GREEN}[Git] Remote URL updated with credentials.${NC}"
  else
    echo -e "${WHITE}[Git] No HTTPS credentials provided; using existing configuration.${NC}"
  fi
fi

echo -e "${WHITE}[Git] Fetching latest changes…${NC}"
git fetch origin || { echo -e "${RED}[Git] Failed to fetch origin via SSH. Ensure GIT_SSH_PRIVATE_KEY and known_hosts are correct.${NC}"; exit 1; }

echo -e "${WHITE}[Git] Resetting working tree to origin/${GIT_BRANCH}…${NC}"
git reset --hard "origin/${GIT_BRANCH}"

echo -e "${GREEN}[Git] Repository updated successfully.${NC}"

if [[ -x "/home/container/www/deploy.sh" ]]; then
  header "Running app deploy script"
  /home/container/www/deploy.sh
fi
