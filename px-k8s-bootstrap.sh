#!/usr/bin/env bash
# =============================================================================
#  PX Lab - Bootstrap Kubernetes (kubeadm) pour demos V1CS / V1FS
#  Script UNIQUE a mettre en launch script sur les 3 VM.
#  Le role est detecte via le hostname :
#    k8smaster   -> control-plane + addons
#    k8sworker*  -> attend le master puis join automatiquement
#  Idempotent : ne rejoue rien si deja termine (marker /var/lib/lab-bootstrap/done)
#  Log : /var/log/lab-bootstrap.log   Infos finales : /root/lab-info.txt
# =============================================================================
set -euo pipefail

# ============================ PARAMETRES =====================================
MASTER_HOST="k8smaster"            # Hostname ou IP du master (vu des workers). IP conseillee si DNS PX incertain.
K8S_MINOR="v1.34"                  # Version mineure K8s. Verifier la matrice de support V1CS.
POD_CIDR="10.244.0.0/16"           # CIDR par defaut de Flannel
JOIN_TOKEN="pxlab0.trendv1cs0demo00"  # Token partage. Format impose : [a-z0-9]{6}.[a-z0-9]{16}
EXPECTED_WORKERS=2                 # Le master attend ces workers avant d'installer les addons
WAIT_WORKERS_TIMEOUT=1800          # Secondes max d'attente des workers

ENABLE_METALLB=true                # false si le reseau PX ne supporte pas MetalLB en L2 (ARP)
METALLB_RANGE=""                   # Vide = auto : x.y.z.240-x.y.z.250 du subnet du master
ENABLE_HEADLAMP=true
ENABLE_MONITORING=true             # kube-prometheus-stack (Prometheus + Grafana)
GRAFANA_PASSWORD="TrendLab2026!"
PROM_RETENTION="3d"

LOCAL_PATH_VERSION="v0.0.31"
# =============================================================================

STATE_DIR=/var/lib/lab-bootstrap
LOG=/var/log/lab-bootstrap.log
mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG") 2>&1

log()  { echo "[$(date '+%F %T')] $*"; }
warn() { echo "[$(date '+%F %T')] WARN: $*"; }

[ "$(id -u)" -eq 0 ] || { echo "Doit tourner en root"; exit 1; }
[ -f "$STATE_DIR/done" ] && { log "Bootstrap deja termine. Rien a faire."; exit 0; }

HOST=$(hostname -s)
case "$HOST" in
  k8smaster)  ROLE=master ;;
  k8sworker*) ROLE=worker ;;
  *) echo "Hostname '$HOST' non reconnu (attendu k8smaster / k8sworker*)"; exit 1 ;;
esac
log "=== Bootstrap $HOST (role=$ROLE) ==="

LAB_USER=$(getent passwd 1000 | cut -d: -f1 || true)
LAB_USER=${LAB_USER:-ubuntu}
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o DPkg::Lock::Timeout=600 -o Acquire::Retries=5"
export KUBECONFIG=/etc/kubernetes/admin.conf

# ----------------------------------------------------------------------------
common_prereqs() {
  [ -f "$STATE_DIR/common" ] && { log "Prereqs deja OK"; return; }
  log "Swap off"
  swapoff -a || true
  sed -ri '/\sswap\s/ s/^#?/#/' /etc/fstab || true
  systemctl mask swap.target >/dev/null 2>&1 || true

  log "Modules et sysctl"
  cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
  modprobe overlay; modprobe br_netfilter
  cat >/etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 524288
EOF
  sysctl --system >/dev/null

  log "Paquets de base + containerd"
  $APT update
  $APT install ca-certificates curl gpg jq conntrack socat ipset containerd

  log "Config containerd (SystemdCgroup)"
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || warn "SystemdCgroup non trouve, verifier config.toml"
  systemctl enable containerd
  systemctl restart containerd

  log "Repo Kubernetes $K8S_MINOR"
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
    | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  $APT update
  $APT install kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable kubelet

  cat >/etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF
  touch "$STATE_DIR/common"
}

# ----------------------------------------------------------------------------
setup_user_kubeconfig() {
  mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config
  if id "$LAB_USER" >/dev/null 2>&1; then
    local h; h=$(getent passwd "$LAB_USER" | cut -d: -f6)
    mkdir -p "$h/.kube" && cp -f /etc/kubernetes/admin.conf "$h/.kube/config"
    chown -R "$LAB_USER:" "$h/.kube"
    grep -q 'alias k=kubectl' "$h/.bashrc" 2>/dev/null || cat >>"$h/.bashrc" <<'EOF'
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF
  fi
}

install_helm() {
  command -v helm >/dev/null && return
  log "Installation Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

wait_workers() {
  log "Attente de $EXPECTED_WORKERS worker(s) Ready (max ${WAIT_WORKERS_TIMEOUT}s)"
  local end=$((SECONDS + WAIT_WORKERS_TIMEOUT)) n=0
  while :; do
    n=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null \
        | awk '$2=="Ready"' | wc -l)
    [ "$n" -ge "$EXPECTED_WORKERS" ] && { log "$n worker(s) Ready"; return 0; }
    [ $SECONDS -ge $end ] && { warn "Timeout : seulement $n worker(s). Les addons resteront Pending."; return 0; }
    sleep 15
  done
}

addon_metrics_server() {
  log "metrics-server"
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
  helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
    --set 'args={--kubelet-insecure-tls}' --wait --timeout 10m
}

addon_local_path() {
  log "local-path-provisioner (StorageClass par defaut)"
  kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

addon_metallb() {
  log "MetalLB"
  if [ -z "$METALLB_RANGE" ]; then
    local p; p=$(echo "$MASTER_IP" | cut -d. -f1-3)
    METALLB_RANGE="${p}.240-${p}.250"
  fi
  helm repo add metallb https://metallb.github.io/metallb >/dev/null
  helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace --wait --timeout 10m
  # Le webhook peut mettre quelques secondes a repondre
  for i in $(seq 1 20); do
    cat <<EOF | kubectl apply -f - && break
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: lab-pool, namespace: metallb-system }
spec:
  addresses: [ "${METALLB_RANGE}" ]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: lab-l2, namespace: metallb-system }
spec:
  ipAddressPools: [ lab-pool ]
EOF
    sleep 10
  done
  log "MetalLB pool : $METALLB_RANGE"
}

addon_headlamp() {
  log "Headlamp"
  helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null
  helm upgrade --install headlamp headlamp/headlamp -n kube-system \
    --set service.type="$SVC_TYPE" --wait --timeout 10m
  kubectl -n kube-system create serviceaccount headlamp-admin --dry-run=client -o yaml | kubectl apply -f -
  kubectl create clusterrolebinding headlamp-admin --clusterrole=cluster-admin \
    --serviceaccount=kube-system:headlamp-admin --dry-run=client -o yaml | kubectl apply -f -
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-admin-token
  namespace: kube-system
  annotations: { kubernetes.io/service-account.name: headlamp-admin }
type: kubernetes.io/service-account-token
EOF
  sleep 5
}

addon_monitoring() {
  log "kube-prometheus-stack"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace \
    --set grafana.adminPassword="$GRAFANA_PASSWORD" \
    --set grafana.service.type="$SVC_TYPE" \
    --set prometheus.prometheusSpec.retention="$PROM_RETENTION" \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --wait --timeout 15m
}

svc_endpoint() { # ns svc
  local ip port
  ip=$(kubectl -n "$1" get svc "$2" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "$ip" ]; then
    port=$(kubectl -n "$1" get svc "$2" -o jsonpath='{.spec.ports[0].port}')
    echo "http://${ip}:${port}"
  else
    port=$(kubectl -n "$1" get svc "$2" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
    echo "http://${MASTER_IP}:${port:-?} (NodePort)"
  fi
}

write_lab_info() {
  local f=/root/lab-info.txt
  {
    echo "===== PX K8s Lab ====="
    echo "Date        : $(date)"
    echo "Master IP   : $MASTER_IP"
    echo "K8s         : $(kubectl version -o json 2>/dev/null | jq -r .serverVersion.gitVersion)"
    echo
    kubectl get nodes -o wide
    echo
    $ENABLE_HEADLAMP   && echo "Headlamp    : $(svc_endpoint kube-system headlamp)"
    $ENABLE_HEADLAMP   && echo "Token       : $(kubectl -n kube-system get secret headlamp-admin-token -o jsonpath='{.data.token}' | base64 -d)"
    $ENABLE_MONITORING && echo "Grafana     : $(svc_endpoint monitoring kps-grafana)  admin / $GRAFANA_PASSWORD"
    $ENABLE_METALLB    && echo "MetalLB     : $METALLB_RANGE"
    echo
    echo "StorageClass:"; kubectl get sc
    echo
    echo "Pret pour V1CS / V1FS (helm + kubeconfig OK pour $LAB_USER)."
  } > "$f"
  if id "$LAB_USER" >/dev/null 2>&1; then
    cp -f "$f" "$(getent passwd "$LAB_USER" | cut -d: -f6)/lab-info.txt"
    chown "$LAB_USER:" "$(getent passwd "$LAB_USER" | cut -d: -f6)/lab-info.txt"
  fi
  cat "$f"
}

# ----------------------------------------------------------------------------
master() {
  MASTER_IP=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  log "Master IP : $MASTER_IP"

  if [ ! -f /etc/kubernetes/admin.conf ]; then
    cat >/root/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
bootstrapTokens:
- token: "${JOIN_TOKEN}"
  ttl: "0s"
  groups: [ "system:bootstrappers:kubeadm:default-node-token" ]
  usages: [ signing, authentication ]
localAPIEndpoint:
  advertiseAddress: "${MASTER_IP}"
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  podSubnet: "${POD_CIDR}"
apiServer:
  certSANs: [ "${MASTER_IP}", "k8smaster" ]
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
    log "kubeadm init"
    kubeadm init --config /root/kubeadm-config.yaml
  fi
  setup_user_kubeconfig

  log "Flannel"
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
  kubectl wait --for=condition=Ready node/"$HOST" --timeout=600s || warn "Master pas encore Ready"

  install_helm
  wait_workers

  SVC_TYPE=NodePort
  addon_local_path     || warn "local-path KO"
  addon_metrics_server || warn "metrics-server KO"
  if $ENABLE_METALLB; then addon_metallb && SVC_TYPE=LoadBalancer || warn "MetalLB KO, fallback NodePort"; fi
  $ENABLE_HEADLAMP   && { addon_headlamp   || warn "Headlamp KO"; }
  $ENABLE_MONITORING && { addon_monitoring || warn "Monitoring KO"; }

  write_lab_info
}

worker() {
  log "Attente API server ${MASTER_HOST}:6443"
  until timeout 3 bash -c "</dev/tcp/${MASTER_HOST}/6443" 2>/dev/null; do
    getent hosts "$MASTER_HOST" >/dev/null || warn "${MASTER_HOST} non resolu. Mettre l'IP dans MASTER_HOST."
    sleep 15
  done
  [ -f /etc/kubernetes/kubelet.conf ] && { log "Deja joint"; return; }
  for i in $(seq 1 30); do
    log "kubeadm join (essai $i)"
    if kubeadm join "${MASTER_HOST}:6443" --token "$JOIN_TOKEN" \
         --discovery-token-unsafe-skip-ca-verification \
         --cri-socket unix:///run/containerd/containerd.sock; then
      log "Join OK"; return
    fi
    kubeadm reset -f >/dev/null 2>&1 || true
    sleep 20
  done
  echo "Join impossible apres 30 essais"; exit 1
}

# ----------------------------------------------------------------------------
common_prereqs
case "$ROLE" in
  master) master ;;
  worker) worker ;;
esac
touch "$STATE_DIR/done"
log "=== Bootstrap $HOST termine ==="
