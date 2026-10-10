# Local MVD deployment — technology report

A long-form walkthrough of every technology involved in bringing up the DEPLOYTOUR / Eona-X Minimum Viable Dataspace on a laptop with `ging_deploy/deploy-local-mvd.sh`. For each technology the report covers what it is, why it is in this deployment, how it is configured here (real values taken from the running cluster and the upstream repository), and what to watch out for.

It is meant to be read top to bottom once, and then used as a reference. Companion documents:

- [README.md](README.md): what gets deployed, ports and ingress routes (the short version)
- [FLOWS.md](FLOWS.md): every functional flow, with commands
- [DIAGRAMS.md](DIAGRAMS.md): architecture, sequence and state diagrams, glossary

Everything below was observed on 2026-10-09 against `AmadeusITGroup/dataspace-ecosystem@e0c5200` (EDC 0.16.1), on macOS 14 arm64 with Docker Desktop, `TLS_ENABLED=false`.

---

## Contents

**Part I — What runs and how it is configured**

1. [The big picture: seven layers](#1-the-big-picture-seven-layers)
2. [Docker and container images](#2-docker-and-container-images)
3. [Java, Gradle and the image build](#3-java-gradle-and-the-image-build)
4. [kind: Kubernetes in Docker](#4-kind-kubernetes-in-docker)
5. [Kubernetes objects used](#5-kubernetes-objects-used)
6. [ingress-nginx](#6-ingress-nginx)
7. [Terraform](#7-terraform)
8. [Helm](#8-helm)
9. [Eclipse Dataspace Components (EDC) runtime configuration](#9-eclipse-dataspace-components-edc-runtime-configuration)
10. [The EDC/DSE components one by one](#10-the-edcdse-components-one-by-one)
11. [Identity: did:web, keys, Verifiable Credentials, DCP](#11-identity-didweb-keys-verifiable-credentials-dcp)
12. [HashiCorp Vault](#12-hashicorp-vault)
13. [PostgreSQL](#13-postgresql)
14. [Azure emulators: Event Hubs and Azurite](#14-azure-emulators-event-hubs-and-azurite)
15. [TLS mode (optional)](#15-tls-mode-optional)
16. [Networking end to end](#16-networking-end-to-end)
17. [The deployment script, step by step](#17-the-deployment-script-step-by-step)
18. [Lifecycle: what survives what](#18-lifecycle-what-survives-what)
19. [Security posture](#19-security-posture)
20. [Local vs. devbox (AWS) vs. target architecture](#20-local-vs-devbox-aws-vs-target-architecture)
21. [Troubleshooting cookbook](#21-troubleshooting-cookbook)

**Part II — Where every configuration comes from**

22. [The configuration chain](#22-the-configuration-chain)
23. [Inventory of source files](#23-inventory-of-source-files)
24. [Tracing values end to end](#24-tracing-values-end-to-end)
25. [Provenance by component](#25-provenance-by-component)
26. [Secrets and keys: who creates what](#26-secrets-and-keys-who-creates-what)
27. [What the deployment does not create](#27-what-the-deployment-does-not-create)
28. [Creation order](#28-creation-order)

**Part III — How it is done, and how to change it**

29. [What each command does inside](#29-what-each-command-does-inside)
30. [How an EDC runtime boots](#30-how-an-edc-runtime-boots)
31. [Recipes](#31-recipes)
32. [Further reading](#32-further-reading)

---

## 1. The big picture: seven layers

```mermaid
graph TB
    L1["1. Host: macOS · Docker Desktop VM (linuxkit, 10 CPU, 7.7 GiB)"]
    L2["2. Build: Gradle 8.14.3 in eclipse-temurin:17-jdk → 11 container images"]
    L3["3. Cluster: kind v0.29 → one node container kindest/node:v1.33.1 (containerd)"]
    L4["4. Edge: ingress-nginx v1.15.1 on node ports 80/443"]
    L5["5. Provisioning: Terraform 1.16.5 (kubernetes, helm, tls providers)"]
    L6["6. Packaging: Helm — 10 local charts v0.1.0 (15 releases) + HashiCorp Vault chart v0.28.1 (3 releases)"]
    L7["7. Runtimes: EDC 0.16 Java apps + Postgres + Vault + Event Hubs/Azurite emulators"]
    L1 --> L2 --> L3 --> L4 --> L5 --> L6 --> L7
```

Each layer depends only on the one below it:

| Layer | Answers the question | Tool |
| --- | --- | --- |
| Host | Where does it run? | Docker Desktop (a Linux VM on macOS) |
| Build | What code runs? | Gradle + Docker build |
| Cluster | Where do the containers get scheduled? | kind |
| Edge | How do I reach it from my laptop? | ingress-nginx, `kubectl port-forward` |
| Provisioning | What exists, in what order, with which config? | Terraform |
| Packaging | How is one component templated into Kubernetes objects? | Helm |
| Runtimes | What does each process do? | EDC + DSE extensions, infra images |

Each section below goes through one layer in that order.

---

## 2. Docker and container images

### What it is

Docker builds and runs OCI containers. On macOS, Docker Desktop runs a small Linux VM (kernel `7.0.14-linuxkit` here) and every container, including the kind "node", runs inside that VM. The VM's resources are the ceiling for the whole dataspace: **10 CPUs and 7.7 GiB of RAM** in this setup. Other containers you run (Mongo, Grafana, Redis…) share that budget.

### Why it is here

- To **build** the 11 EDC images (Gradle talks to the Docker daemon).
- To **run** kind: the Kubernetes node is itself a Docker container (`dse-cluster-control-plane`).
- To run the containerised Gradle build (`eclipse-temurin:17-jdk`).

### Image anatomy

All EDC launchers share the same Dockerfile shape (e.g. `launchers/control-plane/control-plane-postgresql-hashicorpvault/Dockerfile`):

```dockerfile
ARG REGISTRY_URL="quay.io/centos"
ARG BASE_IMAGE="centos:latest"
FROM ${REGISTRY_URL}/${BASE_IMAGE}                      # CentOS Stream from quay.io
ARG INSTALL_JAVA=true
RUN if [ "$INSTALL_JAVA" = "true" ]; then yum install java-21-openjdk -y; fi    # runtime JRE 21
ARG INSTALL_OPENSSL=true
RUN if [ "$INSTALL_OPENSSL" = "true" ]; then yum install openssl -y; fi
WORKDIR /app
RUN groupadd -g 1000 appuser && useradd -u 1000 -g appuser -s /bin/sh -m appuser
COPY ${JAR} controlplane.jar                            # shadow (fat) jar
COPY ${OTEL_JAR} opentelemetry-javaagent.jar
ENV WEB_HTTP_PORT="8080"            WEB_HTTP_PATH="/api"
ENV WEB_HTTP_MANAGEMENT_PORT="8181" WEB_HTTP_MANAGEMENT_PATH="/api/management"
ENV WEB_HTTP_PROTOCOL_PORT="8282"   WEB_HTTP_PROTOCOL_PATH="/api/dsp"
ENV WEB_HTTP_CONTROL_PORT="8383"    WEB_HTTP_CONTROL_PATH="/api/control"
ENV WEB_HTTP_ONBOARDING_PORT="8484" WEB_HTTP_ONBOARDING_PATH="/api/onboarding"
USER appuser
CMD ["java", "-javaagent:/app/opentelemetry-javaagent.jar",
     "-Djava.util.logging.config.file=/app/logging.properties",
     "-Dotel.javaagent.configuration-file=/app/opentelemetry.properties",
     "-jar", "controlplane.jar"]
```

Things to notice:

- **Compile JDK ≠ runtime JRE.** The code is compiled with a Java 17 toolchain, and the image installs Java 21 to run it. Bytecode compiled for 17 runs fine on 21.
- **Ports are baked in as defaults** through `WEB_HTTP_*` env vars, which is how EDC configures its HTTP contexts (see section 9).
- **Non-root**: uid/gid 1000.
- **OpenTelemetry agent** is attached to every JVM but switched off at runtime (`otel.javaagent.enabled=false` in the mounted `opentelemetry.properties`).
- `HEALTHCHECK NONE`: health is checked by Kubernetes probes instead.
- The base is `centos:latest`, which is **unpinned**, so two builds a week apart may produce different images.

### The 11 images and the `localhost/` convention

| Image | Used by |
| --- | --- |
| `control-plane-postgresql-hashicorpvault` | provider/consumer control planes |
| `data-plane-postgresql-hashicorpvault` | provider/consumer data planes |
| `identity-hub-postgresql-hashicorpvault` | the three identity hubs |
| `telemetry-agent-postgresql-hashicorpvault` | provider/consumer telemetry agents |
| `backend-service-provider` | sample backend |
| `issuer-service-postgresql-hashicorpvault` | authority issuer |
| `federated-catalog-postgresql-hashicorpvault` | authority federated catalog |
| `federated-catalog-filter-postgresql-hashicorpvault` | authority catalog filter |
| `telemetry-service-postgresql-hashicorpvault` | authority telemetry service |
| `telemetry-storage` | authority telemetry storage |
| `telemetry-csv-manager` | authority CSV manager |

The `-postgresql-hashicorpvault` suffix means "this launcher bundles the Postgres stores and the HashiCorp Vault client". Sibling `-azurevault` launchers exist for Azure Key Vault and are not built here.

Terraform, with `environment = "local"`, references these images as **`localhost/<name>:latest` with `imagePullPolicy: Never`**. `localhost/` is the prefix Podman gives to locally built images. With Docker, `dockerize` produces plain `<name>:latest`, so the script re-tags each image and loads **both** names into the node. `Never` means Kubernetes will not try to pull from any registry: if the image is not already in the node's containerd store, the pod fails with `ErrImageNeverPull`.

---

## 3. Java, Gradle and the image build

### Gradle in this repo

- **Wrapper**: Gradle 8.14.3 (`./gradlew` downloads it on first use).
- **Plugins** (root `build.gradle.kts`):
  - `com.github.johnrengelman.shadow` 8.1.1: `shadowJar` builds a **fat jar** containing the app and all dependencies. EDC runtimes are assembled from extensions, and the fat jar is the runtime.
  - `com.bmuschko.docker-remote-api` 9.3.4: the `dockerize` task (`DockerBuildImage`) talks to the Docker daemon over its socket and builds `<project.name>:latest`.
  - `org.eclipse.edc.edc-build` 1.1.5: EDC's convention plugin. Among other things it **pins a Java 17 toolchain**.
- **Custom tasks** defined per launcher: `dockerize` (Docker), `podmanize` (Podman build + `podman save` to a tar), `loadToKind` (depends on `podmanize`, then `kind load image-archive`, or pushes to a registry if `CDS_REGISTRY_*` is set), `downloadOtel`/`copyOtel` (fetch the OpenTelemetry agent), `cleanCache`.
- **Image build args**, from `gradle.properties`: `registryUrl=quay.io/centos`, `baseImage=centos:latest`, `installJava=true`.

### The Java 17 toolchain

A Gradle *toolchain* separates "the JVM that runs Gradle" from "the JDK that compiles the code". The EDC build plugin requests `languageVersion=17`. Gradle looks for an installed JDK 17 and, because no download repositories are configured, **fails if none is found**:

```
Cannot find a Java installation on your machine (Linux … aarch64) matching:
{languageVersion=17, vendor=any vendor, implementation=vendor-specific}.
Toolchain download repositories have not been configured.
```

That is why JDK 21 or 23 alone is not enough, and why the script builds inside `eclipse-temurin:17-jdk`.

### The containerised build

```bash
docker run --rm \
  -v "$MVD_DIR":/workspace -w /workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v dse-gradle-cache:/root/.gradle \
  eclipse-temurin:17-jdk \
  ./gradlew --no-daemon clean shadowJar dockerize
```

| Flag | Purpose |
| --- | --- |
| `-v $MVD_DIR:/workspace` | The repo is mounted, so jars land in the host checkout (`build/` dirs) |
| `-v /var/run/docker.sock` | "Docker outside of Docker": the plugin inside the container builds images on the **host** daemon, so they show up in `docker images` |
| `-v dse-gradle-cache:/root/.gradle` | Named volume caching Gradle distributions and dependencies between runs |
| `--no-daemon` | No long-lived Gradle daemon in a throwaway container |

A cold build takes about 15 minutes; with a warm cache it is much faster. The host only needs a JDK for running the E2E tests (`RUN_E2E_TESTS=true`). `rc.sh` points `JAVA_HOME` at `~/deploytour-local/jdk17` (Temurin 17) when it exists.

---

## 4. kind: Kubernetes in Docker

### What it is

kind runs each Kubernetes *node* as a Docker container from the `kindest/node` image. The node container runs systemd, containerd, the kubelet and the control-plane static pods. It is the quickest way to get a conformant cluster locally.

### This cluster

| Property | Value |
| --- | --- |
| kind version | v0.29.0 |
| Node image | `kindest/node:v1.33.1` (Debian 12) |
| Nodes | one, `dse-cluster-control-plane` (control plane and workloads) |
| Container runtime | containerd (inside the node container) |
| CNI | kindnet |
| DNS | CoreDNS (2 replicas) |
| StorageClass | `standard` (default), provisioner `rancher.io/local-path`, reclaim `Delete` |
| kubeconfig context | `kind-dse-cluster`, API server on `127.0.0.1:<random port>` |

### Cluster config

The script writes `~/deploytour-local/kind.config.yaml`, which has the same layout as the repo's `system-tests/kind.config.yaml` plus an explicit `listenAddress`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"     # ingress-nginx's kind manifest selects this label
    extraPortMappings:
      - { containerPort: 80,  hostPort: 80,  listenAddress: "127.0.0.1", protocol: TCP }
      - { containerPort: 443, hostPort: 443, listenAddress: "127.0.0.1", protocol: TCP }
```

- `extraPortMappings` is a Docker port publish on the node container. Together with the ingress controller's `hostPort`, it makes `localhost:80` reach nginx.
- `listenAddress` defaults to `0.0.0.0` in kind (the upstream file does not set it), which **exposes the cluster on your LAN**. The script defaults to `127.0.0.1` (`KIND_LISTEN_ADDRESS`).

### Getting images in: `kind load`

`kind load docker-image a:latest b:latest --name dse-cluster` exports the images from the host Docker daemon and imports them into the node's containerd (`ctr images import`). The node does **not** share the host's image store. To list what the node has: `docker exec dse-cluster-control-plane crictl images` (44 images here).

---

## 5. Kubernetes objects used

Everything is in namespace **`default`** except the ingress controller (`ingress-nginx`) and kind's system pieces. All the kinds used:

| Kind | Count | Examples | Notes |
| --- | --- | --- | --- |
| Deployment | 16 | `provider-controlplane`, `authority-issuerservice`, `provider-backend` | Stateless EDC runtimes, 1 replica each |
| StatefulSet | 8 | `postgresql`, `eventhubs`, `azurite*`, `<p>-vault` | Stable names (`postgresql-0`) for things with identity or storage |
| Job | 13 | `<p>-db-init`, `<p>-vault-init-job`, `<p>-vault-keygen-job`, `billing-db-insert`, `create-blob-container*` | One-shot initialisation |
| Service (ClusterIP) | 28 | `provider-controlplane` (8080/8181/8282/8383), `postgres` (5432) | DNS name = service name |
| Ingress | 16 | `provider-controlplane`, `authority-vault-ingress` | Class `nginx`, host `localhost` |
| ConfigMap | ~26 | `<release>-config`, `<p>-db-init`, `eventhubs-config`, `postgresql` | Config files mounted into pods |
| Secret | 8 + Helm | `postgresql`, `<p>-db-credentials`, `<p>-vault`, `billinguser-db-credentials`, `sh.helm.release.v1.*` | Credentials and Helm release state |
| PersistentVolumeClaim | 3 | `data-<p>-vault-0` (10Gi) | Created by the Vault chart; see section 12 |

Patterns worth knowing:

- **Probes.** Every EDC Deployment has liveness `GET /api/check/liveness` and readiness `GET /api/check/readiness` on port 8080, every 10 s, timeout 5 s, 3 failures, with an explicit `Host: <release>` header. Readiness is what the script waits for.
- **No resource requests or limits** on any EDC pod (only `azurite-blobstorage` has `100m/128Mi` requests and a `512Mi` limit). The scheduler packs everything onto one node, and under memory pressure the kernel's OOM killer decides who dies.
- **Job TTL.** The Vault jobs set `ttl_seconds_after_finished = 3600`, so Kubernetes deletes them an hour after they finish. They disappear from `kubectl get jobs` later on; that is normal.
- **Inert Helm annotations.** The keygen job carries `helm.sh/hook: post-install,post-upgrade`, but it is a Terraform `kubernetes_job`, not a chart template, so Helm never sees those annotations.
- **Service DNS.** Inside the cluster `provider-controlplane`, `provider-controlplane.default` and `provider-controlplane.default.svc.cluster.local` all resolve. DIDs and DSP URLs use the short form.

Useful commands:

```bash
kubectl get deploy,sts,job,svc,ingress,pvc
kubectl describe pod <pod>                # events: image pulls, probe failures, OOMKilled
kubectl logs deploy/<name> [-f] [--since=5m]
kubectl get cm <release>-config -o yaml   # the EDC config file a runtime reads
```

---

## 6. ingress-nginx

### What it is

The community NGINX Ingress Controller watches `Ingress` objects and rewrites an nginx config accordingly. It is the single HTTP entry point from your laptop into the cluster.

### How it is installed here

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

That is the **kind provider** manifest. Its controller Deployment uses `hostPort: 80/443` and a nodeSelector on `ingress-ready=true`, so it binds directly on the node and the kind port mapping takes it to your Mac. It also creates a `LoadBalancer` Service (NodePorts 31566/32074 here), which stays pending on kind and is not used. The URL points at `main`, so **the version is not pinned**: v1.15.1 was installed this time.

### How the dataspace uses it

Every chart renders an Ingress like this:

```yaml
spec:
  ingressClassName: nginx
  rules:
    - host: localhost
      http:
        paths:
          - path: /provider/cp/(management)(.*)      # regex
            pathType: ImplementationSpecific
            backend: { service: { name: provider-controlplane, port: { number: 8181 } } }
metadata:
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /api/$1$2   # /provider/cp/management/v3/x → /api/management/v3/x
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/backend-protocol: HTTP     # HTTPS + proxy-ssl-* when TLS is on
```

Two consequences:

1. **Host matching is strict.** nginx builds one `server` block per host. A request whose `Host` is not `localhost` (an IP, a nip.io name) falls through to the default server and gets 404. If you remove the host from only *some* rules, those paths move to the default server and **stop answering on `localhost`**. This was tested; see README, "nip.io".
2. **Path prefixes are per participant.** `/authority/…`, `/provider/…` and `/consumer/…` route to the same service names you would use in-cluster, with the prefix rewritten to `/api/<context>`.

The Vault ingress is a plain Terraform `kubernetes_ingress_v1`, with path `/<p>/vault(/|$)(.*)` rewritten to `/$2`.

---

## 7. Terraform

### What it is

Terraform declares infrastructure as code (HCL), computes a plan by diffing the desired state against what it recorded in its **state file**, and applies the difference through *providers*.

### Providers

```hcl
terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }              # unpinned
    helm       = { source = "hashicorp/helm", version = ">= 3.0.1" }
    tls        = { source = "hashicorp/tls",  version = "~> 4.0" }
  }
}
provider "kubernetes" { config_path = var.kube_config_path, config_context = var.kube_context }
provider "helm"       { kubernetes = { config_path = var.kube_config_path, config_context = var.kube_context } }
```

- **kubernetes**: plain objects (Secrets, ConfigMaps, StatefulSets, Jobs, Services, the Vault Ingress).
- **helm**: `helm_release` resources, i.e. installing charts with values.
- **tls**: generates key pairs and certificates *inside Terraform*, which then end up in Vault and in Kubernetes Secrets.

`kube_context` defaults to `kind-dse-cluster`, independent of your current kubectl context. The script passes `-var=kube_context=kind-$KIND_CLUSTER_NAME` so a renamed cluster is still targeted correctly.

### Module structure (`system-tests/`)

```mermaid
graph TB
    ROOT["root (main.tf)"] --> PGM["module postgres"]
    ROOT --> BE["module backend-provider (backend-service)"]
    ROOT --> PART["module participant  for_each = [provider, consumer]"]
    ROOT --> AUTH["module authority"]
    ROOT --> AZB["module azurite_blobstorage"]
    ROOT --> CA["tls CA + wildcard cert + secrets (only if tls_enabled)"]
    PART --> DB1["module db (db-init job)"]
    PART --> V1["module vault (helm vault + init + keygen + ingress)"]
    PART --> CPH["helm control-plane"]
    PART --> DPH["helm data-plane"]
    PART --> IHH["helm identity-hub"]
    PART --> TAH["helm telemetry-agent"]
    AUTH --> DB2["module db (authority + billing)"]
    AUTH --> V2["module vault"]
    AUTH --> AH["helm identity-hub · issuer-service · federated-catalog · catalog-filter<br/>telemetry-service · telemetry-storage · telemetry-csv-manager"]
    AUTH --> EHM["module eventhub (eventhubs + azurite + azurite-report-storage)"]
```

`for_each` over `local.participants = [var.provider_name, var.consumer_name]` is how one module definition becomes two participants. Adding a third participant means adding it to that list (the upstream readme calls this "configure participants in `variables.tf`").

### The `environment` variable

One variable switches how images are referenced:

| `environment` | Image | Pull policy | Pull secret |
| --- | --- | --- | --- |
| `local` | `localhost/<name>` | `Never` | none |
| `devbox` | `cds.sec.io/<name>` (`devbox-registry`) | `Always` | `cdsregistrycred` |
| `selfhosted` | value from `*_image` variables | `Never` | none |
| `production` (default) | `<name>` | `IfNotPresent` | none |

Other root variables: `tls_enabled` (default **true**, script uses false), `provider_name`/`consumer_name`/`authority_name`, `auth_*` (Kafka proxy auth, unused here), `vault_folder`, Azurite account name/key (the well-known emulator defaults).

### Lifecycle used by the script

```bash
terraform -chdir=system-tests init -upgrade
terraform -chdir=system-tests destroy -auto-approve -var=environment=local -var=tls_enabled=false -var=kube_context=kind-dse-cluster
terraform -chdir=system-tests apply   -auto-approve -var=environment=local -var=tls_enabled=false -var=kube_context=kind-dse-cluster
```

- `destroy` before `apply` follows the upstream readme: the E2E tests assume a fresh dataspace.
- `apply` created **64 resources** and took about 2 minutes, because `helm_release` waits for pods to become ready.
- **State** lives in `system-tests/terraform.tfstate` (about 400 KB, local backend). It contains every generated private key and password in plain text. Never commit it.

---

## 8. Helm

### What it is

Helm packages Kubernetes manifests as *charts*: Go templates plus default `values.yaml`. A *release* is one installation of a chart with a given set of values, recorded in a `sh.helm.release.v1.<name>.v<rev>` Secret.

### Charts in this deployment

| Chart (source) | Version | Releases |
| --- | --- | --- |
| `charts/control-plane` (repo, local path) | 0.1.0 | `provider-controlplane`, `consumer-controlplane` |
| `charts/data-plane` | 0.1.0 | `provider-dataplane`, `consumer-dataplane` |
| `charts/identity-hub` | 0.1.0 | `authority-identityhub`, `provider-identityhub`, `consumer-identityhub` |
| `charts/telemetry-agent` | 0.1.0 | `provider-telemetryagent`, `consumer-telemetryagent` |
| `charts/issuer-service` | 0.1.0 | `authority-issuerservice` |
| `charts/federated-catalog` / `-filter` | 0.1.0 | `authority-federatedcatalog`, `authority-federatedcatalogfilter` |
| `charts/telemetry-service` / `-storage` / `-csv-manager` | 0.1.0 | `authority-telemetry*` |
| `vault` from `https://helm.releases.hashicorp.com` | 0.28.1 (Vault 1.17.2) | `authority-vault`, `provider-vault`, `consumer-vault` |

To inspect them: `helm --kube-context kind-dse-cluster list -A`, `helm get values provider-controlplane`, `helm get manifest provider-controlplane`.

### How Terraform drives Helm

```hcl
resource "helm_release" "controlplane" {
  name              = "provider-controlplane"
  repository        = "../charts"          # local chart directory
  chart             = "control-plane"
  cleanup_on_fail   = true
  dependency_update = true
  recreate_pods     = true
  values = [ yamlencode({ controlplane = { image = {...}, sts = {...}, did = {...}, ingress = {...}, postgresql = {...}, vault = {...}, config = <<EOT ... EOT } }) ]
}
```

The whole values tree is built in HCL and serialised with `yamlencode`, so the Terraform module is effectively the values file. Each EDC chart renders:

- a **Deployment** whose env vars come from values (`EDC_PARTICIPANT_ID`, `EDC_VAULT_HASHICORP_URL`, `EDC_DATASOURCE_DEFAULT_URL`…; section 9);
- a **Service** with one port per entry in `endpoints` (default, management, protocol, control…);
- an **Ingress** (section 6);
- a **ConfigMap `<release>-config`** with three files mounted under `/app`: `config.properties` (extra EDC settings, `EDC_FS_CONFIG=/app/config.properties`), `logging.properties` (set per component in Terraform: `.level=DEBUG` on control planes, participant identity hubs, the issuer and the three telemetry/billing services; `.level=INFO` on data planes and telemetry agents; the federated catalog, its filter and the authority identity hub have the block commented out and use the chart's default. Where set, `org.eclipse.edc.level=ALL` makes it very verbose) and `opentelemetry.properties` (agent disabled).

The Vault chart is configured with `injector.enabled=false`, `server.standalone.enabled=true` with a custom HCL config (section 12), `server.dev.enabled=false`, readiness probe disabled, and `wait_for_jobs=true` on the release.

---

## 9. Eclipse Dataspace Components (EDC) runtime configuration

### What EDC is

EDC is a Java framework for building dataspace connectors and the services around them. A *runtime* is a fat jar assembled from many *extensions*, each one contributing services, stores, API controllers or policy functions. The DSE extensions (`org.eclipse.dse…`, `extensions/` in the repo) add Amadeus-specific behaviour on top: credential-aware catalog filtering, agreement retirement, telemetry, custom policy functions, and the consumer data gateway.

### Where settings come from

EDC settings are dotted keys (`edc.vault.hashicorp.url`). The runtime reads them from, in increasing priority: the `config.properties` file pointed to by `EDC_FS_CONFIG`, environment variables, and JVM system properties. **Environment variable names are the key upper-cased with dots replaced by underscores**: `edc.vault.hashicorp.url` ⇄ `EDC_VAULT_HASHICORP_URL`. Dashes are kept (`EDC_VAULT_HASHICORP_TOKEN_SCHEDULED-RENEW-ENABLED`).

### HTTP contexts

Each API is a *web context* with its own port and path (`web.http.<context>.port|path`):

| Context | Port | Path | Exposed through ingress? |
| --- | --- | --- | --- |
| default (health) | 8080 | `/api` | no |
| management (control plane) / identity (IH) | 8181 | `/api/management`, `/api/identity` | yes |
| protocol (DSP) / credentials (IH) / data gateway (consumer DP) | 8282 | `/api/dsp`, `/api/credentials`, `/api/data` | yes |
| control / did | 8383 | `/api/control`, `/api/did` | DID only |
| onboarding (CP) / sts (IH) | 8484 | `/api/onboarding`, `/api/sts` | yes |
| statuslist (issuer) | 9999 | `/api/statuslist` | yes |
| public (data plane) | 8181 | `/api/public` | yes |

### Settings of a control plane, as deployed (provider)

```properties
EDC_PARTICIPANT_ID=did:web:provider-identityhub%3A8383:api:did      # the DID is the participant id
EDC_COMPONENT_ID=provider-controlplane
EDC_DSP_CALLBACK_ADDRESS=http://provider-controlplane:8282/api/dsp   # in-cluster, see section 16
EDC_CONTROL_ENDPOINT=http://provider-controlplane:8383/api/control
EDC_DATASOURCE_DEFAULT_URL=jdbc:postgresql://postgres/providerdb    # + user/password from <p>-db-credentials
EDC_SQL_SCHEMA_AUTOCREATE=true                                       # EDC creates its tables on boot
EDC_VAULT_HASHICORP_URL=http://provider-vault:8200                   # token from secret provider-vault/rootToken
EDC_VAULT_HASHICORP_TOKEN_TTL=300
EDC_VAULT_HASHICORP_TOKEN_SCHEDULED-RENEW-ENABLED=false
EDC_VAULT_HASHICORP_HEALTH_CHECK_ENABLED=true
EDC_IAM_ISSUER_ID=did:web:provider-identityhub%3A8383:api:did
EDC_IAM_STS_OAUTH_TOKEN_URL=http://provider-identityhub:8484/api/sts/token
EDC_IAM_STS_OAUTH_CLIENT_ID=did:web:provider-identityhub%3A8383:api:did   # secret alias -> vault
EDC_IAM_DID_WEB_USE_HTTPS=false                                     # resolve did:web over http (TLS off)
DSE_AUTHORITY_DID=did:web:authority-identityhub%3A8383:api:did
EDC_ENCRYPTION_AES_KEY_ALIAS=provider-aes                           # required since EDC 0.16
EDC_WEB_REST_CORS_ENABLED=true
EDC_WEB_REST_CORS_HEADERS=*
```

plus, in `config.properties`:

```properties
edc.iam.trusted-issuer.authority.id=did:web:authority-identityhub%3A8383:api:did
edc.vault.hashicorp.token.scheduled-renew-enabled=false
edc.vault.hashicorp.allow.fallback=true
edc.negotiation.state-machine.iteration-wait-millis=…
edc.transfer.state-machine.iteration-wait-millis=…
edc.policy.monitor.state-machine.iteration-wait-millis=…
edc.data.plane.selector.state-machine.check.period=5
dse.namespace.prefix=…
dse.policy.prefix=…
```

The pieces to remember: **the participant id is the DID**, **the DID is did:web over plain http**, **the only trusted issuer is the authority DID**, and **every secret is resolved through the participant's own Vault by alias**.

### Database schemas

`EDC_SQL_SCHEMA_AUTOCREATE=true` makes each store create its tables at startup. The `sql-migrations/` folders in the repo (v0.14, v0.15, v0.16) are for managed environments where autocreate is off.

---

## 10. The EDC/DSE components one by one

### Control plane (`<p>-controlplane`)

The connector's brain. It stores assets, policy definitions and contract definitions; runs the negotiation and transfer state machines; speaks DSP on 8282; selects a data plane over the control API (`/api/control/v1/dataplanes`); and runs the policy monitor that terminates transfers when an agreement is no longer in force. DSE extensions add `/v1alpha/catalog/query` (credential-filtered federated catalog), `/v3/contractagreements/retirements` (agreement retirement), asset property lookup, and contract validation.

### Data plane (`<p>-dataplane`)

Moves bytes. Key settings:

```properties
EDC_DATAPLANE_API_PUBLIC_BASEURL=http://provider-dataplane:8181/api/public/
EDC_TRANSFER_PROXY_TOKEN_SIGNER_PRIVATEKEY_ALIAS=provider       # signs EDR tokens
EDC_TRANSFER_PROXY_TOKEN_VERIFIER_PUBLICKEY_ALIAS=provider-pub  # verifies them on /api/public
EDC_DPF_SELECTOR_URL=http://provider-controlplane:8383/api/control/v1/dataplanes   # self-registration
```

The DSE **data gateway** (`data-plane-public-api-v2`, port 8282 `/api/data`) is what makes the consumer side convenient. An app calls its *own* data plane with `Authorization: <agreementId>` (and `Contract-Id`). The gateway finds the newest EDR for that agreement, then proxies method, path, query and body to the provider's public endpoint with the EDR token. Data consumption metrics (`data-plane-data-consumption-metrics`) record every served request for billing.

### Identity Hub (`<p>-identityhub`)

The participant wallet:

- serves the DID document on 8383 (`/api/did/did.json`);
- stores VCs (credentials API 8282, which is also where issuers deliver credentials and verifiers query presentations);
- runs the **STS** on 8484, which issues self-signed tokens for DCP;
- exposes the Identity admin API on 8181 (participant contexts, credential requests).

At boot a **super-user seed** extension creates the participant context for its DID, with the `admin` role, the key pair alias from Vault, and the service entries that end up in the DID document. The `ParticipantContextConfiguration` seed adds per-participant config (`edc.participant.*`, `edc.iam.*`).

### Issuer Service (`authority-issuerservice`)

Issues credentials. It holds **holders** (registered participants), **attestation definitions** (where facts come from: `json-database` or `database` tables), **credential definitions** (type, attestations, claim mappings, JWT format, validity), **issuance processes**, and the **status list** (revocation, served on 9999). DSE adds attestation APIs for membership, domain and visibility. `domain: "route"` in Terraform means this issuer will only attest the `route` domain (other domains return 403). Signing uses the authority's Vault key `authority` (`EDC_ISSUER_STATUSLIST_SIGNING_KEY_ALIAS=authority`).

### Federated catalog + filter (`authority-federatedcatalog`, `-filter`)

- **Crawler**: every 10 s (`EDC_CATALOG_CACHE_EXECUTION_PERIOD_SECONDS=10`, initial delay 10, batch size 1) it lists the issuer's holders (`participant-registry-node-directory`) and sends each one a DSP catalog request. Results go to a cache in `authoritydb` (shared with the authority identity hub and issuer). The cache is a copy, not the source of truth.
- **Query**: `/api/catalog/v1alpha/catalog/query` supports `filterExpression` (with nested JSON-LD paths), sort and pagination.
- **Filter**: `/filter` receives a participant's self-issued token, reads that participant's VCs, and drops datasets with a `RestrictedDiscoveryClaim` the participant does not satisfy, unless it holds a `VisibilityCredential` with scope `ALL`.

### Telemetry (`<p>-telemetryagent`, `authority-telemetry*`)

- **Agent**: reads consumption records from its participant DB, gets a SAS token from the telemetry service (`/api/credential/v1alpha/sas-token`, request signed with the participant DID), and publishes to Event Hub `eh1` in namespace `local-eventhub-eventhubs`.
- **Service**: verifies that the requester is onboarded and mints the SAS token from the `event-hub-connection-string` secret in the authority Vault. Terraform only configures the **alias** (`telemetryservice.tf`, `connection_string_alias`); the **value** is written by the E2E suite during setup. On a fresh deployment without the suite the secret does not exist, so the telemetry service cannot mint tokens and the agents cannot publish (recipe 31.9 writes it by hand).
- **Storage**: `POST /telemetry-events` into `billingdb`.
- **CSV manager**: `POST /billing-reports` generates a month's report per participant (cross-checking both sides of each contract); `GET` returns it as CSV for the JWT role `Participant.<name>`. Reports are stored in `azurite-report-storage`.

In production an Azure Function moves events from Event Hub to storage. Nothing does that locally except the E2E suite's `@AfterAll`.

### Backend (`provider-backend`)

A small HTTP app (image `backend-service-provider`, port 8080) used as the asset source: `/api/provider/data` echoes query params, `/api/provider/oauth2data` requires an OAuth2 token from `/api/oauth2/token`, and `/api/provider/failure` returns 500. It is itself a tiny EDC runtime: one extension (`system-tests/backend-service-provider/src/.../ProviderBackendServiceExtension.java`) registering `ProviderBackendApiController` and `ProviderOauth2TokenController`, deployed by Terraform as a plain Deployment + Service (`modules/backend-service/main.tf`), not through Helm.

---

## 11. Identity: did:web, keys, Verifiable Credentials, DCP

### did:web

A `did:web` DID maps deterministically to an HTTPS (here HTTP) URL: `did:web:provider-identityhub%3A8383:api:did` → `http://provider-identityhub:8383/api/did/did.json`. `%3A` is an escaped `:` for the port. Resolution is a plain GET, and the host is a cluster-internal service name, so **these DIDs only resolve inside the cluster**. `EDC_IAM_DID_WEB_USE_HTTPS=false` tells the resolver to use `http://`.

### Keys

1. Terraform's `tls_private_key` generates an **ECDSA P-256** key pair per participant (`modules/vault`).
2. The `<p>-vault-keygen-job` writes the PEMs into Vault: `secret/<p>` (private), `secret/<p>-pub` (public), plus a random 32-byte AES key `secret/<p>-aes`. EDC 0.16 needs the AES key to encrypt participant-context config, and boot fails without it.
3. Each identity hub seeds a key pair resource (`<did>#my-key`, alias `<p>`, state ACTIVATED) and publishes the public key in its DID document as `JsonWebKey2020`.
4. The STS client secret and an API key per DID are added to Vault at seed time (`<did>-sts-client-secret`, `<did>-apikey`).

### Verifiable Credentials

JWT-encoded VC 1.0 (`VC1_0_JWT`), valid for 10 years, signed by the authority:

| Type | Subject claims | Used by |
| --- | --- | --- |
| `MembershipCredential` | `name`, `membership.membershipType`, `membership.since`, `companySegment` | `dse-policy:Membership` (every entry), `GenericClaim.$.MembershipCredential.name` |
| `DomainCredential` | `domain` | `GenericClaim` / `RestrictedDiscoveryClaim` on `.domain` |
| `VisibilityCredential` | `visibility_scope` (`ALL`) | catalog filter |

### DCP (Decentralized Claims Protocol)

Two exchanges, both detailed as diagrams in DIAGRAMS.md sections 7 and 8:

- **Issuance**: wallet → issuer `CredentialRequestMessage` (signed token); issuer → wallet `CredentialMessage` to the holder's CredentialService.
- **Presentation**: on every DSP call the caller attaches a self-issued ID token from its STS. The callee resolves the caller's DID, queries its CredentialService for a presentation of the needed credential types, checks issuer, signatures, expiry and the status list, and evaluates the policy.

---

## 12. HashiCorp Vault

### What it is

Vault stores secrets behind an API with tokens and policies. Here it is used as a simple KV store for keys and credentials, one Vault per participant (authority, provider, consumer).

### How it is configured

Helm chart `vault` 0.28.1 (Vault 1.17.2), standalone mode, with this server config:

```hcl
ui = true
listener "tcp" {
  tls_disable     = 1                 # TLS listener with the internal cert when tls_enabled
  address         = "[::]:8200"
  cluster_address = "[::]:8201"
}
storage "inmem" {}                    # ← everything lives in memory
```

The `<p>-vault-init-job` (image `hashicorp/vault`) then:

1. waits until `vault status` answers;
2. `vault operator init -key-shares=1 -key-threshold=1` (one unseal key);
3. `vault operator unseal <key>` and `vault login <root>`;
4. `vault secrets enable -path=secret kv-v2`;
5. `vault token create -id="root" -policy=root`: a **known token** the EDC runtimes use, stored in Secret `<p>-vault` key `rootToken`.

The keygen job writes the keys (section 11). The runtimes connect with `EDC_VAULT_HASHICORP_URL=http://<p>-vault:8200`, token TTL 300 s, renewal disabled, health checks on `/v1/sys/health`.

### What to watch out for

- **`storage "inmem"`**: the chart creates PVC `data-<p>-vault-0` (10Gi), but nothing is written to it. If a Vault pod restarts, Vault comes back **uninitialised and sealed** with no keys, and every runtime of that participant breaks. The init job will not rerun by itself. Recovery is `down` + `up`.
- **Root token `root`** with the root policy, used by every component and reachable through the ingress (`/<p>/vault/`).
- Inspect: `curl -H 'X-Vault-Token: root' http://localhost/provider/vault/v1/secret/metadata?list=true`.

---

## 13. PostgreSQL

### How it is deployed

A plain StatefulSet from Terraform (no chart):

| Setting | Value |
| --- | --- |
| Image | `postgres:15.3-alpine3.18` |
| Admin | `postgres` / `postgres` (Secret `postgresql`) |
| Service | `postgres:5432` (the StatefulSet's `serviceName`) |
| Config | ConfigMap `postgresql` → `postgresql.conf` (`max_connections=100`, `shared_buffers=128MB`, `listen_addresses='*'`, UTC) |
| Data dir | `PGDATA=/data/pgdata` **with no volume**: lives in the container filesystem |

### Tenancy: one database per participant

The `module db` Job (`<p>-db-init`, same Postgres image) runs `db_init.sh`:

```bash
psql … -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD'"
psql … -c "CREATE DATABASE $DB_NAME OWNER $DB_USER"
psql … -d $DB_NAME -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER"
```

The result is `authoritydb`, `providerdb`, `consumerdb` and `billingdb`, each owned by its own user (password `<p>pwd`, from the module locals) and referenced by the Secret `<p>-db-credentials`. All runtimes of a participant (control plane, data plane, identity hub, telemetry agent) share that participant's database. The authority's identity hub, issuer and federated catalog share `authoritydb`. Telemetry storage and the CSV manager use `billingdb`. `billing-db-insert` seeds `billingdb.participant_id` with one row per participant (DID, email, name). That table maps DIDs to the names that appear as `counterparty_name` in CSV reports and in the JWT role `Participant.<name>`.

This differs from the target architecture (`Architecture/database.md`: one shared server, one *schema* per participant). Here isolation is per *database*.

### What to watch out for

- Recreating `postgresql-0` **wipes every database**: no volume.
- Inspect with `kubectl exec postgresql-0 -- psql -U postgres -d providerdb -c '\dt'`, or `psql -h localhost -p 57521 -U postgres` while the port-forward runs.

---

## 14. Azure emulators: Event Hubs and Azurite

The upstream stack targets Azure. Locally, Microsoft's emulators stand in.

### Event Hubs emulator (`eventhubs-0`)

- Image `mcr.microsoft.com/azure-messaging/eventhubs-emulator:2.1.0`, `ACCEPT_EULA=Y`.
- Ports: **5672** AMQP (what the telemetry agents and the E2E consumer use) and **9092** Kafka protocol.
- Config (`eventhubs-config` → `Config.json`): one namespace with entity **`eh1`**, **2 partitions**, consumer group **`cg1`**.
- Depends on Azurite for checkpoint/metadata storage (`BLOB_SERVER`, `METADATA_SERVER` → `azurite`).
- Connection string used locally: `Endpoint=sb://…;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;`. The port-forward on `localhost:52717` makes it reachable from the host.

### Azurite (three StatefulSets)

| Instance | Role |
| --- | --- |
| `azurite-0` | Storage backend for the Event Hubs emulator |
| `azurite-report-storage-0` | Blob storage for CSV billing reports (accounts via `AZURITE_ACCOUNTS`) |
| `azurite-blobstorage-0` | Source and destination containers for the `AzureStorage-PUSH` E2E transfer (well-known `devstoreaccount1` account/key) |

Containers are created by Jobs using `mcr.microsoft.com/azure-cli:2.84.0` (`create-blob-container`, `create-blobstorage-containers`). Azurite listens on 10000 (blob), 10001 (queue), 10002 (table).

---

## 15. TLS mode (optional)

With `TLS_ENABLED=true` (the upstream default), Terraform switches the whole stack to HTTPS:

1. `tls_private_key` + `tls_self_signed_cert` create an **internal CA** (RSA 4096, 1 year).
2. A **wildcard service certificate** (RSA 2048) is signed for `*.default.svc.cluster.local`, `*.default`, `localhost` and every bare service name (`provider-controlplane`, `authority-identityhub`, `<p>-vault`…).
3. Secret `internal-service-tls` (crt, key, ca) is mounted into every runtime and every Vault. Secret `nginx-proxy-ssl-ca` (CA only) is used by nginx to verify upstreams.
4. Each EDC pod gets an **init container** that imports the CA into a Java truststore (`keytool -import … /opt/ca/cacerts`) and builds a PKCS12 keystore from the cert (`openssl pkcs12 -export`). The JVM gets `-Djavax.net.ssl.trustStore=/shared/cacerts` and `edc.web.https.keystore.*`.
5. Ingresses switch to `backend-protocol: HTTPS` with `proxy-ssl-verify: on`, `proxy-ssl-secret: default/nginx-proxy-ssl-ca`, `proxy-ssl-name: <svc>.default.svc.cluster.local`, and terminate TLS for `localhost` with the same cert.
6. `did:web` resolution uses `https://`; Vault uses its TLS listener.

The E2E tests then need `TLS_ENABLED=true` (they trust all certificates). This mode was not used for the runs in this report.

---

## 16. Networking end to end

```mermaid
graph LR
    subgraph MAC["macOS host"]
        CURL["curl http://localhost/provider/..."]
        PSQL["psql localhost:57521"]
    end
    subgraph VM["Docker Desktop VM"]
        subgraph NODE["container dse-cluster-control-plane"]
            HP["hostPort 80/443"] --> NG["ingress-nginx pod"]
            NG -->|"ClusterIP + kube-proxy"| SVC["Service provider-controlplane:8181"]
            SVC --> POD["pod 10.244.x.x:8181"]
            PGPOD["postgresql-0:5432"]
        end
    end
    CURL -->|"127.0.0.1:80 (extraPortMappings)"| HP
    PSQL -->|"kubectl port-forward (via API server)"| PGPOD
```

| From → to | Path |
| --- | --- |
| You → any API | `127.0.0.1:80` → Docker port publish → node `:80` → nginx (hostPort) → Service → Pod |
| You → Postgres / Event Hub | `kubectl port-forward` tunnels through the Kubernetes API server (`127.0.0.1:<api port>`) to the pod |
| Pod → pod | Service DNS (`provider-controlplane`), kube-proxy iptables, kindnet routing |
| Connector → connector | DSP over in-cluster service names, never through the ingress |
| Pod → internet | Allowed (NAT through the VM); used only at image-pull time for infra images |

Why nip.io does not work out of the box (Host must be `localhost`), and why exposing the ingress would not let an external connector join (DIDs and DSP URLs are internal names): see README.

---

## 17. The deployment script, step by step

`deploy-local-mvd.sh up`:

| Step | Function | What and why |
| --- | --- | --- |
| 1 | `check_prereqs` | docker, kind, kubectl, terraform, git, and a running Docker daemon. A host JDK is checked only when building on the host |
| 2 | `ensure_mvd_repo` | Use the git submodule `ging_deploy/dataspace-ecosystem` (initialised if empty, never pulled: the parent repo pins the commit). Only without the submodule does it clone into `$WORKDIR` or `git pull --ff-only` |
| 3 | `ensure_kind_cluster` | Create the cluster with the generated config (127.0.0.1 binding). If it already exists, warn when its binding differs. **Pin the kubectl context** to `kind-<name>` so nothing hits another cluster |
| 4 | `install_ingress_nginx` | Apply the kind manifest, wait for the pod to exist, then `kubectl wait` for ready |
| 5 | `build_and_load_images` | Containerised Gradle build, then retag each image as `localhost/` and `kind load` both names. The image list matches exactly what Terraform references |
| 6 | `run_terraform_apply` | `init`, `destroy`, `apply` with the same `-var`s, logged to `~/deploytour-local/logs/` |
| 7 | `wait_for_pods` | Poll until every pod is `Completed` or `Running` with all containers ready (the READY column `x/x`), or time out after `POD_WAIT_TIMEOUT` |
| 8 | `start_port_forwards` | Background `kubectl port-forward` for Postgres and Event Hub; PIDs in `.pf/`; check they are still alive after 3 s |
| 9 | optional | E2E tests (`RUN_E2E_TESTS=true`), Dataspace_UI (`START_UI=true`) |
| 10 | `cmd_status` | Pods grouped by authority / provider / consumer / shared infra / problems |

`down`: stop the port-forwards, `terraform destroy`, `kind delete cluster`. Repos, logs, the JDK and Docker images stay.

Every knob is in `rc.sh`: `WORKDIR`, `KIND_CLUSTER_NAME`, `KIND_LISTEN_ADDRESS`, `TLS_ENABLED`, `BUILD_IN_CONTAINER`, `GRADLE_BUILD_IMAGE`, `RUN_E2E_TESTS`, `START_UI`, `UI_ROLE`, ports, `POD_WAIT_TIMEOUT`, `JAVA_HOME`.

---

## 18. Lifecycle: what survives what

| Event | Postgres data | Vault keys | Credentials / agreements | Images | Need to |
| --- | --- | --- | --- | --- | --- |
| EDC pod restart | kept | kept | kept | kept | nothing |
| `postgresql-0` restart | **lost** | kept | **lost** | kept | `down` + `up` |
| `<p>-vault-0` restart | kept | **lost** (inmem) | unusable | kept | `down` + `up` |
| Docker Desktop restart | kind node restarts: **everything above is lost** | | | kept in node | `down` + `up` |
| `up` again | wiped (Terraform destroy) | wiped | wiped | rebuilt | — |
| `down` | gone | gone | gone | kept on host | — |

One more lifecycle rule: **the E2E suite runs once per deployment**. It seeds fixed ids and consumes Event Hub from the start.

---

## 19. Security posture

This environment is a throwaway testbed. These findings were verified while writing this report:

| # | Finding | Impact |
| --- | --- | --- |
| 1 | Management, Identity and Issuer-admin APIs have **no authentication** (a wrong `x-api-key` still gets 200) | Anyone who reaches the ingress controls every participant |
| 2 | Vault root token is **`root`**, Vault is exposed via the ingress | Every key readable |
| 3 | Upstream kind config binds **0.0.0.0:80/443** | LAN exposure; the script now binds 127.0.0.1 |
| 4 | CSV manager **does not verify the JWT signature** (role claim only) | Any participant's billing report readable |
| 5 | `terraform.tfstate` holds private keys and passwords in plain text | Do not share or commit it |
| 6 | DB passwords are derived from names (`<p>pwd`); Postgres admin is `postgres/postgres` | — |
| 7 | Emulator keys are the public well-known ones (Azurite, Event Hubs) | — |
| 8 | Unpinned inputs: `centos:latest`, ingress-nginx `main`, kubernetes provider | Non-reproducible builds |
| 9 | No resource limits | One runaway JVM can starve the node |

---

## 20. Local vs. devbox (AWS) vs. target architecture

| Topic | Local (this) | Devbox (`MVD-Deployment-Dev/`) | Target (`Architecture/`) |
| --- | --- | --- | --- |
| Cluster | kind, 1 node, laptop | kubeadm-style 2 VMs (master/worker) on OpenStack, Calico VXLAN | Kubernetes with ArgoCD |
| Images | built locally, `localhost/`, `Never` | GHCR `ghcr.io/deploytour/*:<version>`, pull secret | registry |
| Deploy | script → Terraform | GitHub Actions → SSH → `redeploy_devbox_terraform.sh` (Terraform with `image_tag`) | GitOps (ArgoCD) |
| Namespaces | all in `default` | `default` | `operator`, `tools`, `participant-edc-<name>`, `argocd` |
| Vault | 1 per participant, in-cluster, inmem | in-cluster | **1 external Vault**, one secret engine per tenant, Kubernetes auth |
| DB | 1 server, DB per tenant, ephemeral | same | 1 server, **schema** per tenant |
| IdP / portal | none | none | Keycloak, onboarding portal + backend |
| Recovery | `down` + `up` | runbook: scale to 0, base first, recreate jobs, `restart_devbox.sh` | — |

The devbox runbooks deal with the same weak points described in this report (jobs that must be recreated, Vault-dependent keygen, Alpine `sh` vs `bash` in `db_init.sh`).

---

## 21. Troubleshooting cookbook

| Symptom | Cause | Fix |
| --- | --- | --- |
| Pods `ErrImageNeverPull` | Image missing in the node, or not tagged `localhost/` | `docker exec dse-cluster-control-plane crictl images`; retag and `kind load` |
| `telemetry-storage`/`telemetry-csv-manager` "not built" | Older docs list them with a `-postgresql-hashicorpvault` suffix | Use the names Terraform references (`grep '"localhost/' system-tests/modules`) |
| `Cannot find a Java installation … languageVersion=17` | Build needs a JDK 17 toolchain | Build in `eclipse-temurin:17-jdk` (default) or install a JDK 17 |
| `./gradlew loadToKind` fails | It is the Podman flow | Use `dockerize` + `kind load` |
| Requests to `http://127.0.0.1/...` or nip.io return 404 | Ingress host is `localhost` | Use `http://localhost` or `-H 'Host: localhost'` |
| Credential issuance stuck APPROVED → ERRORED, empty cause | Request descriptor used `credentialType` | Use `{"format","type","id"}` |
| Negotiation 400 "expected odrl Offer" | JSON-LD context lacks ODRL | Use `https://w3id.org/edc/connector/management/v0.0.1` context |
| Data gateway returns HTML 500 | Missing `Contract-Id` header | Send `Authorization` **and** `Contract-Id` |
| Retirement returns 404 | Used the consumer's agreement id | Use the provider's id (via `correlationId`) |
| Every runtime of a participant fails after a while | Vault pod restarted (inmem) | `down` + `up` |
| Second E2E run fails | State from the first run | `down` + `up` |
| zsh: `$i:latest` becomes `$iatest` | zsh `:l` modifier | Write `${i}:latest` |
| Pods OOMKilled / node slow | 7.7 GiB shared with other containers | Stop other containers, raise Docker Desktop memory |

---

# Part II — Where every configuration comes from

Part I described what runs and how it is configured. This part answers a different question: **for each piece of configuration that ends up in a pod, which file produced it, and through which steps.** Every running object can be traced back to one of four sources:

| Source | Lives in | Examples |
| --- | --- | --- |
| **This repo** (`ging_deploy/`) | `rc.sh`, `deploy-local-mvd.sh` | cluster name, listen address, TLS on/off, build image, ports of the port-forwards |
| **Upstream repo** (git submodule `ging_deploy/dataspace-ecosystem`, pinned to `e0c5200`) | `system-tests/*.tf`, `charts/*`, `launchers/*/Dockerfile`, `build.gradle.kts`, `gradle.properties` | every Kubernetes object, every EDC setting, every image |
| **Third parties, fetched at deploy time** | the ingress-nginx manifest URL, the HashiCorp Helm repo, public images (`postgres`, `hashicorp/vault`, `mcr.microsoft.com/*`) | ingress controller, Vault chart, infra images |
| **Runtime, through APIs** (not configuration at all) | the issuer admin API, Management APIs, Vault API, the E2E suite | holders, attestations, credentials, assets, some Vault secrets |

The last row is easy to forget: a fresh deployment is mostly empty, and much of what you see in a working dataspace was **written by API calls**, not by any file (section 27).

---

## 22. The configuration chain

```mermaid
flowchart TB
    RC["ging_deploy/rc.sh<br/>(exported env vars)"] --> SH["deploy-local-mvd.sh"]
    SH -->|"writes $WORKDIR/kind.config.yaml"| KIND["kind create cluster"]
    SH -->|"kubectl apply URL"| ING["ingress-nginx manifest (upstream)"]
    SH -->|"docker run eclipse-temurin:17-jdk"| GR["gradle: build.gradle.kts + gradle.properties + launchers/*/build.gradle.kts"]
    GR --> DF["launchers/*/Dockerfile<br/>(base image, JRE, ENV WEB_HTTP_* ports, CMD)"]
    DF --> IMG["images &lt;name&gt;:latest → retag localhost/ → kind load"]
    SH -->|"-var environment, tls_enabled, kube_context"| VARS["system-tests/variables.tf"]
    VARS --> ROOT["system-tests/main.tf<br/>(participants list, TLS CA/cert)"]
    ROOT --> MODS["system-tests/modules/*/<br/>locals: names, DIDs, URLs, image refs, aliases, passwords"]
    MODS -->|"kubernetes_* resources"| K8S1["Secrets, ConfigMaps, StatefulSets,<br/>Jobs, Services, Vault Ingress"]
    MODS -->|"helm_release values = yamlencode({...})"| HV["Helm values"]
    CHV["charts/&lt;chart&gt;/values.yaml<br/>(defaults: probes, endpoints, resources)"] --> MERGE
    HV --> MERGE["Helm merge: Terraform values override chart defaults"]
    MERGE --> TPL["charts/&lt;chart&gt;/templates/<br/>_helpers.tpl · deployment.yaml · config.yaml · service.yaml · ingress.yaml"]
    TPL --> K8S2["Deployment (env vars, probes)<br/>ConfigMap &lt;release&gt;-config<br/>Service · Ingress"]
    K8S2 --> POD["container"]
    IMG --> POD
    K8S1 --> POD
    POD --> EDC["EDC settings resolved from:<br/>/app/config.properties ← EDC_FS_CONFIG<br/>environment (EDC_*, WEB_HTTP_* from Dockerfile)<br/>JVM system properties"]
```

Reading the chain from the bottom up:

1. **The JVM** reads its settings from three places: the file named by `EDC_FS_CONFIG` (`/app/config.properties`), environment variables, and system properties. Environment variables include the `WEB_HTTP_*` defaults baked into the image.
2. **The container** gets its environment from the Deployment, and `/app/config.properties`, `logging.properties` and `opentelemetry.properties` from the ConfigMap `<release>-config`, mounted under `/app`.
3. **The Deployment and ConfigMap** are rendered by the chart's templates from the merged values.
4. **The values** are chart defaults (`values.yaml`) overridden by what Terraform passes in `helm_release.values`, built in HCL and serialised with `yamlencode`.
5. **Terraform** computes those values from module `locals` (naming conventions, DIDs, URLs) and variables (`environment`, `tls_enabled`, names).
6. **The script** decides the Terraform variables, the kind config and the build, from `rc.sh`.

Things that skip Helm entirely (Postgres, Vault init and keygen jobs, the Vault ingress, Event Hubs, Azurite, the provider backend, database jobs) are `kubernetes_*` resources written directly in the Terraform modules.

**One trap in this chain: ports.** The port each EDC runtime listens on comes **only** from `ENV WEB_HTTP_<CONTEXT>_PORT` in its Dockerfile. The chart's `endpoints.*.port` values feed the `containerPort`, the Service, the probes and the Ingress, but no chart template passes them to the JVM (there is no `WEB_HTTP_*` in any `deployment.yaml`). Changing a port therefore means changing both places (recipe 31.6).

---

## 23. Inventory of source files

### This repo (`ging_deploy/`)

| File | Produces |
| --- | --- |
| `rc.sh` | Exported variables: `WORKDIR`, repo URLs, `KIND_CLUSTER_NAME`, `KIND_LISTEN_ADDRESS`, `TLS_ENABLED`, `BUILD_IN_CONTAINER`, `GRADLE_BUILD_IMAGE`, `RUN_E2E_TESTS`, `START_UI`, `UI_ROLE`, port-forward ports, `POD_WAIT_TIMEOUT`, `JAVA_HOME` |
| `deploy-local-mvd.sh` | `$WORKDIR/kind.config.yaml` (generated each time a cluster is created), the image list for retag/load, the Terraform `-var`s, port-forwards, logs in `$WORKDIR/logs/` |
| `tutorial/dataspace.py` | Not deployment config: helper constants for the notebooks (base URL, contexts) |

### Upstream repo (`dataspace-ecosystem`, commit `e0c5200`)

**Build**

| File | Produces |
| --- | --- |
| `settings.gradle.kts` | The list of Gradle projects: every launcher (`launchers/<component>/<component>-base`, `-postgresql-hashicorpvault`, `-postgresql-azurevault`), every extension, the system tests |
| `build.gradle.kts` (root) | Plugin versions (shadow 8.1.1, bmuschko docker 9.3.4, edc-build 1.1.5), and for every launcher with a Dockerfile the tasks `dockerize`, `podmanize`, `loadToKind`, `downloadOtel`/`copyOtel` and their build args |
| `gradle.properties` | `version=0.16.0`, `edcGradlePluginsVersion=1.1.5`, `vaultType=hashicorp`, `registryUrl=quay.io/centos`, `baseImage=centos:latest`, `installJava=true` |
| `gradle/libs.versions.toml` | Library versions: `edc = 0.16.1`, `edc-ih/edc-is/edc-fc = 0.16.0`, Jetty, Jackson, BouncyCastle… |
| `launchers/<c>/<c>-base/build.gradle.kts` | **What a runtime contains**. For the control plane: DSE extensions (participant-context-config-seed, policies, odrl-policy-did-validation, agreements, metrics, asset-custom-property-subscriber, asset-property-lookup, control-plane-federated-catalog-filter, contract-validation), the secrets API, the EDC connector bundle and control-plane BOM, DSP |
| `launchers/<c>/<c>-postgresql-hashicorpvault/build.gradle.kts` | Adds the SQL stores (`edc.controlplane.sql.bom`), the HashiCorp Vault client (`edc.ext.vault.hashicorp`), and DSE SQL stores (for example `retirement-evaluation-store-sql`) on top of the base |
| `launchers/<c>/<c>-postgresql-hashicorpvault/Dockerfile` | Base image, JRE 21, openssl, user 1000, the jar, the OpenTelemetry agent, **`ENV WEB_HTTP_*` (listening ports and paths)**, `CMD java …` |
| `system-tests/backend-service-provider/` | The sample backend: its own Gradle project, Dockerfile and three Java classes |

**Terraform (`system-tests/`)**

| File | Lines | Produces |
| --- | --- | --- |
| `providers.tf` | 29 | Provider requirements and configuration (kubeconfig path + context) |
| `variables.tf` | 114 | Root variables: names, `kube_context`, `environment`, Azurite keys, devbox registry, Kafka-proxy auth, `tls_enabled`, `vault_folder` |
| `main.tf` | 227 | `local.participants = [provider, consumer]`; TLS CA, wildcard certificate and the two TLS Secrets (only with TLS); calls to every module |
| `kind.config.yaml` | 17 | The upstream kind config. Not used by the script, which writes its own with `listenAddress` |
| `modules/postgres/main.tf` + `config/postgresql.conf` | 173 | Secret `postgresql`, ConfigMap `postgresql`, StatefulSet `postgresql`, Service `postgres` |
| `modules/db/main.tf` + `db_init.sh` | 112 | ConfigMap `<user>-db-init` (the script) and Job `<user>-db-init`: one user + one database |
| `modules/vault/main.tf` | 368 | Helm release `<p>-vault`, Secret `<p>-vault` (root token), Ingress `<p>-vault-ingress`, Jobs `<p>-vault-init-job` and `<p>-vault-keygen-job`, the participant key pair (`tls_private_key`) |
| `modules/participant/main.tf` | 70 | Shared locals (aliases, DB name/user/password, `authority_did`, pull policy, scheme, TLS helpers), keystore Secret, calls to `db` and `vault`, Secret `<p>-db-credentials` |
| `modules/participant/controlplane.tf` | 193 | Helm release `<p>-controlplane` and the DSP URLs |
| `modules/participant/dataplane.tf` | 175 | Helm release `<p>-dataplane`, public URL, data plane selector URL |
| `modules/participant/identityhub.tf` | 195 | Helm release `<p>-identityhub`: DID, STS URL and client secret alias, **the services published in the DID document** |
| `modules/participant/telemetryagent.tf` | 169 | Helm release `<p>-telemetryagent`, Event Hub namespace/name (hardcoded) |
| `modules/participant/variables.tf` | 194 | Participant defaults: state machine waits (negotiation 2000 ms, transfer 2000 ms, policy monitor 5000 ms, data plane 5000 ms), DSE prefixes (`dse`, `dse-policy`), keystore password `changeit`, `selfhosted_*` overrides |
| `modules/participant/standalone-providers.tf.disabled` | 27 | Disabled: providers for deploying a single participant against an existing cluster |
| `modules/authority/main.tf` | 96 | Authority locals, the `db` module twice (`authoritydb`, `billingdb`), the `eventhub` module, DB credential Secrets |
| `modules/authority/identityhub.tf` | 210 | Helm release `authority-identityhub` and **the five services of the authority DID** |
| `modules/authority/issuerservice.tf` | 174 | Helm release `authority-issuerservice`, `domain: "route"`, status list callback |
| `modules/authority/catalog.tf` | 168 | Helm release `authority-federatedcatalog`, crawler `initial_delay = 10`, `execution_period = 10` |
| `modules/authority/federatedcatalogfilter.tf` | 158 | Helm release `authority-federatedcatalogfilter`, filter URL |
| `modules/authority/telemetryservice.tf` | 162 | Helm release `authority-telemetryservice`, `connection_string_alias = "event-hub-connection-string"` |
| `modules/authority/telemetrystorage.tf` | 231 | Helm release `authority-telemetrystorage`, ConfigMap `billing-db-insert-script` (from `insert_rows.sh`), Job `billing-db-insert` |
| `modules/authority/telemetrycsvmanager.tf` | 135 | Helm release `authority-telemetrycsvmanager`, Azurite connection string, container `reports` |
| `modules/authority/insert_rows.sh` | 8 | Two hardcoded rows in `billingdb.participant_id` (provider, consumer) |
| `modules/authority/registry.tf` | 111 | **Entirely commented out**: a former nginx "participants registry". Dead code |
| `modules/authority/eventhub/eventhub.tf` | — | ConfigMap `eventhubs-config` (`Config.json`), StatefulSet + Service `eventhubs` (emulator 2.1.0) |
| `modules/authority/eventhub/azurite.tf` | — | StatefulSets + Services `azurite`, `azurite-report-storage` (Azurite 3.35.0), Job `create-blob-container` |
| `modules/azurite-blobstorage/main.tf` | 176 | StatefulSet + Service `azurite-blobstorage`, Job `create-blobstorage-containers` |
| `modules/backend-service/main.tf` | 79 | Deployment + Service `provider-backend` |

**Helm charts (`charts/`)**

Every EDC chart has the same layout: `Chart.yaml`, `values.yaml` (defaults), `templates/_helpers.tpl` (naming, URLs, image repository, secret names, `configProperties`), `deployment.yaml` (env vars, probes, volumes, init containers), `config.yaml` (the ConfigMap), `service.yaml`, `ingress.yaml`, `hpa.yaml`, `serviceaccount.yaml`, `NOTES.txt` and `tests/`.

| Chart | Notes |
| --- | --- |
| `control-plane`, `data-plane`, `identity-hub`, `issuer-service`, `federated-catalog`, `federated-catalog-filter`, `telemetry-service`, `telemetry-storage`, `telemetry-csv-manager` | Standard layout |
| `telemetry-agent` | **No `ingress.yaml`**, which is why the agents have no Ingress even though Terraform passes ingress values |
| `participant` | Only `routes.yaml` + `NOTES.txt`: an umbrella not used by the local Terraform |
| `telemetry/` | Elasticsearch-based telemetry stack, not used locally |

### Third parties

| What | Where it comes from | Pinned? |
| --- | --- | --- |
| ingress-nginx | `https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml` (script) | No (`main`) |
| Vault chart | `https://helm.releases.hashicorp.com`, chart `vault` `v0.28.1` (`modules/vault/main.tf`) | Yes |
| Vault image (server + jobs) | chart default `hashicorp/vault:1.17.2`; the jobs use `hashicorp/vault` (latest) | Server yes, jobs no |
| Postgres | `postgres:15.3-alpine3.18` (`modules/postgres`, `modules/db`) | Yes |
| Event Hubs emulator | `mcr.microsoft.com/azure-messaging/eventhubs-emulator:2.1.0` | Yes |
| Azurite | `mcr.microsoft.com/azure-storage/azurite:3.35.0` | Yes |
| Azure CLI (container jobs) | `mcr.microsoft.com/azure-cli:2.84.0` | Yes |
| Base image of every EDC image | `quay.io/centos/centos:latest` (`gradle.properties`) | No |
| kind node | `kindest/node:v1.33.1` (kind v0.29 default) | By kind version |
| Build JDK | `eclipse-temurin:17-jdk` (`rc.sh`) | Major only |

---

## 24. Tracing values end to end

Nine values, followed from the pod back to the line that created them.

### 24.1 `EDC_PARTICIPANT_ID` of `provider-controlplane`

```
pod env EDC_PARTICIPANT_ID = did:web:provider-identityhub%3A8383:api:did
  ← charts/control-plane/templates/deployment.yaml      value: {{ include "dse.controlplane.identityHubDidWebUrl" . }}
  ← charts/control-plane/templates/_helpers.tpl          .Values.controlplane.did.web.url (or global.identityHub.didWebUrl)
  ← modules/participant/controlplane.tf                  "did": {"web": {"url": local.did_url}}
  ← modules/participant/identityhub.tf                   local.did_url = "did:web:${local.identityhub_release_name}%3A8383:api:did"
  ← modules/participant/identityhub.tf                   local.identityhub_release_name = "${var.participant_name}-identityhub"
  ← system-tests/main.tf                                 participant_name = each.key  (for_each over local.participants)
  ← system-tests/variables.tf                            provider_name default = "provider"
```

The `8383` in the DID is a literal in `identityhub.tf`. It must match the identity hub's DID port, which comes from its Dockerfile (`ENV WEB_HTTP_DID_PORT="8383"`), and the E2E tests hardcode it again (`ParticipantConstants.IDENTITY_HUB_DID_PORT = 8383`).

### 24.2 `EDC_DSP_CALLBACK_ADDRESS` (where the other connector sends its DSP replies)

```
pod env EDC_DSP_CALLBACK_ADDRESS = http://provider-controlplane:8282/api/dsp
  ← deployment.yaml  {{ include "dse.controlplane.url.protocol" . }}
  ← _helpers.tpl     uses .Values.controlplane.url.protocol if set; otherwise builds it from the ingress hostname
  ← controlplane.tf  "url": {"protocol": local.protocol_callback_url}
  ← controlplane.tf  local.protocol_callback_url = "${local.scheme}://${local.controlplane_release_name}:8282/api/dsp"
  ← participant/main.tf  local.scheme = var.tls_enabled ? "https" : "http"
```

Terraform sets `url.protocol` explicitly to the **in-cluster** name, which is why DSP never goes through the ingress (with the comment "*In the case of this MVD we use internal routes for simplicity*"). If `url.protocol` were left empty, the helper would derive it from the ingress hostname (`localhost`), which would not work between pods.

### 24.3 The provider's private key

```
Terraform: modules/vault/main.tf  resource "tls_private_key" "key-pair" { algorithm = "ECDSA", ecdsa_curve = "P256" }
  → Terraform state (system-tests/terraform.tfstate) — the PEM is stored there in clear
  → modules/vault/main.tf  kubernetes_job "vault-keygen-job": the PEM is inlined into the job's shell command:
        vault kv put secret/provider     content="<private PEM>"
        vault kv put secret/provider-pub content="<public PEM>"
        vault kv put secret/provider-aes content="<random 32 bytes, base64>"
  → Vault (in memory) at secret/provider, secret/provider-pub, secret/provider-aes
Consumers, by alias:
  identity hub   keys.sts.privateKeyAlias = local.privatekey_alias ("provider")       ← identityhub.tf
                 → key pair resource did:...#my-key, published in the DID document
  data plane     keys.dataplane.privateKeyVaultAlias = "provider" (EDR token signer)  ← dataplane.tf
                 → env EDC_TRANSFER_PROXY_TOKEN_SIGNER_PRIVATEKEY_ALIAS=provider
                 publicKeyVaultAlias = "provider-pub"  → …VERIFIER_PUBLICKEY_ALIAS=provider-pub
  every runtime  EDC_ENCRYPTION_AES_KEY_ALIAS = "provider-aes"
```

The PEM is also visible in the job's pod spec (`kubectl get job provider-vault-keygen-job -o yaml`) until the job is deleted, one hour after completion.

### 24.4 The Vault token every runtime uses

```
modules/vault/main.tf   local.vault_token = "root"
  → kubernetes_secret "<p>-vault"  data = { rootToken = "root" }
  → kubernetes_job "<p>-vault-init-job":  vault token create -id="root" -policy=root
                                          (after operator init + unseal + kv-v2 enable)
  → module output vault_secret_name / vault_url
  → controlplane.tf  "vault": {"hashicorp": {"url": module.vault.vault_url,
                     "token": {"secret": {"name": module.vault.vault_secret_name, "tokenKey": "rootToken"}}}}
  → deployment.yaml  EDC_VAULT_HASHICORP_TOKEN  valueFrom.secretKeyRef {name: <p>-vault, key: rootToken}
```

The init job creates a token **with a known id**. That way the Secret written by Terraform before Vault even exists already holds a valid token by the time the runtimes start.

### 24.5 Database credentials

```
participant/main.tf   local.db_name = "${participant}db", db_user = participant, db_user_password = "${participant}pwd"
  → module "db": Job <p>-db-init, env DB_USER/DB_NAME/DB_PASSWORD + admin creds from Secret "postgresql"
        → db_init.sh: CREATE USER …; CREATE DATABASE … OWNER …; GRANT …
  → kubernetes_secret "<p>-db-credentials" { username, password }
  → controlplane.tf "postgresql": {"jdbcUrl": "jdbc:postgresql://postgres/<p>db", "credentials": {"secret": {"name": "<p>-db-credentials"}}}
  → deployment.yaml EDC_DATASOURCE_DEFAULT_URL / _USER / _PASSWORD (secretKeyRef)
  → EDC_SQL_SCHEMA_AUTOCREATE=true: each SQL store runs its CREATE TABLE IF NOT EXISTS on boot
```

The admin password `postgres` comes from `modules/postgres/main.tf` (`local.pg_password`).

### 24.6 The services in a DID document

```
GET /provider/ih/did/did.json → service: [DSPMessaging, CredentialService]
  ← identity hub runtime: DID document stored in did_resources (providerdb) and served on :8383/api/did
  ← super-user seed extension (extensions/identity-hub/superuser-seed): at boot, creates the participant context
     with the configured key + services and publishes the DID
  ← chart identity-hub: values identityhub.participantcontext.superuser.services → setting read by the seed
  ← modules/participant/identityhub.tf:
        "participantcontext": {"superuser": {"key": "<did base64url>.root",
          "services": jsonencode([{id: "dsp-url", type: "DSPMessaging", serviceEndpoint: local.protocol_url},
                                  {id: "credential-service-url", type: "CredentialService", serviceEndpoint: ".../api/credentials/v1/participants/<b64>"}])}}
```

The authority's five services (`CredentialService`, `IssuerService`, `TelemetryServiceCredential`, `FederatedCatalogFilterService`, `FederatedCatalogService`) come from the same block in `modules/authority/identityhub.tf`. That is how other runtimes **discover** the issuer, the catalog filter and the telemetry service: by resolving the authority DID, not through a configured URL.

### 24.7 The ingress route `/provider/cp/management`

```
nginx rule: host localhost, path /provider/cp/(management)(.*) → provider-controlplane:8181, rewrite /api/$1$2
  ← charts/control-plane/templates/ingress.yaml   rules[0].host = .hostname; paths from .endpoints; service = fullname
  ← controlplane.tf "ingress": {"enabled": true, "className": "nginx", "hostname": "localhost",
        "annotations": {... "rewrite-target": "/api/$1$2", "use-regex": "true", backend-protocol …},
        "endpoints": [{"port": 8181, "path": "${var.participant_with_prefix}/cp/(management)(.*)"}, …]}
  ← main.tf  participant_with_prefix = "/${each.key}"
```

The Vault routes do not come from a chart: `modules/vault/main.tf`, resource `kubernetes_ingress_v1.vault-ingress`, path `/<p>/vault(/|$)(.*)`, rewrite `/$2`.

### 24.8 Who the federated catalog crawls

```
crawler targets ← participant-registry-node-directory extension: holderStore.query(QuerySpec.max())
                ← table of holders in authoritydb
                ← written by POST /authority/is/issueradmin/.../holders   (flow A2, an API call)
crawl timing    ← catalog.tf locals crawler_initial_delay = 10, crawler_execution_period = 10
                → env EDC_CATALOG_CACHE_EXECUTION_DELAY_SECONDS / _PERIOD_SECONDS, EDC_CATALOG_CACHE_LOADER_BATCH_SIZE=1
```

The crawl **list** is not configuration. Until someone registers holders, the federated catalog crawls nobody.

### 24.9 The trusted issuer of a participant

```
config.properties  edc.iam.trusted-issuer.authority.id = did:web:authority-identityhub%3A8383:api:did
  ← chart control-plane _helpers.tpl "dse.controlplane.configProperties":  edc.iam.trusted-issuer.authority.id={{ authorityDid }}
  ← controlplane.tf "trustedIssuers": {"authority": {"did": local.authority_did}}   (and the same line again in its "config" heredoc)
  ← participant/main.tf  local.authority_did = var.selfhosted_authority_did != "" ? … : replace(local.did_url, var.participant_name, "authority")
```

The authority DID is computed by **string replacement** on the participant's own DID (`provider` → `authority`). That works only because of the naming convention. A participant named, say, `providerx` would get `authorityx`, because `replace` substitutes every occurrence. The `selfhosted_authority_did` variable exists to override it.

---

## 25. Provenance by component

For each runtime: its Terraform file, its chart, and where its notable settings come from. `<p>` = provider or consumer.

| Runtime | Terraform | Chart | Image (local) | Notable settings and their origin |
| --- | --- | --- | --- | --- |
| `<p>-controlplane` | `participant/controlplane.tf` | `control-plane` | `localhost/control-plane-postgresql-hashicorpvault` | DSP callback (24.2), STS client (`sts.tokenUrl/clientId/clientSecretAlias` from `identityhub.tf` locals), trusted issuer (24.9), state machine waits (`participant/variables.tf`), DSE prefixes, logging DEBUG |
| `<p>-dataplane` | `participant/dataplane.tf` | `data-plane` | `localhost/data-plane-postgresql-hashicorpvault` | `public_url = http://<p>-dataplane:8181/api/public/`, `dpf_selector_url = http://<p>-controlplane:8383/api/control/v1/dataplanes`, token signer/verifier aliases (24.3), state machine 5000 ms, logging INFO |
| `<p>-identityhub` | `participant/identityhub.tf` | `identity-hub` | `localhost/identity-hub-postgresql-hashicorpvault` | DID (24.1), STS keys, super-user context and services (24.6), credentials URL |
| `<p>-telemetryagent` | `participant/telemetryagent.tf` | `telemetry-agent` | `localhost/telemetry-agent-postgresql-hashicorpvault` | Event Hub `local-eventhub-eventhubs`/`eh1` (hardcoded locals), authority DID, STS client, logging INFO |
| `<p>-vault` | `vault/main.tf` | HashiCorp `vault` 0.28.1 | `hashicorp/vault:1.17.2` | Standalone, `storage "inmem"`, TLS listener only with TLS, readiness probe off |
| `authority-identityhub` | `authority/identityhub.tf` | `identity-hub` | as above | Five DID services (24.6) |
| `authority-issuerservice` | `authority/issuerservice.tf` | `issuer-service` | `localhost/issuer-service-postgresql-hashicorpvault` | `domain: "route"`, `EDC_STATUSLIST_CALLBACK_ADDRESS=http://authority-issuerservice:9999/api/statuslist`, status list signing alias `authority`, datasources `default` + `membership` on `authoritydb` |
| `authority-federatedcatalog` | `authority/catalog.tf` | `federated-catalog` | `localhost/federated-catalog-postgresql-hashicorpvault` | Crawler timing (24.8) |
| `authority-federatedcatalogfilter` | `authority/federatedcatalogfilter.tf` | `federated-catalog-filter` | `localhost/federated-catalog-filter-postgresql-hashicorpvault` | `filter_url = http://authority-federatedcatalogfilter.default.svc.cluster.local:8383/api/catalogfilter/filter`, trusted issuer |
| `authority-telemetryservice` | `authority/telemetryservice.tf` | `telemetry-service` | `localhost/telemetry-service-postgresql-hashicorpvault` | `eventhub.connectionstring.alias = event-hub-connection-string` (value: section 27) |
| `authority-telemetrystorage` | `authority/telemetrystorage.tf` | `telemetry-storage` | `localhost/telemetry-storage` | Datasources on `billingdb`; job `billing-db-insert` after the release |
| `authority-telemetrycsvmanager` | `authority/telemetrycsvmanager.tf` | `telemetry-csv-manager` | `localhost/telemetry-csv-manager` | Blob connection string `…AccountName=user;AccountKey=pass;BlobEndpoint=http://azurite-report-storage:10000/user;`, container `reports`, **no JWT verification setting** |
| `provider-backend` | `backend-service/main.tf` | none | `localhost/backend-service-provider` | Port 8080, liveness `/api/check/liveness` |
| `postgresql` | `postgres/main.tf` | none | `postgres:15.3-alpine3.18` | `postgresql.conf` from `postgres/config/`, admin creds in Secret `postgresql`, no volume |
| `eventhubs` | `authority/eventhub/eventhub.tf` | none | emulator 2.1.0 | `Config.json` inline in the ConfigMap; blob/metadata on `azurite` |
| `azurite`, `azurite-report-storage` | `authority/eventhub/azurite.tf` | none | Azurite 3.35.0 | Accounts `user`/`pass` (root `variables.tf`) |
| `azurite-blobstorage` | `azurite-blobstorage/main.tf` | none | Azurite | Well-known `devstoreaccount1` key (root `variables.tf`) |

---

## 26. Secrets and keys: who creates what

### Kubernetes Secrets

| Secret | Created by | Content | Used by |
| --- | --- | --- | --- |
| `postgresql` | `postgres/main.tf` | `POSTGRES_USER=postgres`, `POSTGRES_PASSWORD=postgres`, `POSTGRES_DB=postgres` | Postgres container, every db-init job, `billing-db-insert` |
| `<p>-db-credentials`, `authority-db-credentials` | `participant/main.tf`, `authority/main.tf` | `username=<p>`, `password=<p>pwd` | `EDC_DATASOURCE_DEFAULT_USER/PASSWORD` of every runtime of that participant |
| `billinguser-db-credentials` | `authority/main.tf` | `billinguser` / `authoritypwd` | telemetry storage, CSV manager |
| `<p>-vault` | `vault/main.tf` | `rootToken=root` | `EDC_VAULT_HASHICORP_TOKEN` of every runtime of that participant |
| `internal-service-tls`, `nginx-proxy-ssl-ca` | `main.tf` (TLS only) | wildcard cert + key + CA / CA only | runtimes, Vaults, nginx |
| `<p>-internal-keystore-credentials` | `participant/main.tf`, `authority/main.tf` (TLS only) | `password=changeit` | `EDC_WEB_HTTPS_KEYSTORE_PASSWORD` |
| `sh.helm.release.v1.<release>.v1` | Helm | the release (values, manifest) | `helm get`, upgrades |

### Vault keys (per participant, `secret/` KV v2)

| Key | Created by | When |
| --- | --- | --- |
| `<p>`, `<p>-pub` | `vault-keygen-job` (PEM from Terraform `tls_private_key`) | deploy |
| `<p>-aes` | `vault-keygen-job` (`head -c 32 /dev/urandom`) | deploy |
| `<did>-sts-client-secret`, `<did>-apikey` | the identity hub, while seeding the super-user participant context | first boot of the identity hub |
| `transfer-process-<id>-data-address` (provider) | the provider control plane, per transfer | each transfer |
| `oauth-secret`, `devstoreaccount1`, `devstoreaccount1-key1` | E2E suite, through `POST /v3/secrets` | E2E run |
| `event-hub-connection-string` (authority) | E2E suite, directly on the Vault API | E2E run |

---

## 27. What the deployment does not create

After `up`, these things **do not exist** until an API call creates them. The notebooks, the Postman collection and the E2E suite are what create them:

| Thing | Created by | Without it |
| --- | --- | --- |
| Holders (registered participants) | `POST …/issueradmin/…/holders` | Nobody can get credentials; **the federated catalog crawls nobody** |
| Attestation and credential definitions | `POST …/attestations`, `…/credentialdefinitions` | The issuer cannot issue anything |
| Membership / domain / visibility attestations | DSE attestation APIs | Issuance has no facts to put in the credentials |
| Verifiable Credentials | Each wallet, `…/credentials/request` | **Every policy fails**: `dse-policy:Membership` needs a MembershipCredential |
| Assets, policies, contract definitions | Provider Management API | Empty catalogs |
| `event-hub-connection-string` in the authority Vault | E2E suite (or recipe 31.9) | Telemetry agents cannot get SAS tokens |
| Backend secrets (`oauth-secret`, Azure keys) | `POST /v3/secrets` | The OAuth2 and blob assets fail |
| Telemetry events in `billingdb` | Ingestion (absent locally), the E2E `@AfterAll`, or manual `POST /telemetry-events` | Reports are empty |

What **is** created by configuration at boot: participant contexts and their DID documents (super-user seed), key pairs (identity hubs read them from Vault), the issuer's status list credential (on first issuance), database schemas (autocreate), the two `participant_id` rows in `billingdb` (`insert_rows.sh`), the blob containers (Azure CLI jobs), and the Event Hub `eh1` with its consumer group `cg1` (emulator `Config.json`).

---

## 28. Creation order

Terraform builds a dependency graph from references and explicit `depends_on`, and runs up to 10 independent resources in parallel. `helm_release` waits for its pods to be ready, and the Vault release also waits for jobs (`wait_for_jobs = true`).

```mermaid
flowchart LR
    TLS["TLS CA + certs + Secrets<br/>(only with TLS)"] --> PART
    PG["postgres: Secret, ConfigMap,<br/>StatefulSet, Service"] --> DBJ["db-init jobs<br/>(authority, billing, provider, consumer)"]
    VH["vault helm release"] --> VI["vault-init-job<br/>(init, unseal, kv-v2, token root)"]
    VI --> VK["vault-keygen-job<br/>(keys + AES)"]
    DBJ --> PART
    VK --> PART
    subgraph PART["per participant (provider, consumer)"]
        CP["controlplane"] --> DP["dataplane"]
        IH["identityhub"]
        TA["telemetryagent"]
    end
    DBJ --> AUTH
    VK --> AUTH
    subgraph AUTH["authority"]
        AIH["identityhub"]
        IS["issuerservice"]
        FC["federatedcatalog"]
        FCF["federatedcatalogfilter"]
        TS["telemetryservice"]
        TST["telemetrystorage"] --> BDI["billing-db-insert job"]
        CSV["telemetrycsvmanager"]
    end
    EH["eventhubs + azurite + azurite-report-storage"] --> CBC["create-blob-container job"]
    AZB["azurite-blobstorage"] --> CBS["create-blobstorage-containers job"]
    BE["provider-backend"]
```

Notes on the edges:

- Every EDC release `depends_on = [module.vault, module.db]`, and the data plane also waits for its control plane (it registers itself through the control plane's selector API).
- Nothing waits for the authority's identity hub before a participant starts. A connector that boots first simply fails DID resolutions until the authority is up, and recovers through retries.
- `billing-db-insert` waits for the telemetry storage release, because the release's boot creates the `participant_id` table through schema autocreate.
- Postgres, the backend and the emulators have no dependencies and start first.

---

# Part III — How it is done, and how to change it

## 29. What each command does inside

### `kind create cluster --config kind.config.yaml`

1. Pulls `kindest/node:v1.33.1` and starts it as a privileged container named `dse-cluster-control-plane`, with the configured port mappings (`127.0.0.1:80/443 → 80/443`) and a random port for the API server.
2. Inside the container, systemd starts containerd and the kubelet; `kubeadm init` runs with the config patch (the node label `ingress-ready=true`).
3. kindnet (CNI), CoreDNS, kube-proxy and the local-path provisioner are installed.
4. The kubeconfig entry `kind-dse-cluster` is written to `~/.kube/config` and made current.

### `kubectl apply -f <ingress-nginx kind manifest>`

Creates namespace `ingress-nginx`, RBAC, the admission webhook (with its two certgen jobs), the IngressClass `nginx` and the controller Deployment. Its nodeSelector (`ingress-ready=true`) and `hostPort: 80/443` pin it to the node and the host ports.

### `./gradlew clean shadowJar dockerize`

Per launcher project: `compileJava` → `jar` → `shadowJar` (merges every dependency into `build/shadow/<project>.jar`, with service files merged so all EDC extensions are discovered) → `downloadOtel` (fetches the OpenTelemetry Java agent once) → `copyOtel` → `dockerize` (`DockerBuildImage`: sends `build/` as the context to the Docker daemon with build args `JAR`, `OTEL_JAR`, `REGISTRY_URL`, `BASE_IMAGE`, `INSTALL_JAVA`, `INSTALL_OPENSSL`, and tags `<project>:latest`). In the containerised build, Docker is the **host** daemon (socket mount), so the images land on the host.

### `kind load docker-image a:latest localhost/a:latest … --name dse-cluster`

`docker save`s the images into a tar, copies it into the node and runs `ctr --namespace=k8s.io images import`. From then on the kubelet finds them locally, which is all `imagePullPolicy: Never` allows.

### `terraform init / destroy / apply`

- `init`: downloads providers into `system-tests/.terraform/` and creates `.terraform.lock.hcl`.
- `destroy`: reads the state, refreshes it against the cluster, and deletes in reverse dependency order (`|| true` in the script, because there may be nothing).
- `apply`: refresh → plan (diff of desired vs. state) → graph walk, 10 resources at a time. For `helm_release`, the Helm provider renders the chart with the merged values, stores the release Secret, applies the manifests and waits for readiness (default timeout 5 min). For `kubernetes_job`, it waits for completion if the resource says so. The result is written to `terraform.tfstate`.

### Pod start-up (an EDC runtime)

1. **Init containers** (TLS only): `keystore-setup` builds `/opt/ca/cacerts` and `keystore.p12` into a shared emptyDir.
2. **Main container** starts `java -javaagent:… -jar controlplane.jar`.
3. **Startup probe** (`/api/check/liveness`): first check after 10 s, every 10 s, up to 30 failures, so the runtime has up to about **5 minutes** to boot before Kubernetes kills it. Liveness and readiness only start after the startup probe succeeds.
4. **Liveness** every 10 s, timeout 5 s, 3 failures → restart. **Readiness** every 10 s → added to or removed from the Service endpoints, and so from nginx.

That is exactly what happened when the node was saturated: health checks that took longer than 5 s three times in a row restarted the pods (exit code 143 = SIGTERM).

## 30. How an EDC runtime boots

1. **Extension discovery**: EDC loads every `ServiceExtension` declared in the shaded jar's `META-INF/services` (that is what the launcher's dependency list decides), builds the dependency graph from `@Inject`/`@Provides`, and initialises them in order.
2. **Settings**: each extension reads its `@Setting`s through the config system (file → environment → system properties). Unknown settings are ignored, so a typo in an env var name silently does nothing.
3. **Web contexts**: for every `web.http.<context>.port/path` (from the Dockerfile `ENV`), a Jetty connector is opened. Controllers register on their context.
4. **Vault**: the HashiCorp client is configured with the URL and token; with health checks on, it calls `/v1/sys/health`.
5. **SQL**: data sources are created from `EDC_DATASOURCE_<NAME>_*`; with autocreate on, each store runs its schema script.
6. **Seeds** (identity hubs, issuer): the super-user participant context is created with its key (alias in Vault) and services, and the DID document is published. `ParticipantContextConfiguration` entries are seeded.
7. **State machines** start (negotiation, transfer, policy monitor, data plane, crawler…), each looping with its `iteration-wait-millis`.
8. `/api/check/readiness` turns healthy, and the pod becomes Ready.

## 31. Recipes

Each recipe says which file to change and how to apply it. Unless noted, apply with `./deploy-local-mvd.sh up` (full redeploy) or, for Terraform-only changes, `terraform -chdir=system-tests apply -auto-approve -var=environment=local -var=tls_enabled=false -var=kube_context=kind-dse-cluster` from the upstream repo.

### 31.1 Change one runtime's code and redeploy only that image

```bash
cd ging_deploy/dataspace-ecosystem
docker run --rm -v "$PWD":/workspace -w /workspace -v /var/run/docker.sock:/var/run/docker.sock \
  -v dse-gradle-cache:/root/.gradle eclipse-temurin:17-jdk \
  ./gradlew --no-daemon :launchers:control-plane:control-plane-postgresql-hashicorpvault:dockerize
docker tag control-plane-postgresql-hashicorpvault:latest localhost/control-plane-postgresql-hashicorpvault:latest
kind load docker-image localhost/control-plane-postgresql-hashicorpvault:latest --name dse-cluster
kubectl rollout restart deploy/provider-controlplane deploy/consumer-controlplane
```

The tag stays `latest` and the pull policy is `Never`, so a restart picks up the newly loaded image.

### 31.2 Give the runtimes memory and CPU (stops the restarts under load)

In each `helm_release` values block (for example `participant/controlplane.tf`, inside `"controlplane"`), add the values the chart's `values.yaml` already recommends:

```hcl
"resources" : { "requests" : { "cpu" : "250m", "memory" : "512Mi" }, "limits" : { "memory" : "768Mi" } }
```

Leave the CPU limit off, as the chart comment advises ("*no CPU limit to avoid JVM throttling*"). Apply with Terraform. With 16 JVMs, size Docker Desktop's memory accordingly.

### 31.3 Change log levels

Edit the `"logging" : <<EOT … EOT` heredoc of the component (`.level=INFO`, `org.eclipse.edc.level=INFO`). It becomes `logging.properties` in the ConfigMap. Apply with Terraform; the release has `recreate_pods = true`, so pods restart.

### 31.4 Add a third participant

1. `system-tests/variables.tf`: add a variable (or reuse the pattern) and append it to `local.participants` in `main.tf`.
2. TLS only: add its bare host names to `dns_names` of `tls_cert_request.internal_service`.
3. Apply. You get `<name>-controlplane`, `-dataplane`, `-identityhub`, `-telemetryagent`, `-vault`, database `<name>db` and ingress paths `/<name>/…`.
4. At runtime: register it as a holder and give it attestations and credentials (flows A2–A4).
5. Billing: add a row for it to `authority/insert_rows.sh` (provider and consumer are hardcoded there).

Avoid names that contain another participant's name (24.9).

### 31.5 Use a hostname other than `localhost` (nip.io, LAN)

Replace `"hostname" : "localhost"` in the 11 Helm values blocks and `host`/`hosts` in `modules/vault/main.tf`, either with a single name (`127.0.0.1.nip.io`) or with `""` to drop the host (TLS off only). With TLS, add the name to the certificate's `dns_names`. For LAN access also set `KIND_LISTEN_ADDRESS=0.0.0.0` and recreate the cluster (`down` + `up`). See the README section "nip.io" for the tests behind this.

### 31.6 Change a port

1. The JVM: set `WEB_HTTP_<CONTEXT>_PORT`. Either rebuild the image with a new `ENV` in the Dockerfile, or add `web.http.<context>.port=<n>` to the component's `"config"` heredoc in Terraform. That file is read by EDC, but environment variables take precedence over it, so the Dockerfile `ENV` still wins; the reliable way is an `env` entry in the values (`"env" : {"WEB_HTTP_<CONTEXT>_PORT" : "<n>"}`).
2. The chart: set the same port in `endpoints.<context>.port` (Service, containerPort, probes) and in the ingress `endpoints`.
3. URLs that embed the port: DSP URLs in `controlplane.tf`, the DID (`%3A8383`) in `identityhub.tf`, the selector URL in `dataplane.tf`, and the E2E constants.

### 31.7 Turn TLS on

Set `TLS_ENABLED=true` in `rc.sh` and run `up`. Everything switches (section 15). Call the APIs with `https://localhost` (`curl -k`, the CA is self-signed). For the E2E suite use `TLS_ENABLED=true`.

### 31.8 Make Vault and Postgres survive restarts

- **Vault**: in `modules/vault/main.tf` replace `storage "inmem" {}` with `storage "file" { path = "/vault/data" }`. The chart already mounts its `data-<p>-vault-0` PVC there. But a restarted Vault comes back **sealed**, and the init job only handles first initialisation (it exits with "Vault is initialized but sealed. Manual intervention required"). You also need to store the unseal key (the job discards it) and unseal after restarts, or configure auto-unseal.
- **Postgres**: add a `volume_claim_template` to the StatefulSet in `modules/postgres/main.tf` and mount it at `/data` (the `PGDATA` parent).

### 31.9 Let telemetry agents publish without the E2E suite

Write the Event Hub connection string the E2E suite would write into the authority Vault (value from `LocalEndToEndTests.EVENT_HUB_CONNECTION_STRING_SECRET`):

```bash
curl -s -X POST -H 'X-Vault-Token: root' -H 'Content-Type: application/json' \
  http://localhost/authority/vault/v1/secret/data/event-hub-connection-string \
  -d '{"data":{"content":"Endpoint=sb://eventhubs;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;"}}'
```

### 31.10 Change how often the federated catalog crawls

`modules/authority/catalog.tf`, locals `crawler_initial_delay` and `crawler_execution_period` (seconds). Apply with Terraform.

### 31.11 Pin what is unpinned

- Base image: `gradle.properties` `baseImage=centos:stream9` (or a digest), then rebuild.
- ingress-nginx: replace `main` in the script's URL with a release tag (`controller-v1.15.1`).
- Vault job image: `image = "hashicorp/vault:1.17.2"` in the two jobs of `modules/vault/main.tf`.
- Terraform kubernetes provider: add a `version` constraint in `providers.tf`.

### 31.12 Deploy a single participant against an existing dataspace

Rename `modules/participant/standalone-providers.tf.disabled` to `.tf`, write a `terraform.tfvars` in that folder with `participant_name`, the four image variables, `kube_context`, `kube_config_path`, `environment = "selfhosted"` and `charts_path = "../../../charts"`, then run Terraform from there. The `selfhosted_did_url`, `selfhosted_sts_url` and `selfhosted_authority_did` variables let that participant use real public URLs instead of in-cluster names (section 16).

---

## 32. Further reading

- kind: https://kind.sigs.k8s.io
- ingress-nginx: https://kubernetes.github.io/ingress-nginx/
- Helm: https://helm.sh/docs/
- Terraform: https://developer.hashicorp.com/terraform/docs
- Vault: https://developer.hashicorp.com/vault/docs
- Eclipse Dataspace Components: https://github.com/eclipse-edc
- Azure Event Hubs emulator: https://github.com/Azure/azure-event-hubs-emulator-installer
- Azurite: https://github.com/Azure/Azurite
- Upstream repository docs: `ging_deploy/dataspace-ecosystem/docs/` (architecture, billing, onboarding, developer guide)
