Do not modify files.

Verify BuilderOS personalisation after launch using read-only checks only.

Run:

```bash
pwd
echo sentinel
ls -la ~/.builderos-personalisation 2>&1 || true
echo install-log
cat ~/.builderos-personalisation/install.log 2>&1 || true
echo preflight-log
cat ~/.builderos-personalisation/sona-preflight.log 2>&1 || true
echo preflight-out-tail
tail -80 ~/.builderos-personalisation/sona-preflight.out 2>&1 || true
echo preflight-pid
cat ~/.builderos-personalisation/sona-preflight.pid 2>&1 || true
echo codex
test -f ~/.codex/config.toml && grep -n tidewave_sona ~/.codex/config.toml || echo missing-codex-tidewave
test -d ~/.codex/skills/caveman && echo codex-caveman-ok || echo missing-codex-caveman
echo claude
claude plugin list 2>&1 || true
echo docker
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
cd /home/dev/project && docker compose ps 2>&1 || true
```

Report concise results and do not run tests.
