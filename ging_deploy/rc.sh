# rc.sh — environment variables for deploy-local-mvd.sh
#
# Usage (from the ging_deploy folder):
#   source ./rc.sh
#   ./deploy-local-mvd.sh up
#
# Every value here also has the same default inside deploy-local-mvd.sh,
# so only change what you want to override.

# Logs, port-forward PIDs, the generated kind config and the Dataspace_UI clone live here
export WORKDIR="$HOME/deploytour-local"

# Upstream repo (Terraform, Helm charts, Dockerfiles). By default the script uses the git submodule
# ging_deploy/dataspace-ecosystem (pinned commit, never pulled) and only clones MVD_REPO_URL into
# $WORKDIR when the submodule folder is missing. Uncomment to force another checkout:
# export MVD_DIR="$HOME/deploytour-local/dataspace-ecosystem"

# Source repositories
export MVD_REPO_URL="https://github.com/AmadeusITGroup/dataspace-ecosystem.git"
export UI_REPO_URL="https://github.com/AmadeusITGroup/Dataspace_UI.git"

# kind cluster name (kubectl context will be kind-<name>)
export KIND_CLUSTER_NAME="dse-cluster"

# Host address the ingress (80/443) binds to. 127.0.0.1 = this machine only.
# 0.0.0.0 exposes it to the LAN — the management APIs and Vault have no auth, so only do it on purpose.
# Only applied when the cluster is created (run `down` then `up` to change it).
export KIND_LISTEN_ADDRESS="127.0.0.1"

# true|false — passed to terraform as tls_enabled and to the E2E tests
export TLS_ENABLED="false"

# true|false — run the gradle E2E tests after deploying (they can only run once per deployment)
export RUN_E2E_TESTS="false"

# true|false — also start the Dataspace_UI frontend (stays in the foreground)
export START_UI="false"

# provider|consumer — Dataspace_UI has no authority mode; authority is always deployed by terraform
export UI_ROLE="provider"

# Local ports for the port-forwards (the E2E tests expect these exact values)
export EVENTHUB_LOCAL_PORT="52717"
export POSTGRES_LOCAL_PORT="57521"

# Seconds to wait for every pod to be Ready/Completed after terraform apply
export POD_WAIT_TIMEOUT="900"

# true|false — run Gradle inside a JDK container (no host JDK needed to build the images)
export BUILD_IN_CONTAINER="true"
export GRADLE_BUILD_IMAGE="eclipse-temurin:17-jdk"

# Host JDK (17+), only used with BUILD_IN_CONTAINER=false or RUN_E2E_TESTS=true.
# Compiling on the host also needs a JDK 17 installed (the build pins a Java 17 toolchain).
# The images always ship their own Java 21 runtime.
# Prefers a JDK 17 unpacked in $WORKDIR/jdk17 (Temurin tarball from adoptium.net).
if [ -d "$WORKDIR/jdk17/Contents/Home" ]; then
  export JAVA_HOME="$WORKDIR/jdk17/Contents/Home"
elif [ -d /opt/homebrew/opt/openjdk@17 ]; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
fi
