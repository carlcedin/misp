# CySOC MISP Threat Intelligence integration for UTMStack v11

This integration makes UTMStack check every event it processes against the indicators in the CySOC MISP instance (`https://10.210.17.244`). When an event matches an indicator, UTMStack raises an alert in its own **Alerts** console.

```
 MISP (10.210.17.244)                     UTMStack EventProcessor
 ┌──────────────────┐  REST, every 15 min  ┌────────────────────────────────────────────┐
 │ /attributes/     │ ◄─────────────────── │ com.utmstack.misp  (analysis plugin)       │
 │   restSearch     │  IOCs: IP, CIDR,     │   in-memory IOC tables + on-disk cache     │
 │ /events/index    │  domain, URL, hash,  │                                            │
 └──────────────────┘  email + threat lvl  │ every parsed event ──► match origin/target │
                                           │   hit ──► Alert ──► com.utmstack.alerts    │
                                           └────────────────────────────────────────────┘
```

The integration uses the same extension point as UTMStack's built-in ThreatWinds `feeds` plugin: an **analysis plugin**, listed in `plugins.analysis.order`. Because it sees every normalised event from every data source, you don't need to edit any filters or write any rules.

## Contents

| Path | Purpose |
|---|---|
| `bin/linux-amd64/com.utmstack.misp.plugin` | Prebuilt static binary (use `linux-arm64` on ARM hosts) |
| `bin/SHA256SUMS` | Checksums for the binaries |
| `config/cysoc_misp.yaml` | Plugin configuration template. Every option is commented |
| `install.sh` | Installs or upgrades the plugin, and re-applies it after UTMStack updates (`--ensure`) |
| `status.sh` | Health check |
| `uninstall.sh` | Clean removal (`--purge` also deletes the config and cache) |
| `build.sh` | Rebuilds the binary from source with Go 1.25, or with Docker if Go isn't installed |
| `plugin/` | Go source code, unit tests, and the gRPC end-to-end test |

## 1. Prepare MISP

1. **Create a dedicated user** for the integration, for example `utmstack@time.com.my`. Give it the **Read Only** role, or **Sync user** if you want it to see events that are shared to your organisation.
2. **Create an auth key** under that user's profile (**Auth keys** → **Add**). Put the UTMStack server IP in **Allowed IPs**, and set an expiry date that you track.
3. **Check your feeds.** Go to **Sync Actions → Feeds** and make sure the feeds you rely on are enabled and cached. Only attributes flagged **for IDS** (`to_ids`) in **published** events are pulled, and MISP warninglists are enforced. These are the defaults, and they keep false positives down.
4. **Deal with the certificate.** MISP currently uses a self-signed certificate. The best fix is to copy it to the UTMStack server as `/utmstack/events-engine-workdir/pipeline/misp-ca.pem` and set `caCertFile` in the config. As a stopgap, `insecureSkipVerify: true` works, and that's the default in the template.

## 2. Install (on the UTMStack swarm manager node, as root)

```bash
tar xzf cysoc-misp-utmstack-integration.tar.gz && cd misp-utmstack-integration
sha256sum -c bin/SHA256SUMS
sudo ./install.sh --url https://10.210.17.244 --api-key '<MISP auth key>'
sudo ./status.sh
```

`install.sh` does the following, and it's safe to re-run:

1. Copies the binary to `/utmstack/custom-plugins/com.utmstack.misp.plugin`.
2. Creates `/utmstack/events-engine-workdir/pipeline/cysoc_misp.yaml` with mode `600`, because it holds the API key. If the file already exists, it's kept.
3. **Tests the MISP API** from the host, and stops if the URL or key is wrong.
4. Writes `pipeline/zz_cysoc_misp_analysis_order.yaml`. This file contains UTMStack's own analysis order with `com.utmstack.misp` appended. It loads after `system_plugins_analysis.yaml`, so its order wins. It's rebuilt from UTMStack's file on each run, so plugins that UTMStack adds in future releases are kept.
5. Bind-mounts the binary into `utmstack_event-processor-worker` and `utmstack_event-processor-manager` at `/workdir/plugins/utmstack/`. This is the folder the EventProcessor loads plugin binaries from.
6. Adds `/etc/cron.d/utmstack-misp-guard`, which runs `install.sh --ensure` every 10 minutes (see section 5).

> **Plan a change window.** Step 5 restarts both EventProcessor services, which pauses event processing for about 30–60 seconds. Agents and collectors buffer during the restart. CySOC is an NCII entity, so do this under your normal change process, and **run it in a lab or staging UTMStack first**.

## 3. What the alerts look like

| Field | Value |
|---|---|
| Name | `MISP Threat Intelligence Match: Malicious IP` / `Domain` / `URL` / `File Hash` / `Email Address` |
| Category | `Threat Intelligence` |
| Severity | From the MISP event threat level: 1 → High, 2 → Medium, 3 → Low. Undefined → `defaultSeverity` (Medium) |
| Adversary | The side of the event that holds the malicious value. For an outbound connection to a C2 IP, the adversary is the C2 IP and the target is your internal host |
| Description | The indicator and matched field, MISP event ID and title, category, tags, and the analyst comment |
| References | A link to the MISP event: `https://10.210.17.244/events/view/<id>` |
| Event fields added | `log.mispIndicator`, `log.mispIndicatorType`, `log.mispEventId`, `log.mispEventInfo`, `log.mispCategory`, `log.mispTags`, `log.mispThreatLevel`, `log.mispMatchedField` |

**Grouping (default `alertMode: group`):** Each hit is kept, and hits are grouped under one parent alert per indicator and internal host, using UTMStack's standard `groupBy`. On top of that, an in-plugin throttle suppresses repeat hits of the same indicator and host within `suppressMinutes` (60 by default), so one noisy IOC can't flood the console.

**Fields that are checked:**
* On both the origin and target side: `ip` (including CIDR ranges), `domain`, `host`, `url` (plus the URL's host against domain IOCs), `md5`, `sha1`, `sha256`, `sha512`, `hash`, `email`, and `emailAddress`.
* Any extra `log.*` paths you list in `extraFields`.

## 4. Verify with a controlled test

1. In MISP, create a test event with threat level **High**. Add an `ip-dst` attribute with **IDS** ticked, using an IP that a lab machine can safely reach through a monitored firewall. Publish the event.
2. Wait for the next refresh. It runs every 15 minutes by default. To force one sooner, temporarily set `refreshMinutes: 1` in `cysoc_misp.yaml`. The change applies without a restart.
3. From the lab machine, connect to that IP, for example with `curl`.
4. In UTMStack, open the **Alerts** view and look for **MISP Threat Intelligence Match: Malicious IP**.
5. When you're done, delete the test attribute or event in MISP. The indicator drops out of UTMStack on the next refresh.

`sudo ./status.sh` shows whether the plugin is mounted, its socket is up, the time of the last cache refresh, and the most recent plugin log lines, such as `MISP indicators refreshed {counts...}`.

## 5. Operations

* **Changing settings:** Edit `/utmstack/events-engine-workdir/pipeline/cysoc_misp.yaml`. The EventProcessor reloads that folder, and the plugin picks up the change on its next cycle. No restart is needed.
* **False positives:** Add the value to `allowlist:`. Or better, fix it at the source in MISP: untick `to_ids`, or add the value to a warninglist, so every consumer benefits.
* **UTMStack upgrades:** An upgrade runs `docker stack deploy`, which resets the services to UTMStack's own spec and drops the custom mount. The cron guard notices within 10 minutes and re-applies the mount and the analysis order. Your config, cache, and binary live in `/utmstack` and aren't touched. After each upgrade, run `sudo ./status.sh`, and keep an eye on the release notes for changes to the plugin API.
* **MISP outage:** The plugin keeps using the last good indicator set. It also saves that set to `/utmstack/events-engine-workdir/logs/com.utmstack.misp.cache.json`, so detection keeps working after a restart. Refresh errors are logged, and UTMStack isn't affected.
* **Multi-node UTMStack:** The worker service runs on every swarm node. Copy `/utmstack/custom-plugins/com.utmstack.misp.plugin` to the same path on each node, because the bind mount reads the file from the local node.
* **Load:** The per-event cost is a few in-memory map lookups. MISP is queried only on refresh, in pages of 5,000 attributes. If you enable large feeds, narrow the pull with `lookback`, `tags`, or `types`, rather than raising `maxPages` a long way.

## 6. Troubleshooting

| Symptom | Check |
|---|---|
| `status.sh` shows the plugin as not mounted | Run `sudo ./install.sh --ensure`, then `docker service ps utmstack_event-processor-worker` to see why a task failed |
| Mounted, but there's no socket and no log lines | Run `docker exec <worker container> ls -l /workdir/plugins/utmstack/`. The binary must be executable, and it must match the host architecture (amd64 vs arm64) |
| `MISP refresh failed ... HTTP 403` | The auth key is wrong or expired, or the UTMStack IP isn't in the key's **Allowed IPs** |
| `x509: certificate signed by unknown authority` | Set `caCertFile`, or set `insecureSkipVerify: true` |
| The refresh works but no alerts appear | Confirm the indicator is `to_ids` and published, and not on a warninglist. Also confirm the matching event actually carries the value in `origin.*` / `target.*`. If the value sits under a vendor-specific field, add that path to `extraFields` |
| Too many alerts | Raise `minSeverity`, set `alertMode: deduplicate`, raise `suppressMinutes`, or tighten the MISP pull with `tags` / `lookback` |

## 7. Limitations and support

* **No UI tile.** This isn't a tile in UTMStack's **Integrations** page. Those tiles are generated by UTMStack's closed-source modules-config service. Configuration is done through the YAML file instead. The alerts themselves are native UTMStack alerts, and they work with its alert workflow, incident response, and reporting.
* **Not vendor-supported.** This is a custom component built on UTMStack's documented plugin SDK (`github.com/threatwinds/go-sdk` v1.1.34, the version UTMStack's own plugins use). It follows the conventions in UTMStack's source (`AGENTS.md`, `event_processor.Dockerfile`, the installer's `plugins.go` and `compose.go`). UTMStack doesn't support it, so validate it after each major upgrade.
* **Detection only.** The plugin doesn't block anything. For prevention, point your Palo Alto EDL or FortiGate external threat feed at MISP's text export as well.
* **Replaces the earlier draft.** This supersedes the parsing-plugin draft (`main.go` and `misp_ioc_match_rule.yaml`) shared earlier. You don't need that separate rule.

## 8. Build from source (optional)

```bash
./build.sh                       # needs Go >= 1.25.5, or Docker
GOARCH=arm64 ./build.sh          # cross-compile
cd plugin && go test ./...       # unit tests
WORK_DIR=$(mktemp -d) go test -tags integration -run Integration -v .   # gRPC end-to-end test
```

The tests cover: MISP pagination and query filters; threat-level mapping; composite types (`domain|ip`, `filename|sha256`); CIDR, subdomain, URL-host, hash, and email matching; the allowlist; TLS verification being on by default; config parsing; the cache round trip; suppression; the severity and data-type filters; and a full gRPC `Analyze` call over the unix socket with the pipeline config merge.
