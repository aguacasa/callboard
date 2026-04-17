#!/usr/bin/env bash
# End-to-end verification of Callboard, following web/src/app/docs/build-an-agent
# and the lifecycle documented in TESTING.md.
#
# Drives the full marketplace flow against a running API:
#   - bootstrap a buyer + seller agent (no pre-seeded keys)
#   - search the agent registry (public)
#   - rank candidates via /agents/match (auth)
#   - create a task (escrow held)
#   - accept, submit, verify (escrow released, reputation updated)
#   - run the dispute → resolve path on a second task
#   - assert the documented error shapes (401, 403, 404, 409)
#
# Usage:
#   bash scripts/e2e.sh                    # uses BASE=http://localhost:3000
#   BASE=http://localhost:4000 bash ...    # override
#
# Exits non-zero on the first failed assertion. Designed for human eyes —
# every step prints what it ran and what it got back. Fixtures are left in
# the database so you can poke at them in /dashboard.

set -euo pipefail

BASE="${BASE:-http://localhost:3000}"
# Unique capability per run so we don't collide with leftover fixtures from
# previous E2E runs (the matching test wants to assert "our" seller is on top).
CAP="e2e-translation-$$-$RANDOM"
PASS=0
FAIL=0

# ─── Colors ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; CYAN=$'\033[0;36m'
  YELLOW=$'\033[0;33m'; DIM=$'\033[0;90m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; CYAN=""; YELLOW=""; DIM=""; BOLD=""; RESET=""
fi

step()    { printf "\n${BOLD}${CYAN}▸ %s${RESET}\n" "$*"; }
note()    { printf "${DIM}  %s${RESET}\n" "$*"; }
pass()    { PASS=$((PASS+1)); printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
fail()    { FAIL=$((FAIL+1)); printf "  ${RED}✗ %s${RESET}\n" "$*"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label = $actual"
  else
    fail "$label expected=$expected actual=$actual"
  fi
}

assert_in() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    pass "$label contains '$needle'"
  else
    fail "$label missing '$needle' (got: $haystack)"
  fi
}

# Per-pid scratch path so concurrent runs don't clobber each other.
BODY_FILE="/tmp/cb_body.$$"
trap 'rm -f "$BODY_FILE"' EXIT

# Fetch with a custom flag for the final HTTP status, so we can assert on it.
# Body is written to $BODY_FILE; read it with `cat "$BODY_FILE"` after the call.
http() {
  local method="$1" path="$2" key="${3:-}" body="${4:-}"
  local args=(-s -o "$BODY_FILE" -w '%{http_code}' -X "$method" "${BASE}${path}")
  args+=(-H "Content-Type: application/json")
  [ -n "$key" ] && args+=(-H "X-API-Key: $key")
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}"
}

# ─── Sanity: server is up ───────────────────────────────────────────────────
step "Pre-flight: server health"
HEALTH_CODE=$(http GET /health)
HEALTH=$(cat "$BODY_FILE")
note "GET /health → $HEALTH_CODE $HEALTH"
assert_eq "health status code" "200" "$HEALTH_CODE"
assert_eq "service name"        "callboard" "$(echo "$HEALTH" | jq -r .service)"

# ─── 1. Register seller (bootstrap, no auth) ────────────────────────────────
step "1. Bootstrap a seller agent (POST /agents, no auth)"
SELLER_NAME="E2E-Translator-$$"
SELLER_BODY=$(jq -nc \
  --arg name "$SELLER_NAME" \
  --arg cap "$CAP" \
  '{
    name:$name,
    description:"E2E seller, translates strings.",
    endpointUrl:"https://e2e.example.com/translate",
    capabilities:[$cap],
    pricingModel:"PER_TASK",
    pricePerUnit:200,
    currency:"USD",
    slaResponseMs:3000,
    slaUptimePct:99.0,
    authMethod:"API_KEY",
    sampleInput:{text:"hi",lang:"fr"},
    sampleOutput:{translation:"salut"}
  }')
note "POST /agents (seller)"
SELLER_CODE=$(http POST /agents "" "$SELLER_BODY")
SELLER_RESP=$(cat "$BODY_FILE")
assert_eq "seller create status" "201" "$SELLER_CODE"
SELLER_ID=$(echo "$SELLER_RESP" | jq -r '.agent.id')
SELLER_KEY=$(echo "$SELLER_RESP" | jq -r '.apiKey')
note "seller agent id: $SELLER_ID"
note "seller api key: ${SELLER_KEY:0:14}…"
[ "$SELLER_ID" != "null" ] && pass "seller has id" || fail "seller id missing"
[ -n "$SELLER_KEY" ] && [ "$SELLER_KEY" != "null" ] && pass "seller api key returned" || fail "seller key missing"
assert_eq "seller capability" "${CAP}" "$(echo "$SELLER_RESP" | jq -r '.agent.capabilities[0]')"

# ─── 2. Register buyer ──────────────────────────────────────────────────────
step "2. Bootstrap a buyer agent"
BUYER_NAME="E2E-Buyer-$$"
BUYER_BODY=$(jq -nc \
  --arg name "$BUYER_NAME" \
  '{
    name:$name,
    description:"E2E buyer, hires translators.",
    endpointUrl:"https://e2e.example.com/buyer",
    capabilities:["e2e-coordinator"],
    pricingModel:"PER_TASK",
    pricePerUnit:0,
    currency:"USD",
    slaResponseMs:1000,
    slaUptimePct:99.9,
    authMethod:"API_KEY"
  }')
BUYER_CODE=$(http POST /agents "" "$BUYER_BODY")
BUYER_RESP=$(cat "$BODY_FILE")
assert_eq "buyer create status" "201" "$BUYER_CODE"
BUYER_ID=$(echo "$BUYER_RESP" | jq -r '.agent.id')
BUYER_KEY=$(echo "$BUYER_RESP" | jq -r '.apiKey')
note "buyer agent id: $BUYER_ID"

# ─── 3. Public discovery ────────────────────────────────────────────────────
step "3. Public discovery (GET /agents)"
DISC_CODE=$(http GET "/agents?capability=${CAP}")
DISC=$(cat "$BODY_FILE")
assert_eq "search status" "200" "$DISC_CODE"
SELLER_FOUND=$(echo "$DISC" | jq -r --arg id "$SELLER_ID" '.agents[] | select(.id==$id) | .id')
assert_eq "seller is discoverable by capability" "$SELLER_ID" "$SELLER_FOUND"

# ─── 4. Match endpoint (auth, scope=read) ───────────────────────────────────
step "4. Rank candidates via POST /agents/match (auth required)"
MATCH_BODY=$(jq -nc --arg cap "$CAP" '{capability:$cap,maxPrice:500}')
MATCH_CODE=$(http POST /agents/match "$BUYER_KEY" "$MATCH_BODY")
MATCH=$(cat "$BODY_FILE")
assert_eq "match status" "200" "$MATCH_CODE"
TOP_ID=$(echo "$MATCH" | jq -r '.matches[0].agent.id // empty')
assert_eq "top match is our seller" "$SELLER_ID" "$TOP_ID"

# ─── 5. Buyer posts a task → escrow held → OPEN ─────────────────────────────
step "5. Buyer posts task (POST /tasks, escrow auto-held)"
TASK_BODY=$(jq -nc --arg b "$BUYER_ID" --arg cap "$CAP" \
  '{
    buyerAgentId:$b,
    capabilityRequested:$cap,
    inputSchema:{type:"object"},
    inputData:{text:"hello",targetLang:"fr"},
    price:200
  }')
TASK_CODE=$(http POST /tasks "$BUYER_KEY" "$TASK_BODY")
TASK=$(cat "$BODY_FILE")
assert_eq "task create status" "201" "$TASK_CODE"
TASK_ID=$(echo "$TASK" | jq -r '.id')
assert_eq "task starts OPEN" "OPEN" "$(echo "$TASK" | jq -r '.status')"
note "task id: $TASK_ID"

# ─── 6. Documented error shapes ─────────────────────────────────────────────
step "6. Documented error shapes (build-an-agent §6)"

# 401 — no key
NA_CODE=$(http POST /tasks "" "$TASK_BODY")
NA=$(cat "$BODY_FILE")
assert_eq "401 on missing key" "401" "$NA_CODE"
assert_in "401 body has UNAUTHORIZED code" "UNAUTHORIZED" "$NA"

# 401 — invalid key
INV_CODE=$(http POST /tasks "cb_definitely_fake_$$" "$TASK_BODY")
assert_eq "401 on invalid key" "401" "$INV_CODE"

# 403 — BOLA: seller tries to create task on buyer's agent
BOLA_CODE=$(http POST /tasks "$SELLER_KEY" "$TASK_BODY")
BOLA=$(cat "$BODY_FILE")
assert_eq "403 on cross-owner write" "403" "$BOLA_CODE"
assert_in "403 body has FORBIDDEN code" "FORBIDDEN" "$BOLA"

# 404 — unknown task id
NF_CODE=$(http GET "/tasks/00000000-0000-0000-0000-000000000000" "$BUYER_KEY")
assert_eq "404 on unknown task" "404" "$NF_CODE"

# 409 — illegal transition: verify before submit
EARLY_VERIFY_CODE=$(http POST "/tasks/${TASK_ID}/verify" "$BUYER_KEY" '{"passed":true}')
assert_eq "409 verify-before-submit" "409" "$EARLY_VERIFY_CODE"

# ─── 7. Seller accepts → IN_PROGRESS ────────────────────────────────────────
step "7. Seller accepts the task"
ACCEPT_BODY=$(jq -nc --arg s "$SELLER_ID" '{sellerAgentId:$s}')
ACC_CODE=$(http POST "/tasks/${TASK_ID}/accept" "$SELLER_KEY" "$ACCEPT_BODY")
ACC=$(cat "$BODY_FILE")
assert_eq "accept status" "200" "$ACC_CODE"
assert_eq "task is IN_PROGRESS" "IN_PROGRESS" "$(echo "$ACC" | jq -r '.status')"

# Capability gate: a fresh seller without the capability cannot accept
step "7b. Seller without the capability is rejected"
ROGUE_BODY=$(jq -nc --arg name "E2E-Rogue-$$" \
  '{name:$name,endpointUrl:"https://e2e.example.com/x",capabilities:["unrelated"]}')
http POST /agents "" "$ROGUE_BODY" > /dev/null
ROGUE_ID=$(jq -r '.agent.id' "$BODY_FILE")
ROGUE_KEY=$(jq -r '.apiKey' "$BODY_FILE")
# Need a fresh OPEN task to attempt acceptance against
T2_BODY=$(jq -nc --arg b "$BUYER_ID" --arg cap "$CAP" \
  '{buyerAgentId:$b,capabilityRequested:$cap,inputSchema:{},price:200}')
http POST /tasks "$BUYER_KEY" "$T2_BODY" > /dev/null
T2_ID=$(jq -r '.id' "$BODY_FILE")
ROGUE_ACC_CODE=$(http POST "/tasks/${T2_ID}/accept" "$ROGUE_KEY" "$(jq -nc --arg s "$ROGUE_ID" '{sellerAgentId:$s}')")
assert_eq "missing-capability accept rejected" "400" "$ROGUE_ACC_CODE"

# ─── 8. Seller submits → SUBMITTED ──────────────────────────────────────────
step "8. Seller submits work"
SUB_BODY=$(jq -nc --arg s "$SELLER_ID" \
  '{sellerAgentId:$s,outputData:{translation:"bonjour le monde"}}')
SUB_CODE=$(http POST "/tasks/${TASK_ID}/submit" "$SELLER_KEY" "$SUB_BODY")
SUB=$(cat "$BODY_FILE")
assert_eq "submit status" "200" "$SUB_CODE"
assert_eq "task is SUBMITTED" "SUBMITTED" "$(echo "$SUB" | jq -r '.status')"

# ─── 9. Buyer verifies → COMPLETED ──────────────────────────────────────────
step "9. Buyer verifies (escrow releases, reputation bumps)"
http GET "/agents/${SELLER_ID}/reputation" > /dev/null
BEFORE_TOTAL=$(jq -r '.totalTasks // 0' "$BODY_FILE")
note "seller reputation before: totalTasks=$BEFORE_TOTAL"

VER_CODE=$(http POST "/tasks/${TASK_ID}/verify" "$BUYER_KEY" \
  '{"passed":true,"verificationResult":{"qualityScore":95}}')
VER=$(cat "$BODY_FILE")
assert_eq "verify status" "200" "$VER_CODE"
assert_eq "task is COMPLETED" "COMPLETED" "$(echo "$VER" | jq -r '.status')"

http GET "/agents/${SELLER_ID}/reputation" > /dev/null
AFTER_TOTAL=$(jq -r '.totalTasks' "$BODY_FILE")
note "seller reputation after:  totalTasks=$AFTER_TOTAL"
if [ "$AFTER_TOTAL" -gt "$BEFORE_TOTAL" ]; then
  pass "totalTasks incremented ($BEFORE_TOTAL → $AFTER_TOTAL)"
else
  fail "totalTasks did not increment ($BEFORE_TOTAL → $AFTER_TOTAL)"
fi

# Buyer can read the task; outsider cannot.
step "9b. Task is scoped to its parties"
PARTY_CODE=$(http GET "/tasks/${TASK_ID}" "$BUYER_KEY")
assert_eq "buyer can read task" "200" "$PARTY_CODE"
OUT_CODE=$(http GET "/tasks/${TASK_ID}" "$ROGUE_KEY")
assert_eq "outsider gets 403" "403" "$OUT_CODE"

# ─── 10. Dispute → resolve path ─────────────────────────────────────────────
step "10. Dispute path on a second task"
T3_BODY=$(jq -nc --arg b "$BUYER_ID" --arg cap "$CAP" \
  '{buyerAgentId:$b,capabilityRequested:$cap,inputSchema:{},price:175}')
http POST /tasks "$BUYER_KEY" "$T3_BODY" > /dev/null
T3_ID=$(jq -r '.id' "$BODY_FILE")

# Drive to SUBMITTED first
http POST "/tasks/${T3_ID}/accept" "$SELLER_KEY" "$(jq -nc --arg s "$SELLER_ID" '{sellerAgentId:$s}')" > /dev/null
http POST "/tasks/${T3_ID}/submit" "$SELLER_KEY" "$(jq -nc --arg s "$SELLER_ID" '{sellerAgentId:$s,outputData:{translation:"garbage"}}')" > /dev/null

DIS_CODE=$(http POST "/tasks/${T3_ID}/dispute" "$BUYER_KEY" '{"reason":"output is wrong"}')
DIS=$(cat "$BODY_FILE")
assert_eq "dispute status" "200" "$DIS_CODE"
assert_eq "task is DISPUTED" "DISPUTED" "$(echo "$DIS" | jq -r '.status')"

RES_CODE=$(http POST "/tasks/${T3_ID}/resolve" "$BUYER_KEY" '{"resolution":"refund_to_buyer","notes":"E2E refund"}')
RES=$(cat "$BODY_FILE")
assert_eq "resolve status" "200" "$RES_CODE"
assert_eq "resolved as FAILED" "FAILED" "$(echo "$RES" | jq -r '.status')"

# ─── 11. API key management ─────────────────────────────────────────────────
step "11. API key management — create, list, revoke"
NEW_KEY_CODE=$(http POST /api-keys "$BUYER_KEY" '{"label":"E2E-extra","scopes":["read"]}')
NEW_KEY=$(cat "$BODY_FILE")
assert_eq "create key status" "201" "$NEW_KEY_CODE"
NEW_KEY_ID=$(echo "$NEW_KEY" | jq -r '.keyInfo.id // empty')
NEW_KEY_FULL=$(echo "$NEW_KEY" | jq -r '.key // empty')
[ -n "$NEW_KEY_FULL" ] && pass "new key returned in clear (one-time)" || fail "new key not returned"

LIST_CODE=$(http GET /api-keys "$BUYER_KEY")
LIST=$(cat "$BODY_FILE")
assert_eq "list keys status" "200" "$LIST_CODE"
LIST_HAS_FULL=$(echo "$LIST" | grep -c "$NEW_KEY_FULL" || true)
assert_eq "list never re-exposes the full key" "0" "$LIST_HAS_FULL"

if [ -n "$NEW_KEY_ID" ]; then
  REV_CODE=$(http DELETE "/api-keys/${NEW_KEY_ID}" "$BUYER_KEY")
  if [ "$REV_CODE" = "200" ] || [ "$REV_CODE" = "204" ]; then
    pass "revoke returned $REV_CODE"
  else
    fail "revoke unexpected status $REV_CODE"
  fi
  # After revoke, it should no longer authenticate
  REV_USE_CODE=$(http GET /tasks "$NEW_KEY_FULL")
  assert_eq "revoked key no longer authenticates" "401" "$REV_USE_CODE"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
printf "\n${BOLD}─── Summary ───${RESET}\n"
printf "  ${GREEN}passed: %d${RESET}\n" "$PASS"
printf "  ${RED}failed: %d${RESET}\n" "$FAIL"
echo
echo "Fixtures left in the database (no auto-cleanup) — open them in /dashboard:"
echo "  buyer  agent: $BUYER_ID"
echo "  seller agent: $SELLER_ID"
echo "  task happy:   $TASK_ID"
echo "  task dispute: $T3_ID"

[ "$FAIL" -eq 0 ]
