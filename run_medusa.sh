#!/bin/bash
# Reliable way to run Medusa fuzzing for Alignerz
# Ensure medusa, crytic-compile are installed

echo "Running Medusa Fuzzing Campaign..."
echo "Target: src/TVSMedusaHarness.sol"
echo "Contract: TVSMedusaHarness"
echo "Solc Version: 0.8.29 (configured in foundry.toml)"

# We run with explicit compilation target to avoid auto-discovery issues
# We use --target-contracts to explicitly select the harness contract from the file
medusa fuzz \
  --compilation-target src/TVSMedusaHarness.sol \
  --target-contracts TVSMedusaHarness \
  --test-limit 0 \
  --timeout 0 \
  --workers 10
