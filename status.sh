#!/usr/bin/env bash
# CySOC MISP integration for UTMStack - health check
set -uo pipefail

PLUGIN=com.utmstack.misp
DATA_DIR=${UTMSTACK_DATA_DIR:-/utmstack}
PIPELINE=${DATA_DIR}/events-engine-workdir/pipeline
LOGS=${DATA_DIR}/events-engine-workdir/logs
TARGET=/workdir/plugins/utmstack/${PLUGIN}.plugin
SERVICES=${UTMSTACK_EP_SERVICES:-"utmstack_event-processor-worker utmstack_event-processor-manager"}

ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }
info() { printf '  [..]   %s\n' "$*"; }

echo "== Files"
[[ -x ${DATA_DIR}/custom-plugins/${PLUGIN}.plugin ]] && ok "binary ${DATA_DIR}/custom-plugins/${PLUGIN}.plugin" || bad "binary missing"
[[ -f ${PIPELINE}/cysoc_misp.yaml ]] && ok "config ${PIPELINE}/cysoc_misp.yaml" || bad "config missing"
if grep -qx "    - ${PLUGIN}" "${PIPELINE}/zz_cysoc_misp_analysis_order.yaml" 2>/dev/null; then
  ok "registered in analysis order"
else
  bad "not in analysis order (run install.sh --ensure)"
fi

echo "== EventProcessor services"
for svc in $SERVICES; do
  if docker service inspect "$svc" --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{.Target}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -qx "$TARGET"; then
    ok "$svc has the plugin mounted"
  else
    bad "$svc: plugin NOT mounted (run install.sh --ensure)"
  fi
  cid=$(docker ps -q --filter "name=${svc}." | head -1)
  if [[ -n "$cid" ]]; then
    if docker exec "$cid" sh -c "ls /workdir/sockets 2>/dev/null" | grep -q "${PLUGIN}_analysis.sock"; then
      ok "$svc: plugin socket is up (${PLUGIN}_analysis.sock)"
    else
      info "$svc: no plugin socket in this container (normal if this role does not run analysis plugins)"
    fi
    if docker exec "$cid" sh -c "ps -ef 2>/dev/null || ls /proc/*/cmdline" 2>/dev/null | grep -q "${PLUGIN}"; then
      ok "$svc: plugin process running"
    fi
  fi
done

echo "== Indicator cache"
cache=${LOGS}/${PLUGIN}.cache.json
if [[ -f "$cache" ]]; then
  ok "cache $(du -h "$cache" | cut -f1), last refresh $(date -r "$cache" '+%F %T')"
else
  info "no cache yet (created after the first successful MISP pull)"
fi

echo "== Recent plugin log lines"
{
  for svc in $SERVICES; do docker service logs --since 2h --raw "$svc" 2>/dev/null; done
  grep -rh "plugin_${PLUGIN}" "$LOGS" 2>/dev/null | tail -n 50
} | grep "plugin_${PLUGIN}" | tail -n 8 | cut -c1-400 || true
echo
echo "Alerts appear in the UTMStack Alerts view, named 'MISP Threat Intelligence Match: ...'"
