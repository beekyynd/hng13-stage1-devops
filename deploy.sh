set -euo pipefail
IFS=$'\n\t'

# --------------------------- Logging & Utilities ---------------------------
TIMESTAMP() { date +"%Y%m%d_%H%M%S"; }
LOGFILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

log()  { printf "[%s] INFO: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf "[%s] WARN: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
err()  { printf "[%s] ERROR: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }

# Trap for unexpected exits
cleanup_on_exit() {
  rc=$?
  if [ $rc -ne 0 ]; then
    err "Script exited with error code $rc. See $LOGFILE for details."
  else
    log "Script finished successfully. Log: $LOGFILE"
  fi
}
trap cleanup_on_exit EXIT

# --------------------------- Input Collection -------------------------------
CLEANUP_MODE=0
if [ "${1:-}" = "--cleanup" ]; then
  CLEANUP_MODE=1
  shift || true
fi

prompt() {
  local varname="$1" prompt_msg="$2" default_val="${3:-}"
  local silent="${4:-0}"
  if [ "$silent" -eq 1 ]; then
    read -r -s -p "$prompt_msg " "$varname"
    echo
  else
    if [ -n "$default_val" ]; then
      read -r -p "$prompt_msg [$default_val]: " "$varname"
      : "${!varname:=$default_val}"
    else
      read -r -p "$prompt_msg: " "$varname"
    fi
  fi
}

log "Starting deployment script"

# Collect inputs
prompt GIT_URL "Git repository URL (HTTPS)"
GIT_URL="${GIT_URL:-}"
if [ -z "$GIT_URL" ]; then err "Git URL required"; exit 2; fi

prompt PAT "Personal Access Token (PAT) (input hidden)" "" 1
PAT="${PAT:-}"
if [ -z "$PAT" ]; then warn "No PAT provided — ensure the repository is public or SSH is configured"; fi

prompt BRANCH "Branch (default: main)" "main"
BRANCH="${BRANCH:-main}"

prompt SSH_USER "Remote SSH username (e.g. ubuntu)"
SSH_USER="${SSH_USER:-}"
if [ -z "$SSH_USER" ]; then err "SSH username required"; exit 3; fi

prompt SSH_HOST "Remote server IP or hostname"
SSH_HOST="${SSH_HOST:-}"
if [ -z "$SSH_HOST" ]; then err "Remote host required"; exit 4; fi

prompt SSH_KEY "Path to SSH private key for remote (absolute or relative)" "~/.ssh/id_rsa"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
if [ ! -f "$SSH_KEY" ]; then warn "SSH key not found at $SSH_KEY — SSH may prompt for password"; fi

prompt APP_PORT "Application internal port (container port) (e.g. 3000)" "3000"
APP_PORT="${APP_PORT:-3000}"

# Derived values
REPO_NAME="$(basename -s .git "$GIT_URL")"
LOCAL_CLONE_DIR="./$REPO_NAME"
REMOTE_APP_DIR="~/deploy_$REPO_NAME"
NGINX_SITE_NAME="${REPO_NAME}.conf"
CONTAINER_NAME="${REPO_NAME}_app"

log "Inputs collected: repo=$GIT_URL branch=$BRANCH host=$SSH_USER@$SSH_HOST app_port=$APP_PORT"

# --------------------------- Git clone / pull --------------------------------
clone_or_pull() {
  if [ -d "$LOCAL_CLONE_DIR/.git" ]; then
    log "Repository already cloned locally. Pulling latest on branch $BRANCH"
    cd "$LOCAL_CLONE_DIR"
    git fetch --all --prune
    git checkout "$BRANCH" || git checkout -b "$BRANCH" origin/$BRANCH || true
    git pull --ff-only || true
    cd - >/dev/null
  else
    log "Cloning repository"
    if [ -n "$PAT" ]; then
      # Insert PAT into HTTPS URL safely
      sanitized_url="$GIT_URL"
      # if user provided https://github.com/owner/repo.git --> insert token
      if printf "%s" "$GIT_URL" | grep -qE '^https?://'; then
        auth_url=$(printf "%s" "$GIT_URL" | sed -E "s#https?://#https://$PAT@#")
        git clone --depth 1 --branch "$BRANCH" "$auth_url" "$LOCAL_CLONE_DIR" || {
          err "git clone failed"; exit 10
        }
        # remove credentials from git config just in case
        if [ -f "$LOCAL_CLONE_DIR/.git/config" ]; then
          git -C "$LOCAL_CLONE_DIR" remote set-url origin "$GIT_URL" || true
        fi
      else
        # Non-HTTPS URL (ssh). Try normal clone
        git clone --depth 1 --branch "$BRANCH" "$GIT_URL" "$LOCAL_CLONE_DIR" || { err "git clone failed"; exit 11; }
      fi
    else
      git clone --depth 1 --branch "$BRANCH" "$GIT_URL" "$LOCAL_CLONE_DIR" || { err "git clone failed"; exit 12; }
    fi
  fi
}

clone_or_pull

# Check for Dockerfile or docker-compose.yml
if [ -d "$LOCAL_CLONE_DIR" ]; then
  if [ -f "$LOCAL_CLONE_DIR/Dockerfile" ] || [ -f "$LOCAL_CLONE_DIR/docker-compose.yml" ] || [ -f "$LOCAL_CLONE_DIR/docker-compose.yaml" ]; then
    log "Found Dockerfile or docker-compose in the project"
  else
    warn "No Dockerfile or docker-compose.yml found in project root. Script will still attempt to deploy but may fail."
  fi
else
  err "Local clone directory $LOCAL_CLONE_DIR missing"
  exit 20
fi

# --------------------------- SSH helper -------------------------------------
SSH_OPTS=( -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 )
if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
  SSH_OPTS+=( -i "$SSH_KEY" )
fi

ssh_cmd() {
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" -- "$@"
}

rsync_to_remote() {
  log "Transferring project to remote: $REMOTE_APP_DIR"
  rsync -avz --delete -e "ssh ${SSH_OPTS[*]}" "$LOCAL_CLONE_DIR/" "$SSH_USER@$SSH_HOST:$REMOTE_APP_DIR/" || { err "rsync failed"; exit 30; }
}

# --------------------------- Remote preparation -----------------------------
prepare_remote() {
  log "Preparing remote environment"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" bash -s <<'REMOTE'
set -euo pipefail
# Assume Debian/Ubuntu
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release
  # Install Docker if missing
  if ! command -v docker >/dev/null 2>&1; then
    logmsg() { printf "[%s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
    logmsg "Installing Docker"
    curl -fsSL https://get.docker.com | sh
  fi
  # Install docker-compose plugin or the python package
  if ! command -v docker-compose >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      true
    else
      # try install docker-compose plugin
      sudo apt-get install -y docker-compose-plugin || true
    fi
  fi
  # Install nginx
  if ! command -v nginx >/dev/null 2>&1; then
    sudo apt-get install -y nginx
  fi
  # enable and start services
  sudo systemctl enable --now docker || true
  sudo systemctl enable --now nginx || true
else
  echo "Unsupported remote OS (no apt-get). Please adapt the script for your distro." >&2
  exit 40
fi
REMOTE
  log "Remote preparation done"
}

# --------------------------- Deploy application -----------------------------
deploy_remote_app() {
  log "Deploying app on remote"
  # create remote dir
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "mkdir -p $REMOTE_APP_DIR"
  rsync_to_remote

  # On the remote: stop old container, remove, then build or docker-compose up
  REMOTE_RUN_CMD=$(cat <<EOF
set -euo pipefail
cd $REMOTE_APP_DIR
# bring down any previous compose
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose down || true
  else
    docker compose down || true
  fi
fi
# Stop and remove container by name if exists
if docker ps -a --format '{{.Names}}' | grep -w $CONTAINER_NAME >/dev/null 2>&1; then
  docker rm -f $CONTAINER_NAME || true
fi
# Deploy
if [ -f Dockerfile ]; then
  docker build -t $CONTAINER_NAME:latest .
  # Run with restart policy and map to 127.0.0.1:$APP_PORT
  docker run -d --name $CONTAINER_NAME --restart unless-stopped -p 127.0.0.1:$APP_PORT:$APP_PORT $CONTAINER_NAME:latest
elif [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d --build
  else
    docker compose up -d --build
  fi
else
  echo "No Dockerfile or docker-compose.yml found for building" >&2
  exit 50
fi
EOF
)

  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" bash -s <<-REMOTE2
  $REMOTE_RUN_CMD
REMOTE2

  log "Application deploy commands executed on remote"
}

# --------------------------- Nginx config -----------------------------------
configure_nginx() {
  log "Configuring Nginx reverse proxy"
  NGINX_CONF="server {\n    listen 80;\n    listen [::]:80;\n    server_name _;\n\n    location / {\n        proxy_pass http://127.0.0.1:$APP_PORT;\n        proxy_set_header Host \$host;\n        proxy_set_header X-Real-IP \$remote_addr;\n        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto \$scheme;\n    }\n}\n"

  # create remote nginx site
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" bash -s <<-REMOTECFG
  set -euo pipefail
  sudo tee /etc/nginx/sites-available/$NGINX_SITE_NAME > /dev/null <<'EOC'
$NGINX_CONF
EOC
  sudo ln -sf /etc/nginx/sites-available/$NGINX_SITE_NAME /etc/nginx/sites-enabled/$NGINX_SITE_NAME
  # remove default if exists to avoid conflicts
  sudo rm -f /etc/nginx/sites-enabled/default || true
  sudo nginx -t
  sudo systemctl reload nginx
REMOTECFG

  log "Nginx configured and reloaded to forward 80 -> $APP_PORT"
}

# --------------------------- Validation ------------------------------------
validate_deployment() {
  log "Validating deployment"
  # Check docker running
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "sudo systemctl is-active --quiet docker" || { err "Docker not active on remote"; exit 60; }

  # Check container
  if ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "docker ps --format '{{.Names}}' | grep -w $CONTAINER_NAME >/dev/null 2>&1"; then
    log "Container $CONTAINER_NAME is running"
  else
    err "Container $CONTAINER_NAME is not running"
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "docker ps -a --filter name=$CONTAINER_NAME --format 'table {{.ID}}\t{{.Status}}\t{{.Names}}' || true"
    exit 61
  fi

  # Check Nginx proxy locally on remote
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "curl -sS -I --max-time 5 http://127.0.0.1/ || true" >/dev/null || warn "Local curl to 127.0.0.1 returned non-zero"

  # Check from local machine to remote
  if curl -sS -I --max-time 8 "http://$SSH_HOST/" >/dev/null; then
    log "Remote HTTP request succeeded from control host"
  else
    warn "HTTP request to remote failed from control host; it may be blocked by firewall or provider. Try testing from another network or open port 80.";
  fi
}

# --------------------------- Cleanup mode ----------------------------------
run_cleanup() {
  log "Running cleanup on remote"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" bash -s <<-REMCL
  set -euo pipefail
  # stop and remove container
  if docker ps -a --format '{{.Names}}' | grep -w $CONTAINER_NAME >/dev/null 2>&1; then
    docker rm -f $CONTAINER_NAME || true
  fi
  # remove remote app dir
  rm -rf $REMOTE_APP_DIR || true
  # remove nginx site
  sudo rm -f /etc/nginx/sites-enabled/$NGINX_SITE_NAME /etc/nginx/sites-available/$NGINX_SITE_NAME || true
  sudo nginx -t || true
  sudo systemctl reload nginx || true
REMCL
  log "Cleanup completed"
}

# --------------------------- Main flow -------------------------------------
if [ "$CLEANUP_MODE" -eq 1 ]; then
  run_cleanup
  exit 0
fi

# Connectivity check
log "Checking SSH connectivity to $SSH_USER@$SSH_HOST"
if ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" echo ok >/dev/null 2>&1; then
  log "SSH connection works"
else
  err "Unable to SSH to $SSH_USER@$SSH_HOST"; exit 70
fi

prepare_remote

deploy_remote_app

configure_nginx

validate_deployment

log "Deployment complete"
exit 0
