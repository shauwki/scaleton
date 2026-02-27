# Scaleton

Minimal, duplicable Docker skeleton for multi-domain stacks.

## What you get

- Base `compose.yaml` with only:
  - `traefik`
  - `cloudflared`
- Strong stack isolation using:
  - `name: ${STACK_ID}`
  - dedicated network `network-${STACK_ID}`
  - Traefik provider constraint on compose project label
- Interactive bootstrap via `./setup.sh init`

## Quick start

1. Clone/copy this repository.
2. Run interactive init:

```bash
./setup.sh init
```

3. Start edge services:

```bash
docker compose up -d
```

4. Verify dashboard:

- URL: `https://tre.<PRIMARY_DOMAIN>`
- Credentials: username you entered in setup + generated htpasswd password

## Commands

```bash
./setup.sh init
./setup.sh --validate
./setup.sh --gen-secrets
./setup.sh reset traefik-password
./setup.sh reset env STACK_ID
./setup.sh reset database-template
```

## Notes

- `./setup.sh init` creates/updates:
  - `.env`
  - `core/traefik/traefik.yml`
  - `core/traefik/users.htpasswd`
  - `core/database/init-databases.sh`
  - base project directories
- Keep domain/subdomain routes project-specific as you add new services.
- This skeleton is designed so multiple stacks can run on the same host without Traefik cross-project conflicts.
