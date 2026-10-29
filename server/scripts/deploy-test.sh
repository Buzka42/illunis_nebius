#!/usr/bin/env bash
# Test deploy (no secrets here). Testing runs on free Nemotron models via OpenRouter; Nebius is final-build only. Usage: scripts/deploy-test.sh <hermes-quick-tunnel-url>
set -euo pipefail
cd "$(dirname "$0")/.."
HERMES_URL=${1:?hermes quick tunnel url}
npx --no-install wrangler deploy \
  --var REPLY_PROVIDER:openrouter_poc --var REPLY_LLM_MODEL:nvidia/nemotron-3.5-lightning:free \
  --var COUNCIL_TEST_PROVIDER:openrouter_poc \
  --var QUOTA_COUNCIL_PER_DAY:50 --var DATA_MODE:owner_any \
  --var HERMES_BASE_URL:"$HERMES_URL" \
  --var HERMES_SESSION_ID:local-7f42ceba0a8b89d9215ca1aa20138df124ed645a239d5473595de5cf748fdac4 \
  --var HERMES_ACCESS_MODE:quick_tunnel --var ASSISTANT_OWNER_DEVICE_ID:owner-test-device
