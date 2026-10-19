#!/usr/bin/env bash
# =============================================================================
#  V1CS auto install - Trend Vision One Container Security
#  A lancer sur le master (kubectl + helm deja OK).
#
#  Usage :
#    export V1_API_KEY='<cle API Vision One>'     # sinon demandee au clavier
#    ./v1cs-install.sh               # installe
#    ./v1cs-install.sh uninstall     # desinstalle + supprime le cluster dans V1
#
#  Variables optionnelles (export avant lancement) :
#    V1_REGION      eu (defaut) | us | jp | sg | au | in | mea | uk | ca
#    REG_MODE       api (defaut) : cree le cluster via l'API, recupere le token
#                   auto         : auto-registration par le chart Helm
#    CLUSTER_NAME   defaut PX_Lab_<date>
#    GROUP_ID       defaut 00000000-0000-0000-0000-000000000001 (groupe par defaut)
#    POLICY_ID      vide = aucune policy assignee
#    RUNTIME VULN MALWARE SECRET   true|false (defaut true)
#    CHART_VERSION  vide = derniere version
# =============================================================================
set -euo pipefail

V1_REGION="${V1_REGION:-eu}"
REG_MODE="${REG_MODE:-api}"
CLUSTER_NAME="${CLUSTER_NAME:-PX_Lab_$(date +%Y%m%d_%H%M)}"
GROUP_ID="${GROUP_ID:-00000000-0000-0000-0000-000000000001}"
POLICY_ID="${POLICY_ID:-}"
RUNTIME="${RUNTIME:-true}"
VULN="${VULN:-true}"
MALWARE="${MALWARE:-true}"
SECRET="${SECRET:-true}"
CHART_VERSION="${CHART_VERSION:-}"

NS=trendmicro-system
RELEASE=trendmicro
CHART=oci://public.ecr.aws/trendmicro/container-security/trendmicro-container-security
WORKDIR="$HOME/v1cs"
STATE="$WORKDIR/state.env"

log()  { echo "[$(date '+%T')] $*"; }
die()  { echo "[$(date '+%T')] ERREUR: $*" >&2; exit 1; }

case "$V1_REGION" in
  us)  API="https://api.xdr.trendmicro.com" ;;
  eu)  API="https://api.eu.xdr.trendmicro.com" ;;
  jp)  API="https://api.xdr.trendmicro.co.jp" ;;
  sg)  API="https://api.sg.xdr.trendmicro.com" ;;
  au)  API="https://api.au.xdr.trendmicro.com" ;;
  in)  API="https://api.in.xdr.trendmicro.com" ;;
  mea) API="https://api.mea.xdr.trendmicro.com" ;;
  uk)  API="https://api.uk.xdr.trendmicro.com" ;;
  ca)  API="https://api.ca.xdr.trendmicro.com" ;;
  *)   die "Region inconnue : $V1_REGION" ;;
esac

mkdir -p "$WORKDIR" && chmod 700 "$WORKDIR"
for b in kubectl helm jq curl; do command -v "$b" >/dev/null || die "$b absent"; done
kubectl get nodes >/dev/null 2>&1 || die "kubectl ne joint pas le cluster"

get_key() {
  if [ -z "${V1_API_KEY:-}" ]; then
    read -rsp "Cle API Vision One : " V1_API_KEY; echo
  fi
  [ -n "$V1_API_KEY" ] || die "Cle API vide"
  AUTH_H="$WORKDIR/.auth"
  ( umask 077; printf 'Authorization: Bearer %s\n' "$V1_API_KEY" > "$AUTH_H" )
  trap 'rm -f "$AUTH_H"' EXIT
}

v1api() { # METHOD PATH [JSON_BODY] -> sets HTTP_CODE, BODY_F, HDR_F
  BODY_F="$WORKDIR/.resp.json"; HDR_F="$WORKDIR/.resp.hdr"
  local args=(-sS -o "$BODY_F" -D "$HDR_F" -w '%{http_code}' -X "$1" -H @"$AUTH_H"
              -H 'Content-Type: application/json' "${API}$2")
  [ $# -ge 3 ] && args+=(-d "$3")
  HTTP_CODE=$(curl "${args[@]}") || die "Appel API impossible ($2)"
}

# ----------------------------------------------------------------------------
uninstall() {
  [ -f "$STATE" ] && . "$STATE"
  # En mode auto, le chart desenregistre lui-meme le cluster : pas besoin de cle
  [ "${SAVED_MODE:-}" = api ] && get_key
  log "helm uninstall"
  helm uninstall "$RELEASE" -n "$NS" --wait --timeout 10m || true
  kubectl delete ns "$NS" --ignore-not-found --timeout=5m || true
  if [ "${SAVED_MODE:-}" = api ] && [ -n "${SAVED_CLUSTER_ID:-}" ]; then
    log "Suppression du cluster $SAVED_CLUSTER_ID dans Vision One"
    v1api DELETE "/v3.0/containerSecurity/kubernetesClusters/${SAVED_CLUSTER_ID}"
    case "$HTTP_CODE" in
      204|200) log "Cluster supprime dans V1" ;;
      *) echo "HTTP $HTTP_CODE"; cat "$BODY_F"; echo; log "A supprimer a la main dans la console" ;;
    esac
  fi
  rm -f "$STATE"
  log "Desinstallation terminee"
}

install() {
  helm status "$RELEASE" -n "$NS" >/dev/null 2>&1 && die "Release $RELEASE deja installee. Lancer d'abord : $0 uninstall"
  get_key

  if [ "$REG_MODE" = api ]; then
    log "Test de la cle API ($API)"
    v1api GET "/v3.0/containerSecurity/kubernetesClusters?top=1"
    case "$HTTP_CODE" in
      200) log "Cle API OK" ;;
      401) die "Cle API invalide ou expiree (401)" ;;
      403) die "Cle API sans droit de lecture CS (403). Cle auto-registration ? Utiliser REG_MODE=auto" ;;
      *)   cat "$BODY_F"; echo; die "Reponse inattendue HTTP $HTTP_CODE. Region correcte ?" ;;
    esac
  else
    log "Mode auto : la cle sera validee par le chart a l'installation"
  fi

  kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local endpoint
  if [ "$REG_MODE" = api ]; then
    log "Creation du cluster '$CLUSTER_NAME' dans Vision One"
    local body
    body=$(jq -n --arg n "$CLUSTER_NAME" --arg g "$GROUP_ID" --arg p "$POLICY_ID" \
      '{name:$n, groupId:$g, description:"PX lab - installation automatique"}
       + (if $p != "" then {policyId:$p} else {} end)')
    v1api POST "/v3.0/containerSecurity/kubernetesClusters" "$body"
    [[ "$HTTP_CODE" =~ ^20[01]$ ]] || { cat "$BODY_F"; echo; die "Creation cluster KO (HTTP $HTTP_CODE)"; }

    local token cid
    token=$(jq -r '.apiKey // empty' "$BODY_F")
    endpoint=$(jq -r '.endpointUrl // empty' "$BODY_F")
    cid=$(grep -i '^location:' "$HDR_F" | tr -d '\r' | awk '{print $2}' | xargs -r basename)
    [ -n "$token" ] && [ -n "$endpoint" ] || die "Reponse sans apiKey/endpointUrl : $(cat "$BODY_F")"
    log "Cluster cree (id=${cid:-?})"
    printf 'SAVED_MODE=api\nSAVED_CLUSTER_ID=%s\nSAVED_CLUSTER_NAME=%s\n' "$cid" "$CLUSTER_NAME" > "$STATE"

    kubectl -n "$NS" create secret generic trendmicro-container-security-bootstrap-token \
      --from-file=bootstrap.token=<(printf '%s' "$token") --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    rm -f "$BODY_F"
  else
    endpoint="${API}/external/v2/direct/vcs/external/vcs"
    log "Mode auto-registration (groupe $GROUP_ID)"
    kubectl -n "$NS" create secret generic trendmicro-container-security-registration-key \
      --from-file=registration.key=<(printf '%s' "$V1_API_KEY") --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    printf 'SAVED_MODE=auto\nSAVED_CLUSTER_NAME=%s\n' "$CLUSTER_NAME" > "$STATE"
  fi

  log "Generation overrides.yaml"
  {
    echo "visionOne:"
    echo "  endpoint: ${endpoint}"
    if [ "$REG_MODE" = auto ]; then
      echo "  clusterRegistrationKey: true"
      echo "  groupId: ${GROUP_ID}"
      echo "  clusterName: ${CLUSTER_NAME}"
      [ -n "$POLICY_ID" ] && echo "  policyId: ${POLICY_ID}"
    fi
    echo "  runtimeSecurity:"
    echo "    enabled: ${RUNTIME}"
    echo "  vulnerabilityScanning:"
    echo "    enabled: ${VULN}"
    echo "  malwareScanning:"
    echo "    enabled: ${MALWARE}"
    echo "  secretScanning:"
    echo "    enabled: ${SECRET}"
    if [ "$REG_MODE" = api ]; then
      echo "useExistingSecrets:"
      echo "  containerSecurityAuth: true"
    fi
  } > "$WORKDIR/overrides.yaml"
  cat "$WORKDIR/overrides.yaml"

  log "helm install $CHART"
  local ver=(); [ -n "$CHART_VERSION" ] && ver=(--version "$CHART_VERSION")
  helm install "$RELEASE" "$CHART" "${ver[@]}" -n "$NS" \
    --values "$WORKDIR/overrides.yaml" --wait --timeout 15m \
    || log "helm --wait en timeout, verifier les pods ci-dessous"

  log "Etat des pods"
  kubectl -n "$NS" get pods -o wide
  echo
  log "Termine. Cluster '$CLUSTER_NAME' visible sous quelques minutes dans :"
  log "Vision One > Cloud Security > Container Security > Container Inventory"
  log "Fichiers : $WORKDIR/overrides.yaml  $STATE"
}

case "${1:-install}" in
  install)   install ;;
  uninstall) uninstall ;;
  *) die "Usage : $0 [install|uninstall]" ;;
esac
