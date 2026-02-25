# OpenClaw on DigitalOcean (Git pull, no Docker)

## 1) Prepare local files
```bash
cp config/do.env.example config/do.env
cp secrets/do.env.example secrets/do.env
```

Fill at minimum in `secrets/do.env`:
- `DO_TOKEN`
- `OPENCLAW_GATEWAY_TOKEN`
- `OPENAI_API_KEY`

Create your own public Git repository (can be empty), then set `REPO_URL` in `config/do.env` to that repo URL.
Defaults in `config/do.env`:
- `DEPLOY_REF=openclaw-deploy`
- `AUTO_SYNC_DEPLOY_REPO=true`

With defaults, `./do.sh` auto-syncs this template into your repo branch `openclaw-deploy` before install/update.

## 2) One-command install
```bash
./do.sh install
```

This command:
- syncs deployment template files to your `REPO_URL` branch
- creates DigitalOcean SSH key + droplet + SSH-only firewall
- bootstraps VPS packages and Node 22
- installs pinned `openclaw` version (skips reinstall if already pinned)
- configures `systemd` (`openclaw-gateway.service`, user `openclaw`)
- enables service in bootstrap, then starts/restarts only once during final apply
- runs smoke checks
- prints tokenized dashboard URL at the very end (after checks pass)

## 3) Open dashboard through tunnel
Start tunnel locally:
```bash
./do.sh tunnel
```

`install`, `update`, and `rollback` print `openclaw dashboard --no-open` output at the end. Open that URL locally while tunnel is running.

## Update / rollback
Update to a specific tag/ref:
```bash
./do.sh update --to <TAG>
```

Rollback to previous known-good deploy:
```bash
./do.sh rollback --previous
```

Rollback to explicit ref:
```bash
./do.sh rollback --to <TAG_OR_SHA>
```

## Status / logs / destroy
```bash
./do.sh status
./do.sh logs
./do.sh logs --follow
./do.sh destroy
```

## Security warning (`0.0.0.0/0`)
Default `SSH_ALLOWED_CIDRS='["0.0.0.0/0"]'` is convenient for dynamic IPs but less secure. Restrict it in `config/do.env`, for example:
```bash
SSH_ALLOWED_CIDRS='["203.0.113.10/32"]'
```

## Troubleshooting
- SSH refused:
  - wait 1-2 minutes after `terraform apply`, then retry `./do.sh status`
  - verify firewall CIDR includes your current IP
- Wrong key:
  - ensure local key files exist: `secrets/do_ssh_key` and `secrets/do_ssh_key.pub`
  - do not replace key files after install
- Pairing required:
  - run `./do.sh tunnel`, open tokenized dashboard URL, complete pairing/auth setup
- Gateway token missing / unauthorized:
  - set `OPENCLAW_GATEWAY_TOKEN` in `secrets/do.env`, rerun `./do.sh update --to <TAG>`
  - always use tokenized URL printed by `openclaw dashboard --no-open`
- OpenAI key typo:
  - OpenAI project keys usually start with `sk-proj-`, not `k-proj-`
  - fix `OPENAI_API_KEY` in `secrets/do.env`, run update again
- Service not active:
  - check `./do.sh status`
  - inspect logs with `./do.sh logs --follow`
  - on server: `systemctl status openclaw-gateway.service` and `journalctl -u openclaw-gateway -n 200 --no-pager`

## Private repo support (optional)
Default flow assumes public HTTPS clone (`REPO_URL=https://...git`). For private repositories, preconfigure server-side git credentials/SSH access for user `openclaw` and then set `REPO_URL` accordingly.
