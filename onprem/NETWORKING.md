# fbt on-prem networking plan

Status: NOT IMPLEMENTED. Local builds only. No listener, no port, nothing below is wired up.

When ready, expose the pipelines over the LAN so devices like the Chromebook can submit projects and fetch artifacts.

## Intended shape

```text
# Chromebook -> http://server:8471/v1/build (tarball + JSON params)
# Server queues one job at a time, runs onprem/pipelines/*.sh, serves artifact
# Bearer token auth, LAN bind only, no inbound ports opened elsewhere
```

## API sketch

```bash
# Submit a build (project tarball + options)
# POST /v1/build -> {"id": "<jobid>"}
curl -H "Authorization: Bearer $FBT_SERVER_TOKEN" \
  -F "src=@src.tar.gz" \
  -F "pipeline=android" -F "variant=release" -F "sign=true" \
  http://server:8471/v1/build

# Poll status
# GET /v1/jobs/<id> -> {"state": "queued|running|done|failed", "log_tail": "..."}
curl -H "Authorization: Bearer $FBT_SERVER_TOKEN" \
  http://server:8471/v1/jobs/<id>

# Fetch artifact
# GET /v1/jobs/<id>/artifact -> binary download
curl -H "Authorization: Bearer $FBT_SERVER_TOKEN" \
  -o app-release.apk http://server:8471/v1/jobs/<id>/artifact

# Health
# GET /v1/health -> {"ok": true}
curl http://server:8471/v1/health
```

## Server sketch

```python
# Minimal stdlib HTTP service; shell out to pipelines/, one job at a time.
# Jobs live under ~/fbt-data/<id>/{src,dist,log}. FIFO queue, keep last N.
# Auth: compare Authorization header to FBT_SERVER_TOKEN with hmac.compare_digest.
# Bind 127.0.0.1 first; switch to 0.0.0.0 only when LAN access is approved.
# Limits: max upload size, per-job timeout (60 min android / 45 others),
#   artifact retention 14 days, auto-cleanup temp dirs on done/failed.
```

```ini
# ~/.config/systemd/user/fbt-server.service (draft)
# [Unit]
# Description=fbt on-prem build server
# After=network.target
# [Service]
# ExecStart=/usr/bin/python3 /path/to/onprem/server/serve.py --bind 127.0.0.1 --port 8471
# Restart=on-failure
# [Install]
# WantedBy=default.target
```

## Rollout checklist

```bash
# 1. Pick port + token
export FBT_SERVER_PORT=8471
export FBT_SERVER_TOKEN="$(openssl rand -hex 32)"  # store once, copy to clients

# 2. Localhost smoke test (server on 127.0.0.1, client on same host)
# 3. Switch bind to 0.0.0.0, set static IP or hostname.local for this host
# 4. Chromebook: POST tarball created by the same package_project() excludes
# 5. Signing stays server-side: clients send sign=true, key never leaves disk
# 6. Later, optional: TLS via caddy or Tailscale for off-LAN use
```

## Security notes

- Token is the only auth in v1; use a long random value, rotate by replacing the file and restarting.
- Validate every field server-side with the same allowlists the pipeline scripts use (variant, abis, target, features, goos/goarch, runtime).
- Never run untrusted Gradle/cargo as root; run as this user, one job at a time.
- Keep `~/fbt-data` downloads prunable; shred signing temp dirs even on failure (pipelines already do this).
