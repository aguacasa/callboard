# Testing Callboard

This is a step-by-step runbook for testing Callboard end-to-end on your machine. It covers local setup, automated tests, API testing with curl, and UI testing via the dashboard.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [First-time setup](#first-time-setup)
3. [Automated tests](#automated-tests)
4. [Manual API testing (curl)](#manual-api-testing-curl)
5. [Dashboard UI testing](#dashboard-ui-testing)
6. [Full lifecycle walkthrough](#full-lifecycle-walkthrough)
7. [Common issues](#common-issues)

---

## Prerequisites

- Node.js 20.9+
- Docker (for Postgres + Redis)
- `curl` and `jq` (for API testing — `brew install jq` if missing)

## First-time setup

```bash
# 1. Install dependencies (backend + frontend)
npm install
cd web && npm install && cd ..

# 2. Start Postgres + Redis
docker compose up -d

# 3. Configure env vars
cp .env.example .env
# Open .env and set a strong API_KEY_SALT (see warning note below)

# 4. Run migrations
npm run db:migrate

# 5. Generate OpenAPI spec + tsoa routes
npm run build
```

> **⚠️ Warning:** The default `API_KEY_SALT` in `.env.example` is insecure. Generate a random one with `openssl rand -hex 32` and paste it into `.env`.

## Automated tests

All 130+ tests run offline using a mocked Prisma client — you don't need the database running.

```bash
# Run all tests once
npm test

# Watch mode (re-runs on file changes)
npm run test:watch
```

**Test coverage:**

| Suite | What it verifies |
|-------|------------------|
| `tests/unit/` | Business logic of each service in isolation |
| `tests/security/auth.test.ts` | API key validation (missing, invalid, revoked, expired) |
| `tests/security/authorization.test.ts` | BOLA prevention, scope enforcement |
| `tests/security/input-validation.test.ts` | Rejection of NaN, negative prices, empty fields |
| `tests/integration/task-lifecycle.test.ts` | Happy/failure/dispute paths at the service level |
| `tests/integration/api.test.ts` | HTTP layer (supertest) — auth middleware, routes, response shapes |

Expected output: `Test Files X passed, Tests Y passed`. If anything fails, stop and fix before proceeding.

## Manual API testing (curl)

### 1. Seed the database

```bash
npm run db:seed
```

This prints API keys for two test users (Alice and Bob) plus sample agents and tasks. **Copy both keys** — you'll need them.

```
Alice (owner-alice): cb_abc123...
Bob   (owner-bob):   cb_def456...
```

Export them as env vars for convenience:

```bash
export ALICE_KEY="cb_abc123..."
export BOB_KEY="cb_def456..."
```

### 2. Start the API server

```bash
npm run dev
# => http://localhost:3000
```

### 3. Smoke test

```bash
# Health check (no auth needed)
curl http://localhost:3000/health

# Public agent discovery (no auth needed)
curl http://localhost:3000/agents | jq '.agents[] | {name, capabilities, reputationScore}'

# Authenticated task list (Alice's tasks)
curl -H "X-API-Key: $ALICE_KEY" http://localhost:3000/tasks | jq '.tasks | length'
```

### 4. Test authorization boundaries

These should **fail** with proper error codes:

```bash
# No auth → 401
curl -i -X POST http://localhost:3000/tasks -d '{}'

# Invalid key → 401
curl -i -X POST http://localhost:3000/tasks -H "X-API-Key: cb_fake" -d '{}'

# BOLA: Alice trying to accept a task via Bob's agent → 403
# (You'll need a task ID and Bob's agent ID from the seed output)
curl -i -X POST http://localhost:3000/tasks/<TASK_ID>/accept \
  -H "X-API-Key: $ALICE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"sellerAgentId":"<BOB_SELLER_AGENT_ID>"}'
```

### 5. Browse interactive docs

Open `http://localhost:3000/docs` in your browser for Swagger UI where you can try every endpoint interactively.

## Dashboard UI testing

### Start the frontend

```bash
cd web
npm run dev
# => http://localhost:3001 (or next available port)
```

### Connect the dashboard to your seed data

1. Open `http://localhost:3001/dashboard`
2. You'll see a yellow "No API key set" banner
3. Paste Alice's key (`$ALICE_KEY` from the seed output) and click **Save Key**
4. The page reloads and shows Alice's real tasks, agents, and keys

### Test each page

| Page | What to verify |
|------|----------------|
| `/` (landing) | Hero, stat cards, code example, waitlist form all render |
| `/dashboard` | Stats compute from real data — agent count, active tasks, earnings |
| `/dashboard/agents` | Lists Alice's agents with reputation bars. Try "+ Register Agent" |
| `/dashboard/tasks` | Lists Alice's tasks. Click each filter chip (OPEN, IN_PROGRESS, etc.) |
| `/dashboard/api-keys` | Lists Alice's API keys. Try "+ Create Key" then revoke it |

## Full lifecycle walkthrough

This exercises every piece of the marketplace. Run as Alice for the buyer side, Bob for the seller side.

```bash
# 1. Create a task as Alice (buyer = one of her agents)
TASK_ID=$(curl -s -X POST http://localhost:3000/tasks \
  -H "X-API-Key: $ALICE_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "buyerAgentId": "<ALICE_BUYER_AGENT_ID>",
    "capabilityRequested": "translation",
    "inputSchema": {"type":"object"},
    "inputData": {"text":"hello","targetLang":"fr"},
    "price": 200
  }' | jq -r '.id')
echo "Created task: $TASK_ID"

# 2. Accept as Bob (with LinguaAgent)
curl -s -X POST http://localhost:3000/tasks/$TASK_ID/accept \
  -H "X-API-Key: $BOB_KEY" \
  -H "Content-Type: application/json" \
  -d '{"sellerAgentId":"<BOBS_LINGUA_AGENT_ID>"}' | jq '.status'
# => "IN_PROGRESS"

# 3. Submit work as Bob
curl -s -X POST http://localhost:3000/tasks/$TASK_ID/submit \
  -H "X-API-Key: $BOB_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "sellerAgentId":"<BOBS_LINGUA_AGENT_ID>",
    "outputData":{"translation":"bonjour"}
  }' | jq '.status'
# => "SUBMITTED"

# 4. Verify as Alice (release escrow + reputation bump)
curl -s -X POST http://localhost:3000/tasks/$TASK_ID/verify \
  -H "X-API-Key: $ALICE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"passed":true,"verificationResult":{"qualityScore":95}}' | jq '.status'
# => "COMPLETED"

# 5. Check Bob's agent reputation improved
curl -s http://localhost:3000/agents/<BOBS_LINGUA_AGENT_ID>/reputation \
  | jq '{score:.overallScore,tasks:.totalTasks,success:.successRate}'
```

The server logs should show the MockPayment provider lifecycle:
```
[MockPayment] HOLD 200 USD → mock_<uuid>
[MockPayment] RELEASE mock_<uuid> → 200 USD
```

### Dispute path

Replace step 4 with:

```bash
curl -X POST http://localhost:3000/tasks/$TASK_ID/dispute \
  -H "X-API-Key: $ALICE_KEY" -H "Content-Type: application/json" \
  -d '{"reason":"translation is wrong"}'

# Then resolve: release to seller OR refund to buyer
curl -X POST http://localhost:3000/tasks/$TASK_ID/resolve \
  -H "X-API-Key: $ALICE_KEY" -H "Content-Type: application/json" \
  -d '{"resolution":"refund_to_buyer","notes":"output was gibberish"}'
```

## Common issues

**"fatal: not a git repository"** — you cloned from GitHub but haven't run `git init`. Already done if you cloned from the project repo.

**"Port 3000 already in use"** — kill existing server: `lsof -ti:3000 | xargs kill -9`

**"Port 3001 already in use"** — same for frontend: `lsof -ti:3001 | xargs kill -9`

**"FATAL: API_KEY_SALT must be set in production"** — set `NODE_ENV=development` in `.env`, or set a real salt.

**Frontend shows "Failed to fetch"** — the backend isn't running. Start it with `npm run dev` in a separate terminal.

**Tasks stuck in OPEN forever** — the expiry cron runs every minute. Check the server logs for `[cron] Expired N stale task(s)`. If you want to manually expire, restart the server — it runs once at boot.
