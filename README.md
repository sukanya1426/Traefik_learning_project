# Traefik + FastAPI on Hetzner

A production-ready setup that demonstrates how to run a **FastAPI** application on a **Hetzner VPS** behind **Traefik** as a reverse proxy, with automatic **HTTPS via Let's Encrypt** and **HTTP Basic Auth** protecting both the API and the Traefik dashboard.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Project Structure](#project-structure)
3. [How Each Piece Works](#how-each-piece-works)
   - [FastAPI](#fastapi)
   - [Docker & Docker Compose](#docker--docker-compose)
   - [Traefik as a Reverse Proxy](#traefik-as-a-reverse-proxy)
   - [HTTPS with Let's Encrypt (ACME)](#https-with-lets-encrypt-acme)
   - [HTTP Basic Auth](#http-basic-auth)
4. [Prerequisites](#prerequisites)
5. [Step-by-Step Deployment to Hetzner](#step-by-step-deployment-to-hetzner)
6. [Testing the Setup](#testing-the-setup)
7. [Useful Commands](#useful-commands)
8. [API Reference](#api-reference)
9. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Internet
    │
    │  HTTP :80   ─────────────────────────────────────────────┐
    │  HTTPS :443 ─────────────────────────────────────────────┤
    ▼                                                           │
┌─────────────────────────────────────────────────────────┐    │
│                      TRAEFIK                            │ ◄──┘
│                                                         │
│  ┌─────────────────┐   ┌───────────────────────────┐   │
│  │  HTTP → HTTPS   │   │  Let's Encrypt ACME       │   │
│  │  Redirect       │   │  (auto cert renewal)      │   │
│  └─────────────────┘   └───────────────────────────┘   │
│                                                         │
│  Routes:                                                │
│   api.yourdomain.com      ──────────────────► FastAPI :8000
│   traefik.yourdomain.com  ──────────────────► Dashboard (internal)
└─────────────────────────────────────────────────────────┘
         │  Basic Auth middleware applied on all routes
         │
         ▼
   Browser / curl must authenticate before reaching the app
```

**Traffic flow:**
1. User hits `http://api.yourdomain.com` → Traefik redirects to `https://`.
2. User hits `https://api.yourdomain.com` → Traefik checks Basic Auth → forwards to FastAPI.
3. FastAPI runs inside a Docker container, never directly exposed to the internet.
4. TLS certificates are obtained automatically from Let's Encrypt and stored in `traefik/acme.json`.

---

## Project Structure

```
.
├── app/
│   ├── main.py           # FastAPI application (routes, models)
│   ├── requirements.txt  # Python dependencies
│   └── Dockerfile        # Builds the FastAPI container image
│
├── traefik/
│   ├── traefik.yml       # Traefik static config (entrypoints, ACME, providers)
│   └── acme.json         # TLS cert storage — gitignored, chmod 600 required
│
├── docker-compose.yml    # Defines all services + Traefik labels (dynamic config)
├── .env.example          # Template for secrets — copy to .env
├── .env                  # Your actual secrets — gitignored, never commit
├── deploy.sh             # One-command deployment to Hetzner
└── README.md
```

---

## How Each Piece Works

### FastAPI

FastAPI is a modern Python web framework built on top of Starlette and Pydantic. It gives you:

- **Automatic API docs** at `/docs` (Swagger UI) and `/redoc`
- **Type validation** via Pydantic models — if a request body has the wrong type, FastAPI returns a 422 automatically
- **Async support** out of the box

The app runs on port `8000` inside its container using `uvicorn`, an ASGI server. Uvicorn is the production-grade server for async Python frameworks.

```
app/
├── main.py          # Route handlers using @app.get / @app.post etc.
├── requirements.txt # fastapi + uvicorn[standard] + pydantic
└── Dockerfile       # python:3.12-slim → pip install → uvicorn main:app
```

**The container is never exposed directly to the internet.** It only has a private Docker network interface that Traefik can reach.

---

### Docker & Docker Compose

Docker packages the FastAPI app and its dependencies into a portable image. The `Dockerfile` uses a layered approach:

1. Start from `python:3.12-slim` (small base image, ~50 MB)
2. Install Python dependencies (`pip install -r requirements.txt`) — this layer is cached unless `requirements.txt` changes
3. Copy the application code
4. Set the startup command: `uvicorn main:app --host 0.0.0.0 --port 8000`

Docker Compose orchestrates multiple containers (Traefik + FastAPI) and the shared network between them. The key concept here: **Traefik discovers services via Docker labels**. You don't write Traefik router config in a separate file — you annotate your containers directly.

---

### Traefik as a Reverse Proxy

Traefik has two types of configuration:

#### Static config (`traefik/traefik.yml`)
Set once at startup. Cannot change without restarting Traefik.
- **Entrypoints**: which ports to listen on (`web` = 80, `websecure` = 443)
- **Providers**: how to discover services (Docker in our case)
- **Certificate resolvers**: how to get TLS certs (Let's Encrypt)

#### Dynamic config (Docker labels in `docker-compose.yml`)
Reloaded automatically when containers change. This is where you define:
- **Routers**: match incoming requests to a service (e.g. `Host("api.yourdomain.com")`)
- **Middlewares**: transform requests/responses before they reach the service (e.g. basic auth, redirects, rate limiting)
- **Services**: the actual backend containers

**Example: how the FastAPI router is defined via labels:**

```yaml
labels:
  - "traefik.enable=true"

  # Router: match requests for api.yourdomain.com on port 443
  - "traefik.http.routers.api.rule=Host(`api.yourdomain.com`)"
  - "traefik.http.routers.api.entrypoints=websecure"

  # TLS: tell Traefik to terminate TLS and use the letsencrypt resolver
  - "traefik.http.routers.api.tls.certresolver=letsencrypt"

  # Middleware: apply basic auth before forwarding
  - "traefik.http.routers.api.middlewares=api-auth"

  # Service: tell Traefik the container listens on port 8000
  - "traefik.http.services.api.loadbalancer.server.port=8000"
```

**The naming convention matters:**
- `traefik.http.routers.<NAME>.rule` → defines router called `<NAME>`
- `traefik.http.middlewares.<NAME>.basicauth.users` → defines middleware called `<NAME>`
- `traefik.http.services.<NAME>.loadbalancer.server.port` → defines service called `<NAME>`

**Router → Middleware → Service** is the chain every request goes through.

---

### HTTPS with Let's Encrypt (ACME)

**What is Let's Encrypt?**
A free, automated Certificate Authority. It issues 90-day TLS certificates for your domain at no cost. Traefik renews them automatically ~30 days before expiry.

**What is ACME?**
The protocol Let's Encrypt uses to verify that you actually control the domain you're requesting a certificate for.

**How the HTTP-01 challenge works** (what we use):

```
1. Traefik asks Let's Encrypt:  "Please give me a cert for api.yourdomain.com"
2. Let's Encrypt responds:      "Prove you control that domain.
                                  Place this token at:
                                  http://api.yourdomain.com/.well-known/acme-challenge/<TOKEN>"
3. Traefik creates an ephemeral  HTTP router that serves the token on port 80
4. Let's Encrypt makes an HTTP   request to verify the token
5. Verification passes →         Let's Encrypt issues the certificate
6. Traefik stores cert+key in    traefik/acme.json
7. Traefik starts serving HTTPS  with the new cert
```

**Why HTTP-01 works even with HTTP→HTTPS redirect:**
Traefik has internal ACME challenge routing that takes priority over user-defined routers. The `/.well-known/acme-challenge/` path is served directly by Traefik's ACME client — the redirect middleware never fires for that path.

**The `acme.json` file:**
This file stores your private key and certificate. It must:
- Exist before Traefik starts: `touch traefik/acme.json`
- Have strict permissions: `chmod 600 traefik/acme.json`
- **Never be committed to git** (it's in `.gitignore`)

If you delete `acme.json`, Traefik will request new certificates on next start. Be careful — Let's Encrypt has rate limits (5 certs per domain per week on production).

**Let's Encrypt staging (for testing):**
If you're testing frequently, use the staging server to avoid rate limits. Add to `traefik/traefik.yml`:

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      caServer: "https://acme-staging-v02.api.letsencrypt.org/directory"
```

Staging certs are not trusted by browsers but confirm the flow works without hitting rate limits.

---

### HTTP Basic Auth

Basic Auth is a simple HTTP authentication mechanism:
1. Client makes a request without credentials
2. Server responds with `401 Unauthorized` and `WWW-Authenticate: Basic realm="..."`
3. Browser shows a login dialog; client retries with `Authorization: Basic <base64(user:password)>`
4. Traefik validates the password hash and allows or denies the request

**How Traefik implements it:**
Traefik's `basicauth` middleware stores a list of `user:hash` pairs. Passwords are hashed using bcrypt. Traefik never stores plaintext passwords.

**The `$$` escaping in docker-compose:**
In `docker-compose.yml`, `$` is a special character used for variable interpolation (e.g. `${DOMAIN}`). To include a literal `$` in a label value, you must double it to `$$`. Since bcrypt hashes contain many `$` signs, every `$` in the hash must become `$$` in the docker-compose file.

Example:
```
htpasswd generates:    admin:$2y$05$abc123...
In docker-compose:     admin:$$2y$$05$$abc123...
```

The `sed 's/\$/\$\$/g'` command does this replacement automatically.

---

## Prerequisites

### Local machine
- SSH configured for the Hetzner server (see Step 1)
- `htpasswd` installed: `brew install httpd` on macOS

### Hetzner server
- Ubuntu 22.04 (or similar) with root access at `37.27.203.157`
- Ports 80 and 443 open in the firewall
- Docker (the `deploy.sh` script installs it automatically if missing)

### DNS — required for Let's Encrypt
You need a domain with **two A records** pointing to `37.27.203.157`:

```
api.yourdomain.com     →  37.27.203.157
traefik.yourdomain.com →  37.27.203.157
```

> DNS changes can take up to 24 hours to propagate, but usually under 5 minutes with TTL=300.
> Let's Encrypt will fail if DNS is not propagated yet — check with `nslookup api.yourdomain.com`.

---

## Step-by-Step Deployment to Hetzner

### Step 1: Configure SSH

Make sure `~/.ssh/config` has an entry for the Hetzner server:

```
Host hetzner
    HostName 37.27.203.157
    User root
    IdentityFile /Users/mahdiya/Downloads/id_hetzner.pem
```

Test it:
```bash
ssh hetzner "echo connected"
```

> The PEM file must have strict permissions: `chmod 400 ~/Downloads/id_hetzner.pem`

### Step 2: Open firewall ports on the server

```bash
ssh hetzner "ufw allow 80/tcp && ufw allow 443/tcp && ufw reload"
```

Check if ufw is active first:
```bash
ssh hetzner "ufw status"
```

### Step 3: Point DNS to your server

In your domain registrar or DNS provider, create:

| Type | Name    | Value         | TTL |
|------|---------|---------------|-----|
| A    | api     | 37.27.203.157 | 300 |
| A    | traefik | 37.27.203.157 | 300 |

Verify DNS has propagated:
```bash
nslookup api.yourdomain.com
# Should return: Address: 37.27.203.157
```

### Step 4: Generate basic auth credentials

Install `htpasswd`:
```bash
brew install httpd   # macOS
```

Generate a hashed credential (bcrypt):
```bash
# -n = print to stdout, -B = use bcrypt
htpasswd -nB admin
# Enter your password when prompted
# Output: admin:$2y$05$xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Escape $ signs for use in docker-compose / .env:
htpasswd -nB admin | sed 's/\$/\$\$/g'
# Output: admin:$$2y$$05$$xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Do this twice — once for the dashboard user, once for the API user.

### Step 5: Create your `.env` file

```bash
cp .env.example .env
```

Open `.env` and fill in your values:

```bash
DOMAIN=yourdomain.com
LETSENCRYPT_EMAIL=you@yourdomain.com
TRAEFIK_DASHBOARD_AUTH=admin:$$2y$$05$$<your-escaped-hash>
API_AUTH=user:$$2y$$05$$<your-escaped-hash>
```

### Step 6: Deploy

```bash
./deploy.sh
```

The script will:
1. Check that Docker is installed on the server (and install if missing)
2. Create `/opt/traefik-fastapi/` directory structure on the server
3. Copy all project files via `scp`
4. Create `acme.json` with `chmod 600` on the server
5. Run `docker compose up -d --build`
6. Print the live URLs when done

### Step 7: Verify

```bash
# Check containers are running
ssh hetzner "cd /opt/traefik-fastapi && docker compose ps"

# Stream logs
ssh hetzner "cd /opt/traefik-fastapi && docker compose logs -f"

# Test HTTPS (replace with your credentials and domain)
curl -u user:yourpassword https://api.yourdomain.com/health

# Test HTTP → HTTPS redirect (should return 301)
curl -v http://api.yourdomain.com/
```

---

## Testing the Setup

### API endpoints

```bash
BASE="https://api.yourdomain.com"
AUTH="-u user:yourpassword"

# Health check
curl $AUTH $BASE/health

# List items
curl $AUTH $BASE/items

# Get single item
curl $AUTH $BASE/items/1

# Create item
curl $AUTH -X POST $BASE/items \
  -H "Content-Type: application/json" \
  -d '{"name":"Thingamajig","description":"Indispensable","price":14.99}'

# Delete item
curl $AUTH -X DELETE $BASE/items/4
```

### Swagger UI

Open in browser: `https://api.yourdomain.com/docs`

The browser will ask for Basic Auth credentials (the ones you set as `API_AUTH`). After authenticating, the Swagger UI lets you test all endpoints interactively.

### Traefik Dashboard

Open: `https://traefik.yourdomain.com`

The dashboard shows:
- All active routers, middlewares, and services
- Which routes are matched by which rules
- TLS certificate status
- Health of backend services

### Verify TLS certificate

```bash
echo | openssl s_client -connect api.yourdomain.com:443 -servername api.yourdomain.com 2>/dev/null \
  | openssl x509 -noout -issuer -dates
# Should show: issuer= /C=US/O=Let's Encrypt/CN=...
```

---

## Useful Commands

```bash
# SSH into server
ssh hetzner

# On the server:
cd /opt/traefik-fastapi

# View running containers
docker compose ps

# Stream logs from all services
docker compose logs -f

# Stream Traefik logs only
docker compose logs -f traefik

# Restart the API after code change
docker compose up -d --build api

# Stop everything
docker compose down

# Stop and remove volumes (WARNING: deletes acme.json = lose certs)
docker compose down -v
```

---

## API Reference

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Root — welcome message + links |
| GET | `/health` | Health check (liveness probe) |
| GET | `/items` | List all items |
| GET | `/items/{id}` | Get item by ID |
| POST | `/items` | Create a new item |
| DELETE | `/items/{id}` | Delete an item |

All endpoints require HTTP Basic Auth credentials (set via `API_AUTH` in `.env`).

**POST /items request body:**
```json
{
  "name": "string",
  "description": "string (optional)",
  "price": 0.0
}
```

Full interactive docs available at: `https://api.yourdomain.com/docs`

---

## Troubleshooting

### Let's Encrypt certificate not issued

**Symptoms:** `https://` gives a certificate error or Traefik logs show ACME errors.

**Check:**
1. DNS resolves: `nslookup api.yourdomain.com` must return `37.27.203.157`
2. Port 80 is reachable: `curl -v http://api.yourdomain.com` from outside the server
3. Traefik logs: `docker compose logs traefik | grep -i acme`
4. `acme.json` permissions: `ls -la traefik/acme.json` must show `-rw-------`

If you hit rate limits, switch to [Let's Encrypt staging](#https-with-lets-encrypt-acme).

---

### Basic auth not working / 401 on everything

**Symptoms:** Every request returns `401 Unauthorized` even with correct credentials.

**Check:**
1. Test credentials: `curl -u user:yourpassword https://api.yourdomain.com/health`
2. Every `$` in the hash in `.env` must be doubled to `$$`
3. Re-run `docker compose up -d` after any `.env` change

---

### 502 Bad Gateway

**Symptoms:** Traefik returns 502.

**Causes:**
- FastAPI container is not running: `docker compose ps`
- FastAPI crashed: `docker compose logs api`
- Wrong port in labels: verify `traefik.http.services.api.loadbalancer.server.port=8000`

---

### Dashboard shows no routes

**Symptoms:** Traefik dashboard is empty.

**Check:**
- `traefik.enable=true` label is present on the `api` service
- All services are on the same Docker network (`traefik-net`): `docker network inspect traefik-net`

---

### Container exits immediately

```bash
docker compose logs api       # See the Python traceback
docker compose logs traefik   # See Traefik startup errors
```

Common FastAPI cause: syntax error in `main.py`. Fix and run `docker compose up -d --build api`.
