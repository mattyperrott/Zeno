#!/usr/bin/env bash
# ==============================================================================
#   Zeno – full-stack installer (single VPS, fresh OS, with llama.cpp build)
# ==============================================================================

set -euo pipefail
trap 'echo -e "\e[31mERROR at line $LINENO – aborting.\e[0m"' ERR
shopt -s globstar

log(){ printf "\n\033[1;34m\u25B6\uFE0E %s\033[0m\n" "$*"; }

list_disks() {
  lsblk -b -o NAME,SIZE,FSTYPE,MOUNTPOINT |
    awk 'NR>1 && $3!="" && $4!="" {printf "%s|%s|%s\n",$0,$3,$4}' |
    while IFS='|' read -r line fstype mount; do
      avail=$(df -hP "$mount" | awk 'NR==2{print $4}')
      size=$(echo "$line" | awk '{printf "%.1fG", $2/1024/1024/1024}')
      printf "%-3s  %-8s  %-7s  %-12s  %s\n" "[$idx]" "$size" "$fstype" "$avail" "$mount"
      ((idx++))
    done
}

# ───────── Disk selection ───────────────────────────────────────────────────
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

log "Using BASE=${BASE}"
mkdir -p "$BASE/models" "$BASE/models/loras"

# ───────── Copy necessary directories ───────────────────────────────────────
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
for d in backend charts llamacpp microservices; do
  if [[ ! -d "${BASE}/${d}" ]]; then
    log "Copying ${d}/ → ${BASE}/${d}"
    cp -rT "${SCRIPT_DIR}/${d}" "${BASE}/${d}"
  fi
  [[ -d "${BASE}/${d}" ]] || { echo "❌  ${BASE}/${d} missing – aborting."; exit 1; }
done

# ───────── Configurable ─────────────────────────────────────────────────────
DOMAIN="${1:-zeno.local}"
NS=zeno
REG_PORT=5000
REG="localhost:${REG_PORT}"
MEM_CHART_VER="0.1.0"
PG_VER="15.2.2"
HELM_LIMIT=20000000

need_pkg(){ dpkg -s "$1" &>/dev/null || apt-get install -y "$1"; }
append_bashrc(){ local line="$1" file="$2"; mkdir -p "$(dirname "$file")"; touch "$file"; grep -Fqx "$line" "$file" || echo "$line" >> "$file"; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 <public-host>"; exit 1; }

# ───────── Install dependencies ─────────────────────────────────────────────
log "Installing base packages"
apt-get update -qq
for p in curl git ca-certificates gnupg lsb-release unzip yq build-essential python3 python3-venv pkg-config libffi-dev libssl-dev; do
  need_pkg "$p"
done

# Docker
if ! command -v docker &>/dev/null; then curl -fsSL https://get.docker.com | sh; fi
systemctl enable --now docker

# NVIDIA optional
if lspci | grep -qi nvidia; then
  need_pkg nvidia-driver-535
  need_pkg nvidia-container-toolkit
  systemctl restart docker
fi

# k3s
if ! command -v k3s &>/dev/null; then curl -sfL https://get.k3s.io | sh -; fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
append_bashrc 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' /root/.bashrc
if [[ -n "${SUDO_USER:-}" && -d /home/${SUDO_USER} ]]; then append_bashrc 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' "/home/${SUDO_USER}/.bashrc"; fi

log "Waiting for Kubernetes node to become Ready"
ATTEMPTS=36
until kubectl get nodes &>/dev/null; do ((ATTEMPTS--)) || { echo "k3s API unreachable after 3 min"; exit 1; }; sleep 5; done
kubectl wait --for=condition=Ready node --all --timeout=120s

# Helm
if ! command -v helm &>/dev/null; then curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; fi

# ───────── Local Docker registry ────────────────────────────────────────────
log "Starting local Docker registry"
docker rm -f zeno-registry 2>/dev/null || true
docker run -d --restart=always -p ${REG_PORT}:5000 --name zeno-registry registry:2

mkdir -p /etc/rancher/k3s
cat >/etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "${REG}":
    endpoint:
      - "http://${REG}"
EOF
systemctl restart k3s
sleep 5

# ───────── Build llama.cpp image (if not present) ──────────────────────────
LLAMACPP_IMAGE="${REG}/zeno-llamacpp:latest"
if ! docker image inspect "$LLAMACPP_IMAGE" &>/dev/null; then
  log "Building llama.cpp Docker image"
  docker build -t "$LLAMACPP_IMAGE" "$SCRIPT_DIR/llamacpp"
  docker push "$LLAMACPP_IMAGE"
else
  log "llama.cpp Docker image already present: $LLAMACPP_IMAGE"
fi

# ───────── Download small test model ───────────────────────────────────────
MODEL_DIR="${BASE}/models"
MODEL_FILE="phi-3-mini-128k-instruct.Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/TheBloke/phi-3-mini-128k-instruct-GGUF/resolve/main/${MODEL_FILE}"
log "Downloading test model: ${MODEL_FILE}"
curl -L --retry 5 --retry-delay 5 -o "${MODEL_DIR}/${MODEL_FILE}" "${MODEL_URL}"

# ───────── Build & push app images ─────────────────────────────────────────
log "Building app images"
docker build -t "${REG}/zeno-agents:latest" "${BASE}/backend"
for svc in ocr playwright selenium; do
  docker build -t "${REG}/zeno-${svc}:latest" "${BASE}/microservices/${svc}"
done
log "Pushing images"
for svc in agents ocr playwright selenium; do
  docker push "${REG}/zeno-${svc}:latest"
done

# ───────── Package charts ──────────────────────────────────────────────────
log "Packaging memory chart"
MEM_DIR="${BASE}/charts/memory"; SUB_DIR="${MEM_DIR}/charts"
mkdir -p "$SUB_DIR"
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
helm pull bitnami/postgresql --version "$PG_VER" --destination "$SUB_DIR"
helm package "$MEM_DIR" -d "$BASE/charts"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null || true
helm repo add n8n https://8gears.github.io/n8n-helm-chart >/dev/null || true
helm repo add sentry https://sentry-kubernetes.github.io/charts >/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null || true
helm repo update >/dev/null

log "Packaging remaining charts"
cd "$BASE/charts"
for c in inference agents ui; do
  helm package "$c"
done
INFER_TGZ=$(ls "$BASE/charts"/zeno-inference-*.tgz | head -n1)
AGENT_TGZ=$(ls "$BASE/charts"/zeno-agents-*.tgz | head -n1)

kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f -

log "Deploying memory layer"
helm upgrade --install zeno-memory "$BASE/charts/zeno-memory-${MEM_CHART_VER}.tgz" -n "$NS" --wait

log "Deploying inference layer (llama.cpp)"
helm upgrade --install zeno-inference "$INFER_TGZ" \
  -n "$NS" \
  --set global.registry="$REG" \
  --set modelVolume.hostPath="$MODEL_DIR" \
  --set llamaCpp.modelPath="/models/${MODEL_FILE}" \
  --set llamaCpp.nGPULayers=40 \
  --set llamaCpp.threads=12 \
  --set llamaCpp.batch=64 \
  --wait --timeout 20m

log "Deploying agents layer"
helm upgrade --install zeno-agents "$AGENT_TGZ" -n "$NS" --set global.registry="$REG" --wait

log "Deploying Keycloak (admin / admin)"
helm upgrade --install zeno-auth bitnami/keycloak \
  -n "$NS" --set auth.adminUser=admin --set auth.adminPassword=admin --wait

log "✅  All charts triggered. Watch:  kubectl get pods -n ${NS} -w"

cat <<'TIP'
────────────────────────────────────────────────────────────────
🛈  API access while you wait
    ssh -L 8001:zeno-inference-backend.zeno.svc.cluster.local:8001 \
        root@<VPS-IP>
    LobeChat → API Base = http://localhost:8001
────────────────────────────────────────────────────────────────
TIP