#!/usr/bin/env bash
# ==============================================================================
#   Zeno – full-stack installer (single VPS, fresh OS)
# ==============================================================================

set -euo pipefail
trap 'echo -e "\e[31mERROR at line $LINENO – aborting.\e[0m"' ERR
shopt -s globstar

# ───────── [ FIXED ] Define log early so it's available at startup ────────────
log(){ printf "\n\033[1;34m▶︎ %s\033[0m\n" "$*"; }

list_disks() {
  # NAME  SIZE FSTYPE MOUNTPOINT FSAVAIL
  lsblk -b -o NAME,SIZE,FSTYPE,MOUNTPOINT |
    awk 'NR>1 && $3!="" && $4!="" {printf "%s|%s|%s\n",$0,$3,$4}' |
    while IFS='|' read -r line fstype mount; do
      # query free space in human form
      avail=$(df -hP "$mount" | awk 'NR==2{print $4}')
      size=$(echo "$line" | awk '{printf "%.1fG", $2/1024/1024/1024}')
      printf "%-3s  %-8s  %-7s  %-12s  %s\n" "[$idx]" "$size" "$fstype" "$avail" "$mount"
      ((idx++))
    done
}

echo -e "\n\033[1;33mAvailable writable mounts:\033[0m"
idx=0; mapfile -t MOUNTS < <(list_disks)
printf "%s\n" "${MOUNTS[@]}"

read -rp $'\nChoose install location by index, or type a custom absolute path: ' choice

if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >=0 && choice < ${#MOUNTS[@]} )); then
  MOUNT_POINT=$(echo "${MOUNTS[$choice]}" | awk '{print $NF}')
  BASE="${MOUNT_POINT%/}/zeno"
else
  [[ "$choice" = /* ]] || { echo "Path must be absolute (start with /)"; exit 1; }
  BASE="$choice"
fi

echo -e "\n\033[1;32m→ Using BASE=${BASE}\033[0m"
mkdir -p "$BASE/models" "$BASE/models/loras"

mkdir -p "$BASE/models" "$BASE/models/loras"

# --------------------------------------------------------------------------- #
#  Copy backend/, charts/, microservices/ into the chosen BASE (if missing)   #
#  Assumes those folders sit next to this script when you launch it.          #
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

for d in backend charts microservices; do
  if [[ ! -d "${BASE}/${d}" ]]; then
    log "Copying ${d}/ → ${BASE}/${d}"
    # -r  recurse,  -T  treat DEST as a directory (avoid double nesting)
    cp -rT "${SCRIPT_DIR}/${d}" "${BASE}/${d}"
  fi
done

# sanity-check — abort early if anything is still missing
for d in backend charts microservices; do
  [[ -d "${BASE}/${d}" ]] || { echo "❌  ${BASE}/${d} missing – aborting."; exit 1; }
done


# ───────── Configurable ───────────────────────────────────────────────────────
DOMAIN="${1:-zeno.local}"
NS=zeno
REG_PORT=5000
REG="localhost:${REG_PORT}"      # registry URL used by K8s
MEM_CHART_VER="0.1.0"            # charts/memory/Chart.yaml version
PG_VER="15.2.2"                  # Bitnami PostgreSQL chart
HELM_LIMIT=20000000              # 20 MiB (Bitnami tgz < 74 KiB, but play safe)

# ───────── Helper functions ───────────────────────────────────────────────────

need_pkg(){
  dpkg -s "$1" &>/dev/null || apt-get install -y "$1"
}
append_bashrc(){
  local line="$1" file="$2"
  mkdir -p "$(dirname "$file")"
  touch    "$file"
  grep -Fqx "$line" "$file" || echo "$line" >> "$file"
}

# ───────── 0. Must be root ────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 <public-host>"; exit 1; }

# ───────── 1. System dependencies ─────────────────────────────────────────────
log "Installing base packages (Docker, k3s, Helm, build tools …)"
apt-get update -qq
for p in curl git ca-certificates gnupg lsb-release unzip yq \
         build-essential python3 python3-venv pkg-config libffi-dev libssl-dev; do
  need_pkg "$p"
done

# Docker
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker "${SUDO_USER:-root}" || true
fi
systemctl enable --now docker

# (Optional) NVIDIA driver & container-toolkit
if lspci | grep -qi nvidia; then
  need_pkg nvidia-driver-535
  need_pkg nvidia-container-toolkit
  systemctl restart docker
fi

# k3s (single-node Kubernetes)
if ! command -v k3s &>/dev/null; then
  curl -sfL https://get.k3s.io | sh -
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
append_bashrc 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' /root/.bashrc
if [[ -n "${SUDO_USER:-}" && -d /home/${SUDO_USER} ]]; then
  append_bashrc 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' "/home/${SUDO_USER}/.bashrc"
fi

# ─── Wait for k3s to expose a Ready node ──────────────────────────────
log "Waiting for Kubernetes node to become Ready (max 3 min)…"
ATTEMPTS=36             # 36 × 5 s = 180 s
until kubectl get nodes &>/dev/null; do
  ((ATTEMPTS--)) || { echo "k3s API still unreachable after 3 min"; exit 1; }
  sleep 5
done

# k3s API is reachable – now wait for Ready condition
kubectl wait --for=condition=Ready node --all --timeout=120s

# Helm
if ! command -v helm &>/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ───────── 2. Local Docker registry ───────────────────────────────────────────
log "Starting local Docker registry on ${REG}"
docker rm -f zeno-registry 2>/dev/null || true
docker run -d --restart=always -p ${REG_PORT}:5000 --name zeno-registry registry:2

# Tell k3s about the local mirror
mkdir -p /etc/rancher/k3s
cat >/etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "${REG}":
    endpoint:
      - "http://${REG}"
EOF
systemctl restart k3s
sleep 5

# ───────── 3. Folder scaffold ────────────────────────────────────────────────
log "Preparing folder tree at ${BASE}"
mkdir -p "${BASE}/"{models,models/loras}

[[ -d "${BASE}/backend" ]] || { echo "❌  Put backend/, microservices/, charts/ under ${BASE} first."; exit 1; }

MODEL_DIR="${BASE}/models"
MODEL_FILE="phi-3-mini-128k-instruct.Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/TheBloke/phi-3-mini-128k-instruct-GGUF/resolve/main/${MODEL_FILE}"

log "Downloading test model: ${MODEL_FILE}"
curl -L --retry 5 --retry-delay 5 -o "${MODEL_DIR}/${MODEL_FILE}" "${MODEL_URL}"

# ───────── 4. Build & push custom images ─────────────────────────────────────
log "Building custom images"
docker build -t "${REG}/zeno-agents:latest" "${BASE}/backend"

for svc in ocr playwright selenium; do
  docker build -t "${REG}/zeno-${svc}:latest" "${BASE}/microservices/${svc}"
done

log "Pushing images to local registry"
for svc in agents ocr playwright selenium; do
  docker push "${REG}/zeno-${svc}:latest"
done

# ───────── 5. Re-package zeno-memory chart (PostgreSQL only) ─────────────────
log "Re-building zeno-memory chart (PostgreSQL only)"
MEM_DIR="${BASE}/charts/memory"; SUB_DIR="${MEM_DIR}/charts"
mkdir -p "${SUB_DIR}"
cat >"${MEM_DIR}/Chart.yaml" <<EOF
apiVersion: v2
name: zeno-memory
version: ${MEM_CHART_VER}
dependencies:
  - name: postgresql
    version: ${PG_VER}
    repository: "file://charts"
EOF

rm -rf "${SUB_DIR:?}/"* "${MEM_DIR}/Chart.lock" || true
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null || true
helm pull bitnami/postgresql --version "${PG_VER}" --destination "${SUB_DIR}" \
  || { log "Failed to pull Bitnami Postgres chart"; exit 1; }

export HELM_MAX_CHART_SIZE=${HELM_LIMIT}
export HELM_MAX_CHART_FILE_SIZE=${HELM_LIMIT}
helm package "${MEM_DIR}" -d "${BASE}/charts"

# ───────── 6. Add extra Helm repos ───────────────────────────────────────────
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null || true
helm repo add n8n               https://8gears.github.io/n8n-helm-chart >/dev/null || true
helm repo add sentry            https://sentry-kubernetes.github.io/charts >/dev/null || true
helm repo add open-telemetry    https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null || true
helm repo update >/dev/null

# ───────── 7. Package remaining charts ───────────────────────────────────────
log "Packaging remaining charts"
cd "${BASE}/charts"
for c in inference agents ui; do
  helm package "${c}" | tee -a /var/log/zeno-install.log
done

# Capture packaged file names (no hard-coded versions)
INFER_TGZ=$(ls "${BASE}"/charts/zeno-inference-*.tgz | head -n1)
AGENT_TGZ=$(ls "${BASE}"/charts/zeno-agents-*.tgz   | head -n1)

# ───────── 8. Deploy releases ────────────────────────────────────────────────
kubectl create ns "${NS}" --dry-run=client -o yaml | kubectl apply -f -

log "Deploying memory layer"
helm upgrade --install zeno-memory "${BASE}/charts/zeno-memory-${MEM_CHART_VER}.tgz" -n "${NS}" --wait

# ───────── Deploy inference layer (GPU or CPU) ─────────────────────────────
INFER_TGZ=$(ls "${BASE}/charts"/zeno-inference-*.tgz | head -n1)
MODEL_DIR="${BASE}/models"
MODEL_FILE="phi-3-mini-128k-instruct.Q4_K_M.gguf" 

log 'Deploying inference layer (llama.cpp off-load)'
helm upgrade --install zeno-inference "${INFER_TGZ}" \
  -n "${NS}" \
  --set global.registry="${REG}" \
  --set modelVolume.hostPath="${MODEL_DIR}" \
  --set llamaCpp.modelPath="/models/${MODEL_FILE}" \
  --set llamaCpp.nGPULayers=40 \
  --set llamaCpp.threads=12 \
  --set llamaCpp.batch=64 \
  --wait --timeout 20m

log "Deploying agents layer"
helm upgrade --install zeno-agents   "${AGENT_TGZ}" -n "${NS}" --set global.registry="${REG}" --wait

log "Deploying Keycloak (admin / admin)"
helm upgrade --install zeno-auth bitnami/keycloak \
  -n "${NS}" --set auth.adminUser=admin --set auth.adminPassword=admin --wait

# ───────── Optional extras (uncomment to enable) ─────────────────────────────
# OpenTelemetry Collector
# helm upgrade --install zeno-otel open-telemetry/opentelemetry-collector -n "${NS}" --create-namespace --wait

# n8n (external Postgres)
# kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n "${NS}" --timeout=120s
# DB_PASS=$(kubectl get secret -n "${NS}" zeno-memory-postgresql -o jsonpath='{.data.postgresql-password}' | base64 -d)
# helm upgrade --install zeno-n8n n8n/n8n \
#   -n "${NS}" --create-namespace --wait --timeout 600s \
#   --set postgresql.enabled=false \
#   --set externalDatabase.host=zeno-memory-postgresql \
#   --set externalDatabase.user=postgres \
#   --set externalDatabase.password="${DB_PASS}" \
#   --set n8n.env.DB_TYPE=postgresdb

# Sentry (external Postgres)
# helm upgrade --install zeno-sentry sentry/sentry \
#   -n "${NS}" --create-namespace --wait --timeout 1000s \
#   --set postgresql.enabled=false \
#   --set externalPostgresql.host=zeno-memory-postgresql \
#   --set externalPostgresql.user=postgres \
#   --set externalPostgresql.password="${DB_PASS}" \
#   --set externalPostgresql.database=sentry

log "✅  All charts triggered. Watch:  kubectl get pods -n ${NS} -w"

cat <<'TIP'
────────────────────────────────────────────────────────────────
🛈  API access while you wait
    # on your laptop:
    ssh -L 8001:zeno-inference-backend.zeno.svc.cluster.local:8001 \
        root@<VPS-IP>
    LobeChat → API Base = http://localhost:8001
────────────────────────────────────────────────────────────────
TIP