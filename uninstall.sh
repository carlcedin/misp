#!/usr/bin/env bash
# CySOC MISP integration for UTMStack - uninstall
#   sudo ./uninstall.sh            remove plugin, keep config (with API key) and cache
#   sudo ./uninstall.sh --purge    also delete config and indicator cache
set -euo pipefail

PLUGIN=com.utmstack.misp
DATA_DIR=${UTMSTACK_DATA_DIR:-/utmstack}
PIPELINE=${DATA_DIR}/events-engine-workdir/pipeline
TARGET=/workdir/plugins/utmstack/${PLUGIN}.plugin
SERVICES=${UTMSTACK_EP_SERVICES:-"utmstack_event-processor-worker utmstack_event-processor-manager"}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

rm -f /etc/cron.d/utmstack-misp-guard                        # stop the guard first
rm -f "${PIPELINE}/zz_cysoc_misp_analysis_order.yaml"         # back to UTMStack's own order

for svc in $SERVICES; do
  if docker service inspect "$svc" --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{.Target}} {{end}}' 2>/dev/null \
      | tr ' ' '\n' | grep -qx "$TARGET"; then
    echo "removing plugin mount from $svc (service restarts) ..."
    docker service update --detach=false --quiet --mount-rm "$TARGET" "$svc" >/dev/null
  fi
done

rm -f "${DATA_DIR}/custom-plugins/${PLUGIN}.plugin" "${DATA_DIR}/custom-plugins/misp-install.sh"

if [[ "${1:-}" == "--purge" ]]; then
  rm -f "${PIPELINE}/cysoc_misp.yaml" "${PIPELINE}/misp-ca.pem" \
        "${DATA_DIR}/events-engine-workdir/logs/${PLUGIN}.cache.json"
  echo "config and cache deleted"
else
  echo "kept ${PIPELINE}/cysoc_misp.yaml (contains the MISP API key; use --purge to delete)"
fi
echo "MISP plugin removed."
