#!/usr/bin/env bash
#
# deploy-local-mvd.sh
#
# Brings up (or tears down) the full DEPLOYTOUR MVD (Eona-X) locally on Kind + Terraform:
#   - Authority  (Issuer Service, Federated Catalog, Telemetry Service/Storage/CSV Manager, Identity Hub...)
#   - Provider   (Control Plane, Data Plane, Identity Hub, Backend Service, Kafka Proxy Manager...)
#   - Consumer   (Control Plane, Data Plane, Identity Hub, Kafka Proxy Manager...)
#   - Infra      (PostgreSQL, Vault, Kafka, emulated Event Hub, Azurite)
# Terraform ALWAYS deploys all three participants together; there is no role to pick.
# Optionally also starts the Dataspace_UI frontend (which only supports provider/consumer).
#
# Based on:
#   - MVD-Deployment-Local/MVD-DeployTour-Local.md   (backend + localhost/ image fix)
#   - MVD-Deployment-Local/MVD_DeployTour-local-ui.md (frontend)
#   - dataspace-ecosystem/system-tests/readme.md      (official repo readme)
#
# Usage:
#   source ./rc.sh                   # load configuration (see rc.sh)
#   ./deploy-local-mvd.sh up        # bring everything up
#   ./deploy-local-mvd.sh status    # status grouped by authority/provider/consumer/infra
#   ./deploy-local-mvd.sh down      # tear everything down (terraform destroy + delete kind cluster)
#
# Host requirements: docker (running), kind, kubectl, terraform, git.
# No host JDK needed by default: Gradle runs inside a JDK container (BUILD_IN_CONTAINER=true).
# Optional: npm (if START_UI=true).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration. Every variable can be overridden from the environment (rc.sh).
# ---------------------------------------------------------------------------
WORKDIR="${WORKDIR:-$HOME/deploytour-local}"
MVD_REPO_URL="${MVD_REPO_URL:-https://github.com/AmadeusITGroup/dataspace-ecosystem.git}"
UI_REPO_URL="${UI_REPO_URL:-https://github.com/AmadeusITGroup/Dataspace_UI.git}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-dse-cluster}"
KIND_LISTEN_ADDRESS="${KIND_LISTEN_ADDRESS:-127.0.0.1}"
TLS_ENABLED="${TLS_ENABLED:-false}"
RUN_E2E_TESTS="${RUN_E2E_TESTS:-false}"
START_UI="${START_UI:-false}"
UI_ROLE="${UI_ROLE:-provider}"
EVENTHUB_LOCAL_PORT="${EVENTHUB_LOCAL_PORT:-52717}"
POSTGRES_LOCAL_PORT="${POSTGRES_LOCAL_PORT:-57521}"
POD_WAIT_TIMEOUT="${POD_WAIT_TIMEOUT:-900}"
BUILD_IN_CONTAINER="${BUILD_IN_CONTAINER:-true}"
GRADLE_BUILD_IMAGE="${GRADLE_BUILD_IMAGE:-eclipse-temurin:17-jdk}"

# Derived paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Upstream repo: the git submodule next to this script if it exists (pinned commit),
# otherwise a plain clone under $WORKDIR. MVD_DIR can be forced from rc.sh.
if [ -z "${MVD_DIR:-}" ]; then
  if [ -d "$SCRIPT_DIR/dataspace-ecosystem" ]; then
    MVD_DIR="$SCRIPT_DIR/dataspace-ecosystem"
  else
    MVD_DIR="$WORKDIR/dataspace-ecosystem"
  fi
fi
UI_DIR="$WORKDIR/Dataspace_UI"
PF_DIR="$WORKDIR/.pf"        # port-forward PIDs and logs
LOG_DIR="$WORKDIR/logs"      # build/terraform logs

# kind registers the cluster in kubeconfig with a "kind-" prefix.
# Every kubectl call in this script uses this explicit context so it never
# touches another cluster (e.g. the AWS devbox) that happens to be current.
KCTX="kind-${KIND_CLUSTER_NAME}"

# Images produced by `./gradlew dockerize`. Terraform (environment=local) looks
# them up with a `localhost/` prefix (Podman's naming convention), so with Docker
# they must be re-tagged and both names loaded into kind. See MVD-DeployTour-Local.md.
# This is exactly the set referenced by system-tests/modules (grep '"localhost/').
# Note: MVD-DeployTour-Local.md lists telemetry-storage/csv-manager with a
# -postgresql-hashicorpvault suffix and two kafka-proxy-* images; the current build
# names them without the suffix, and the kafka-proxy images aren't used by terraform.
IMAGES=(
  control-plane-postgresql-hashicorpvault
  data-plane-postgresql-hashicorpvault
  identity-hub-postgresql-hashicorpvault
  telemetry-agent-postgresql-hashicorpvault
  backend-service-provider
  issuer-service-postgresql-hashicorpvault
  federated-catalog-postgresql-hashicorpvault
  federated-catalog-filter-postgresql-hashicorpvault
  telemetry-service-postgresql-hashicorpvault
  telemetry-storage
  telemetry-csv-manager
)

# Pod name prefixes per participant (used by `status`)
ROLES=(authority provider consumer)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# Fail with an install hint if a binary is missing
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1 ($2)"; }

# kubectl always pointed at the local kind cluster
kctl() { kubectl --context "$KCTX" "$@"; }

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; }

# Shared terraform vars (destroy and apply must use the same ones). kube_context
# defaults to kind-dse-cluster in variables.tf, so it must follow KIND_CLUSTER_NAME.
tf_vars() {
  printf '%s\n' "-var=environment=local" "-var=tls_enabled=${TLS_ENABLED}" "-var=kube_context=${KCTX}"
}

# ---------------------------------------------------------------------------
# Deployment steps
# ---------------------------------------------------------------------------
check_prereqs() {
  log "Checking prerequisites..."
  need docker    "https://docs.docker.com/get-docker/"
  need kind      "brew install kind"
  need kubectl   "brew install kubectl"
  need terraform "brew install terraform"
  need git       "brew install git"
  if [ "$BUILD_IN_CONTAINER" != "true" ]; then
    check_java
  fi
  if [ "$START_UI" = "true" ]; then
    need npm "https://nodejs.org/"
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon not running. Start Docker Desktop first."
}

# Only used with BUILD_IN_CONTAINER=false. The JDK is only needed to compile the
# jars (./gradlew shadowJar); the images ship their own Java 21 runtime.
# Gradle honours JAVA_HOME (set it in rc.sh).
check_java() {
  local java_bin="${JAVA_HOME:+$JAVA_HOME/bin/}java" version major
  command -v "$java_bin" >/dev/null 2>&1 || die "No JDK found. brew install openjdk@21 and set JAVA_HOME in rc.sh"
  version="$("$java_bin" -version 2>&1 | awk -F'"' '/version/ {print $2; exit}')"
  major="${version%%.*}"
  # Java 8 and older report "1.x"
  [ "$major" = "1" ] && major="$(echo "$version" | cut -d. -f2)"
  [ "${major:-0}" -ge 17 ] || die "JDK $version found, Gradle needs 17+. brew install openjdk@17 and set JAVA_HOME in rc.sh"
  # The EDC build plugin pins a Java 17 toolchain: Gradle can run on a newer JDK,
  # but a JDK 17 must still be installed for it to auto-detect.
  [ "$major" = "17" ] || warn "JDK $version: compiling needs a JDK 17 installed too (Gradle toolchain); E2E tests are fine with $version."
  log "Using JDK $version (${JAVA_HOME:-system java})"
}

# The upstream repo as a git submodule: initialise it if it is empty, never pull
# (the parent repo pins the commit; move it with `git submodule update --remote`).
ensure_mvd_repo() {
  local superproject
  superproject="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ "$MVD_DIR" = "$SCRIPT_DIR/dataspace-ecosystem" ] && [ -n "$superproject" ]; then
    if [ ! -e "$MVD_DIR/.git" ]; then
      log "Initialising submodule ging_deploy/dataspace-ecosystem..."
      git -C "$superproject" submodule update --init ging_deploy/dataspace-ecosystem
    fi
    log "Using submodule $MVD_DIR at $(git -C "$MVD_DIR" rev-parse --short HEAD) (pinned, not pulled)"
  else
    clone_or_update "$MVD_REPO_URL" "$MVD_DIR" "dataspace-ecosystem"
  fi
}

# Clone the repo if missing; otherwise try a fast-forward pull without overwriting local changes
clone_or_update() {
  local url="$1" dir="$2" name="$3"
  if [ -e "$dir/.git" ]; then
    log "$name already present at $dir, pulling latest..."
    git -C "$dir" pull --ff-only || warn "$name: pull failed (local changes?), using existing checkout"
  else
    log "Cloning $name into $dir..."
    git clone "$url" "$dir"
  fi
}

# Create the kind cluster if it doesn't exist. Same layout as the repo's
# system-tests/kind.config.yaml (single node labelled ingress-ready, 80/443 mapped
# to the host), plus an explicit listenAddress: the repo's file binds 0.0.0.0, which
# exposes the unauthenticated management APIs and Vault to the whole LAN.
ensure_kind_cluster() {
  if cluster_exists; then
    log "kind cluster '$KIND_CLUSTER_NAME' already exists, reusing it."
    local bound
    bound="$(docker port "${KIND_CLUSTER_NAME}-control-plane" 80/tcp 2>/dev/null | head -n1 || true)"
    case "$bound" in
      "${KIND_LISTEN_ADDRESS}:80"|"") ;;
      *) warn "Existing cluster has port 80 bound to $bound (wanted ${KIND_LISTEN_ADDRESS}). Run 'down' then 'up' to recreate it." ;;
    esac
  else
    local kind_config="$WORKDIR/kind.config.yaml"
    cat >"$kind_config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        listenAddress: "${KIND_LISTEN_ADDRESS}"
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        listenAddress: "${KIND_LISTEN_ADDRESS}"
        protocol: TCP
EOF
    log "Creating kind cluster '$KIND_CLUSTER_NAME' (ingress on ${KIND_LISTEN_ADDRESS}:80/443)..."
    kind create cluster --name "$KIND_CLUSTER_NAME" --config "$kind_config"
  fi
  # Terraform targets the context via -var=kube_context (see tf_vars); kubectl
  # calls use --context. Switching the current context too means a manual
  # `kubectl ...` afterwards hits this cluster and not, say, the AWS devbox.
  log "Switching kubectl context to $KCTX"
  kubectl config use-context "$KCTX" >/dev/null
  kctl cluster-info
}

# Ingress controller for kind, as in the official readme
install_ingress_nginx() {
  log "Installing ingress-nginx (kind provider)..."
  kctl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
  log "Waiting for ingress-nginx controller to be ready..."
  # The pod takes a few seconds to be created; `kubectl wait` fails immediately if it doesn't exist yet
  local i
  for i in $(seq 1 30); do
    kctl get pods -n ingress-nginx -l app.kubernetes.io/component=controller --no-headers 2>/dev/null | grep -q . && break
    sleep 2
  done
  kctl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s
}

# Build the jars and Docker images, then load them into kind under both
# their original name and the localhost/ prefix (documented fix).
build_and_load_images() {
  cd "$MVD_DIR"
  log "Building jars and Docker images (./gradlew clean shadowJar dockerize)... this takes a while"
  if [ "$BUILD_IN_CONTAINER" = "true" ]; then
    # Gradle runs in a JDK container. The Docker socket is mounted so the dockerize
    # task builds the images on the host daemon; a named volume caches ~/.gradle between runs.
    docker run --rm \
      -v "$MVD_DIR":/workspace -w /workspace \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v dse-gradle-cache:/root/.gradle \
      "$GRADLE_BUILD_IMAGE" \
      ./gradlew --no-daemon clean shadowJar dockerize 2>&1 | tee "$LOG_DIR/gradle-build.log"
  else
    ./gradlew clean shadowJar dockerize 2>&1 | tee "$LOG_DIR/gradle-build.log"
  fi

  log "Re-tagging images as localhost/<img>:latest and loading them into kind..."
  local load_args=() img
  for img in "${IMAGES[@]}"; do
    if docker image inspect "${img}:latest" >/dev/null 2>&1; then
      docker tag "${img}:latest" "localhost/${img}:latest"
      load_args+=("${img}:latest" "localhost/${img}:latest")
    else
      warn "  ${img}:latest was not built — its pod will fail with ErrImageNeverPull"
    fi
  done
  # Check the length before expanding: macOS's bash 3.2 errors on empty arrays under `set -u`.
  [ "${#load_args[@]}" -gt 0 ] || die "No images were built. Check $LOG_DIR/gradle-build.log"
  kind load docker-image "${load_args[@]}" --name "$KIND_CLUSTER_NAME"
}

# init + destroy + apply, as in the official readme. The prior destroy leaves a
# clean environment: the E2E tests can only run once per deployment.
run_terraform_apply() {
  cd "$MVD_DIR"
  local vars=() v
  while IFS= read -r v; do vars+=("$v"); done < <(tf_vars)

  log "terraform init..."
  terraform -chdir=system-tests init -upgrade 2>&1 | tee "$LOG_DIR/terraform-init.log"

  log "terraform destroy (clean previous state, ignored if nothing exists)..."
  terraform -chdir=system-tests destroy -auto-approve "${vars[@]}" 2>&1 | tee "$LOG_DIR/terraform-destroy.log" || true

  log "terraform apply ${vars[*]} ..."
  terraform -chdir=system-tests apply -auto-approve "${vars[@]}" 2>&1 | tee "$LOG_DIR/terraform-apply.log"
}

# Wait until every pod in the default namespace is Completed, or Running with
# all its containers ready (READY x/x).
wait_for_pods() {
  log "Waiting for pods to be Ready/Completed (timeout ${POD_WAIT_TIMEOUT}s)..."
  local elapsed=0 pods not_ready
  while true; do
    pods="$(kctl get pods --no-headers 2>/dev/null || true)"
    not_ready="$(printf '%s\n' "$pods" | awk '
      NF == 0           { next }
      $3 == "Completed" { next }
      $3 == "Running"   { split($2, r, "/"); if (r[1] == r[2]) next }
                        { print $1 " (" $3 " " $2 ")" }')"
    if [ -n "$pods" ] && [ -z "$not_ready" ]; then
      log "All pods are Ready/Completed."
      break
    fi
    if [ "$elapsed" -ge "$POD_WAIT_TIMEOUT" ]; then
      warn "Timeout waiting for pods. Not ready:"
      printf '%s\n' "$not_ready" >&2
      warn "Inspect with: kubectl --context $KCTX describe pod <name> / logs <name>"
      break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
}

# Port-forwards required by the E2E tests (and handy for manual access):
#   Event Hub  localhost:$EVENTHUB_LOCAL_PORT -> eventhubs-0:5672
#   Postgres   localhost:$POSTGRES_LOCAL_PORT -> postgresql-0:5432
# They run in the background; PIDs are stored in $PF_DIR so `down` can stop them.
start_port_forwards() {
  stop_port_forwards
  log "Starting port-forwards: eventhub -> :$EVENTHUB_LOCAL_PORT, postgres -> :$POSTGRES_LOCAL_PORT"
  nohup kubectl --context "$KCTX" port-forward eventhubs-0 "${EVENTHUB_LOCAL_PORT}:5672" \
    >"$PF_DIR/eventhub.log" 2>&1 &
  echo $! >"$PF_DIR/eventhub.pid"
  nohup kubectl --context "$KCTX" port-forward postgresql-0 "${POSTGRES_LOCAL_PORT}:5432" \
    >"$PF_DIR/postgres.log" 2>&1 &
  echo $! >"$PF_DIR/postgres.pid"

  # Check they're still alive (they die instantly if the pod is missing or the port is taken)
  sleep 3
  local name
  for name in eventhub postgres; do
    if kill -0 "$(cat "$PF_DIR/$name.pid")" 2>/dev/null; then
      log "  $name port-forward running (pid $(cat "$PF_DIR/$name.pid"))"
    else
      warn "  $name port-forward died, see $PF_DIR/$name.log"
    fi
  done
}

stop_port_forwards() {
  local name pidfile pid
  for name in eventhub postgres; do
    pidfile="$PF_DIR/$name.pid"
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log "Stopped $name port-forward (pid $pid)"
    fi
    rm -f "$pidfile"
  done
}

# Repo E2E tests (phases: setup, catalog, transfers, reports, cleanup).
# Require the port-forwards to be active. Can only run once per deployment.
run_e2e_tests() {
  cd "$MVD_DIR"
  # The tests connect to localhost:<port-forward> and to the ingress on localhost,
  # so they run on the host and need a host JDK (17+) even with BUILD_IN_CONTAINER=true.
  check_java
  log "Running E2E tests (tag EndToEndTest)..."
  TLS_ENABLED="$TLS_ENABLED" ./gradlew :system-tests:runner:test \
    -DincludeTags="EndToEndTest" \
    -Dtls.enabled="$TLS_ENABLED" 2>&1 | tee "$LOG_DIR/e2e-tests.log"
}

# Dataspace_UI frontend. Only provider/consumer configurations exist
# (there is no authority UI). Stays in the foreground serving with `ng serve`.
start_ui() {
  case "$UI_ROLE" in
    provider|consumer) ;;
    *) die "UI_ROLE must be 'provider' or 'consumer' (Dataspace_UI has no authority mode), got '$UI_ROLE'" ;;
  esac
  clone_or_update "$UI_REPO_URL" "$UI_DIR" "Dataspace_UI"
  cd "$UI_DIR"
  log "Installing UI dependencies (npm install)..."
  npm install
  warn "Check that api.config.local-backend.ts (managementBEContextPath) and"
  warn "proxy.local-backend.conf.json (target) point to your backend — see MVD_DeployTour-local-ui.md."
  log "Starting UI (role=$UI_ROLE). Ctrl+C stops the UI only; the cluster keeps running."
  npm run "start:local-backend-${UI_ROLE}"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_up() {
  check_prereqs
  ensure_mvd_repo
  ensure_kind_cluster
  install_ingress_nginx
  build_and_load_images
  run_terraform_apply
  wait_for_pods
  start_port_forwards

  if [ "$RUN_E2E_TESTS" = "true" ]; then
    run_e2e_tests
  fi

  cmd_status
  log "MVD is up on kind cluster '$KIND_CLUSTER_NAME' (context $KCTX)."
  log "Postgres -> localhost:$POSTGRES_LOCAL_PORT   Event Hub -> localhost:$EVENTHUB_LOCAL_PORT   Logs -> $LOG_DIR"

  if [ "$START_UI" = "true" ]; then
    start_ui
  else
    log "UI not started (set START_UI=true in rc.sh to launch Dataspace_UI)."
  fi
}

cmd_down() {
  stop_port_forwards
  if cluster_exists; then
    if [ -d "$MVD_DIR/system-tests" ]; then
      cd "$MVD_DIR"
      local vars=() v
      while IFS= read -r v; do vars+=("$v"); done < <(tf_vars)
      # Same as `up`: pin the context so terraform never destroys another cluster
      kubectl config use-context "$KCTX" >/dev/null
      log "terraform destroy..."
      terraform -chdir=system-tests destroy -auto-approve "${vars[@]}" || warn "terraform destroy failed, deleting the cluster anyway"
    fi
    log "Deleting kind cluster '$KIND_CLUSTER_NAME'..."
    kind delete cluster --name "$KIND_CLUSTER_NAME"
  else
    log "kind cluster '$KIND_CLUSTER_NAME' does not exist, nothing to destroy."
  fi
  log "Everything torn down. Repos in $WORKDIR and local Docker images are kept."
}

# Grouped status: authority / provider / consumer / infra, plus pods with problems
cmd_status() {
  if ! cluster_exists; then
    warn "kind cluster '$KIND_CLUSTER_NAME' does not exist. Run: $0 up"
    return 0
  fi

  local pods role
  pods="$(kctl get pods --no-headers 2>/dev/null || true)"
  if [ -z "$pods" ]; then
    warn "No pods in the default namespace yet."
  else
    for role in "${ROLES[@]}"; do
      printf '\n\033[1m== %s ==\033[0m\n' "$role"
      printf '%s\n' "$pods" | grep "^${role}-" || echo "  (none)"
    done
    printf '\n\033[1m== shared infra (postgres, eventhub, azurite, shared jobs) ==\033[0m\n'
    printf '%s\n' "$pods" | grep -Ev '^(authority|provider|consumer)-' || echo "  (none)"
    printf '\n\033[1m== problems ==\033[0m\n'
    printf '%s\n' "$pods" | grep -E 'CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull|Pending' || echo "  none"
  fi

  printf '\n\033[1m== port-forwards ==\033[0m\n'
  local name pidfile
  for name in eventhub postgres; do
    pidfile="$PF_DIR/$name.pid"
    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      echo "  $name: running (pid $(cat "$pidfile"))"
    else
      echo "  $name: stopped"
    fi
  done
}

mkdir -p "$WORKDIR" "$PF_DIR" "$LOG_DIR"

case "${1:-up}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  *)      die "Usage: $0 {up|down|status}" ;;
esac
