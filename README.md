# Traefik Learning Playground

A minimal Docker Compose project to learn Traefik reverse proxy fundamentals.

## Quick Start

```bash
docker compose up -d
```

Then open: http://admin.localhost (Traefik Dashboard)

## What's Running

| URL | Service | What It Does |
|-----|---------|-------------|
| http://app1.localhost | App 1 (Nginx) | Static HTML page |
| http://app2.localhost | App 2 (Nginx) | Static HTML page + custom header |
| http://api.localhost | API (Nginx) | JSON response (requires auth) |
| http://admin.localhost | Traefik Dashboard | See all routes, services, middlewares |
| http://localhost/app1 | App 1 via path | Path-based routing |
| http://localhost/app2 | App 2 via path | Path-based routing |

---

## Step 1: Verify Routing

### Domain-based routing
```bash
curl http://app1.localhost
curl http://app2.localhost
```

### Path-based routing
```bash
curl http://localhost/app1
curl http://localhost/app2
```

### API with Basic Auth
```bash
# This returns 401 Unauthorized
curl http://api.localhost

# This works (username: user, password: traefik)
curl -u user:traefik http://api.localhost
```

### Dashboard
Open http://admin.localhost in your browser, or:
```bash
curl http://admin.localhost/api/overview | python3 -m json.tool
```

---

## Step 2: Understand the 5 Core Concepts

### 1. EntryPoints (ports Traefik listens on)
**File:** `traefik.yml`

EntryPoints define where traffic enters Traefik.
```yaml
entryPoints:
  web:
    address: ":80"        # HTTP
  websecure:
    address: ":443"       # HTTPS
```

### 2. Routers (who gets the request)
**File:** `docker-compose.yml` (Docker labels)

Routers match incoming requests to services using rules:
```yaml
# Domain-based: match by hostname
- "traefik.http.routers.app1.rule=Host(`app1.localhost`)"

# Path-based: match by URL path
- "traefik.http.routers.app1-path.rule=Host(`localhost`) && PathPrefix(`/app1`)"
```

See all routers:
```bash
curl http://localhost:8080/api/http/routers | python3 -m json.tool
```

### 3. Services (where to send the request)
Services are auto-created by the Docker provider from your container names. You don't need to configure them manually!

See all services:
```bash
curl http://localhost:8080/api/http/services | python3 -m json.tool
```

### 4. Middlewares (transform requests/responses)
**File:** `docker-compose.yml` (Docker labels)

This playground demonstrates 3 middlewares:

**StripPrefix** — removes `/app1` from the URL before forwarding to Nginx:
```bash
# Without stripprefix, Nginx would receive /app1 and return 404
curl http://localhost/app1    # Traefik strips /app1, Nginx gets /
```

**Custom Headers** — adds `X-Served-By: app2` to responses:
```bash
curl -v http://app2.localhost 2>&1 | grep X-Served-By
# Output: < X-Served-By: app2
```

**Basic Auth** — protects the API with username/password:
```bash
curl -v http://api.localhost          # 401 Unauthorized
curl -u user:traefik http://api.localhost  # 200 OK + JSON
```

### 5. Providers (how Traefik discovers services)
**File:** `traefik.yml`

The Docker provider watches for container changes in real-time:
```yaml
providers:
  docker:
    exposedByDefault: false   # Containers must opt-in
```

Try this — stop app1 and watch it disappear:
```bash
docker compose stop app1
curl http://app1.localhost      # 404 — it's gone!

docker compose start app1
curl http://app1.localhost      # It's back!
```

---

## Step 3: Real Project Mapping

This playground simulates a real microservices setup:

| Playground | Real Project Equivalent |
|-----------|----------------------|
| app1.localhost | app.yourdomain.com (NextJS frontend) |
| api.localhost | api.yourdomain.com (FastAPI backend) |
| admin.localhost | traefik.yourdomain.com (dashboard) |

To integrate Traefik into your real project:
1. Add a `traefik` service to your existing `docker-compose.yml`
2. Remove published ports from your app services
3. Add Traefik labels to each service
4. All traffic goes through Traefik on port 80/443

---

## Useful Commands

```bash
docker compose up -d          # Start everything
docker compose down           # Stop everything
docker compose logs -f traefik  # Watch Traefik logs
docker compose ps             # See running containers
```
