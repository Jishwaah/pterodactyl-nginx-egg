#!/bin/bash

set -euo pipefail

# [SETUP] Install necessary packages, including git + openssh-client
echo -e "[SETUP] Install packages"
apt-get update -qq > /dev/null 2>&1 && apt-get install -qq > /dev/null 2>&1 -y \
    git \
    openssh-client \
    wget \
    perl \
    perl-doc \
    fcgiwrap

# Add VERSION file
wget -q -O - https://api.tavuru.de/version/Ym0T/pterodactyl-nginx-egg \
    | grep -o '"version":"[^"]*"' \
    | cut -d'"' -f4 \
    | head -1 > /mnt/server/VERSION

# Change to server directory
cd /mnt/server

# Ensure current uid has a passwd entry for runtime SSH
UID_VAL=$(id -u)
GID_VAL=$(id -g)
if ! getent passwd "$UID_VAL" >/dev/null 2>&1; then
    if [ -w /etc/passwd ]; then
        echo "container:x:$UID_VAL:$GID_VAL:container:/home/container:/usr/sbin/nologin" >> /etc/passwd
    else
        echo "[Git] Warning: /etc/passwd is not writable; SSH user fallback may fail at runtime. Ensure you provide USERNAME and/or ACCESS_TOKEN for HTTPS fallback."
    fi
fi

# [SETUP] Create necessary folders
echo -e "[SETUP] Create folders"
mkdir -p logs tmp www

# Clone the default egg repository into a temporary directory
echo "[Git] Cloning default repository 'https://github.com/jishwaah/pterodactyl-nginx-egg' into temporary directory."
git clone https://github.com/jishwaah/pterodactyl-nginx-egg /mnt/server/gtemp > /dev/null 2>&1 \
    && echo "[Git] Repository cloned successfully." \
    || { echo "[Git] Error: Default repository clone failed."; exit 21; }

# Copy the support files from the temporary repository to the target directory
echo "[Git] Copying folder and files from default repository."
cp -r /mnt/server/gtemp/nginx /mnt/server || { echo "[Git] Error: Copying 'nginx' folder failed."; exit 22; }
cp -r /mnt/server/gtemp/php /mnt/server || { echo "[Git] Error: Copying 'php' folder failed."; exit 22; }
cp -r /mnt/server/gtemp/modules /mnt/server || { echo "[Git] Error: Copying 'modules' folder failed."; exit 22; }
cp /mnt/server/gtemp/start-modules.sh /mnt/server || { echo "[Git] Error: Copying 'start-modules.sh' file failed."; exit 22; }
cp /mnt/server/gtemp/LICENSE /mnt/server || { echo "[Git] Error: Copying 'LICENSE' file failed."; exit 22; }

chmod +x /mnt/server/start-modules.sh
find /mnt/server/modules -type f -name "*.sh" -exec chmod +x {} \;

# Remove the temporary cloned repository
rm -rf /mnt/server/gtemp

# Check if GIT_ADDRESS is set
if [ -z "${GIT_ADDRESS:-}" ]; then
    echo "[Git] Info: GIT_ADDRESS is not set."
    echo "[Git] Git operations are disabled. Skipping Git actions."
else
    # Optional: desired branch; empty means remote's default branch
    GIT_BRANCH="${GIT_BRANCH:-}"

    # Add .git suffix to GIT_ADDRESS if it's not present
    if [[ "${GIT_ADDRESS}" != *.git ]]; then
        GIT_ADDRESS="${GIT_ADDRESS}.git"
        echo "[Git] Added .git suffix to GIT_ADDRESS: ${GIT_ADDRESS}"
    fi
    CLONE_URL="${GIT_ADDRESS}"

    GIT_HTTPS_USERNAME="${USERNAME:-x-access-token}"

    # SSH bootstrap for git@github.com / ssh:// remotes
    if [[ "${GIT_ADDRESS}" =~ ^git@|^ssh:// ]]; then
    echo "[Git] SSH Git remote detected."

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    if [ -z "${GIT_SSH_PRIVATE_KEY:-}" ]; then
        echo "[Git] Error: GIT_SSH_PRIVATE_KEY is empty."
        exit 15
    fi

    # Normalize line endings and escaped newline content for the key
    KEY_CONTENT="${GIT_SSH_PRIVATE_KEY//$'\r'/}"
    # Convert literal escape sequences for newlines to actual newlines
    KEY_CONTENT="$(printf '%s' "$KEY_CONTENT" | perl -pe 's/\\n/\n/g')"

    # Write cleaned key
    echo "[Git] Info: Writing private key to /root/.ssh/id_ed25519"
    printf '%s\n' "$KEY_CONTENT" > /root/.ssh/id_ed25519

    # If key ended up on a single line, attempt a one-line OpenSSH key reformat
    if [ "$(wc -l < /root/.ssh/id_ed25519)" -eq 1 ]; then
        if grep -q "BEGIN OPENSSH PRIVATE KEY" /root/.ssh/id_ed25519 && grep -q "END OPENSSH PRIVATE KEY" /root/.ssh/id_ed25519; then
            echo "[Git] Info: Reformatting one-line OpenSSH key into multiline key."
            perl -0777 -i -pe '
                if (/-----BEGIN OPENSSH PRIVATE KEY-----(.*?)-----END OPENSSH PRIVATE KEY-----/s) {
                    $body = $1;
                    $body =~ s/\s+//g;
                    $body = join("\n", ($body =~ /(.{1,70})/g));
                    s/-----BEGIN OPENSSH PRIVATE KEY-----(.*?)-----END OPENSSH PRIVATE KEY-----/-----BEGIN OPENSSH PRIVATE KEY-----\n$body\n-----END OPENSSH PRIVATE KEY-----/s;
                }
            ' /root/.ssh/id_ed25519
        fi
    fi

    # Basic key sanity checks
    if ! grep -q "BEGIN .*PRIVATE KEY" /root/.ssh/id_ed25519; then
        echo "[Git] Error: SSH private key file does not contain a BEGIN marker."
        echo "[Git] Please ensure your GIT_SSH_PRIVATE_KEY includes the full key with BEGIN/END lines."
        exit 16
    fi
    if ! grep -q "END .*PRIVATE KEY" /root/.ssh/id_ed25519; then
        echo "[Git] Error: SSH private key file does not contain an END marker."
        echo "[Git] Please ensure you pasted the full private key."
        exit 16
    fi

    # Print debug key stats (non-secret)
    echo "[Git] Debug: key length lines=$(wc -l < /root/.ssh/id_ed25519)"
    echo "[Git] Debug: key head=$(head -n 1 /root/.ssh/id_ed25519)"
    echo "[Git] Debug: key tail=$(tail -n 1 /root/.ssh/id_ed25519)"

    chmod 600 /root/.ssh/id_ed25519

    # Validate the key before continuing
    if ! ssh-keygen -y -f /root/.ssh/id_ed25519 > /dev/null 2>&1; then
        echo "[Git] Error: SSH private key is invalid or unreadable. Ensure you pasted the full private key including BEGIN/END markers and that it is in PEM/OpenSSH format."
        echo "[Git] Debug: key length lines=$(wc -l < /root/.ssh/id_ed25519)"
        echo "[Git] Debug: key head=$(head -n 1 /root/.ssh/id_ed25519)"
        echo "[Git] Debug: key tail=$(tail -n 1 /root/.ssh/id_ed25519)"
        echo "[Git] Debug: key contains 'ENCRYPTED'=$(grep -c 'ENCRYPTED' /root/.ssh/id_ed25519)"
        exit 16
    fi

    echo "[Git] Fetching GitHub Ed25519 host key."
    ssh-keyscan -t ed25519 github.com > /tmp/github_known_hosts 2>/dev/null

    if [ ! -s /tmp/github_known_hosts ]; then
        echo "[Git] Error: Failed to retrieve GitHub host key."
        exit 17
    fi

    EXPECTED_FP='SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'
    FETCHED_FP="$(ssh-keygen -lf /tmp/github_known_hosts -E sha256 | awk '{print $2}')"

    if [ "${FETCHED_FP}" != "${EXPECTED_FP}" ]; then
        echo "[Git] Error: GitHub host key fingerprint mismatch."
        echo "[Git] Expected: ${EXPECTED_FP}"
        echo "[Git] Got:      ${FETCHED_FP}"
        exit 18
    fi

    mv /tmp/github_known_hosts /root/.ssh/known_hosts
    chmod 600 /root/.ssh/known_hosts

    export GIT_SSH_COMMAND="ssh -i /root/.ssh/id_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=${GIT_SSH_STRICT_HOST_CHECKING:-yes} -o UserKnownHostsFile=/root/.ssh/known_hosts"

    echo "[Git] GitHub host key verified and known_hosts created."
    ssh -T git@github.com || true
    elif [ -n "${ACCESS_TOKEN:-}" ]; then
        echo "[Git] HTTPS remote detected. Using personal access token authentication."
        CLONE_URL="$(printf '%s' "${GIT_ADDRESS}" | sed -E "s|^https://|https://${GIT_HTTPS_USERNAME}:${ACCESS_TOKEN}@|")"
    else
        echo "[Git] Using anonymous Git access."
    fi

    # Check if the 'www' directory exists, if not create it
    if [ ! -d /mnt/server/www ]; then
        echo "[Git] Creating /mnt/server/www directory."
        mkdir -p /mnt/server/www
    else
        rm -rf /mnt/server/www
        mkdir -p /mnt/server/www
    fi

    cd /mnt/server/www || { echo "[Git] Error: Could not access /mnt/server/www directory."; exit 1; }

    if [ "$(ls -A /mnt/server/www 2>/dev/null)" ]; then
        echo "[Git] /mnt/server/www directory is not empty."

        if [ -d .git ]; then
            echo "[Git] .git directory exists in 'www'."

            if [ -f .git/config ]; then
                echo "[Git] Loading repository info from git config in 'www'."
                ORIGIN=$(git config --get remote.origin.url)
            else
                echo "[Git] Error: .git/config not found in 'www'. The directory may contain files, but it's not a valid Git repository."
                exit 10
            fi
        else
            echo "[Git] Error: Directory contains files but no Git repository found in 'www'."
            exit 11
        fi

        if [ "${ORIGIN}" == "${GIT_ADDRESS}" ]; then
            if [ -n "${GIT_BRANCH}" ]; then
                echo "[Git] Updating specific branch '${GIT_BRANCH}'."
                git fetch --prune origin "${GIT_BRANCH}" || { echo "[Git] Error: git fetch failed for branch '${GIT_BRANCH}'."; exit 12; }

                if git show-ref --verify --quiet "refs/heads/${GIT_BRANCH}"; then
                    git checkout "${GIT_BRANCH}" || { echo "[Git] Error: git checkout '${GIT_BRANCH}' failed."; exit 12; }
                else
                    git checkout -b "${GIT_BRANCH}" "origin/${GIT_BRANCH}" || { echo "[Git] Error: creating local branch '${GIT_BRANCH}' failed."; exit 12; }
                fi

                git pull --ff-only origin "${GIT_BRANCH}" || { echo "[Git] Error: git pull failed for branch '${GIT_BRANCH}'."; exit 12; }
            else
                echo "[Git] Updating current tracking branch."
                git fetch --prune origin || { echo "[Git] Error: git fetch failed."; exit 12; }
                git pull --ff-only || { echo "[Git] Error: git pull failed for 'www'."; exit 12; }
            fi
        else
            echo "[Git] Error: Repository origin does not match the provided GIT_ADDRESS in 'www'."
            exit 13
        fi
    else
        # Directory is empty, clone the repository
        echo "[Git] /mnt/server/www directory is empty. Cloning into /mnt/server/www."

        if [ -n "${GIT_BRANCH}" ]; then
            echo "[Git] Running: git clone --branch ${GIT_BRANCH} --single-branch ${GIT_ADDRESS} ."
            git clone --branch "${GIT_BRANCH}" --single-branch "${CLONE_URL}" . \
                && echo "[Git] Repository cloned successfully (branch '${GIT_BRANCH}')." \
                || { echo "[Git] Error: git clone failed for 'www' (branch '${GIT_BRANCH}')."; exit 14; }
        else
            echo "[Git] Running: git clone ${GIT_ADDRESS} ."
            git clone "${CLONE_URL}" . \
                && echo "[Git] Repository cloned successfully." \
                || { echo "[Git] Error: git clone failed for 'www'."; exit 14; }
        fi
    fi
fi

# Check if WordPress should be installed
if [ "${WORDPRESS:-0}" == "true" ] || [ "${WORDPRESS:-0}" == "1" ]; then
    echo "[SETUP] Install WordPress"
    cd /mnt/server/www
    wget -q http://wordpress.org/latest.tar.gz > /dev/null 2>&1 || { echo "[SETUP] Error: Downloading WordPress failed."; exit 16; }
    tar xzf latest.tar.gz > /dev/null 2>&1
    mv wordpress/* .
    rm -rf wordpress latest.tar.gz
    echo "[SETUP] WordPress installed - http://ip:port/wp-admin"
elif [ -z "${GIT_ADDRESS:-}" ]; then
    # Create a simple PHP info page if WordPress is not installed and no git repo was provided
    echo "<?php phpinfo(); ?>" > "www/index.php"
fi

echo -e "[DONE] Everything has been installed successfully"
echo -e "[INFO] You can now start the nginx web server"
