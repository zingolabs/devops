#!/usr/bin/env bash
set -euo pipefail

# Seals the test wallet fixtures (wallet-a, wallet-b) used by the wallet-sync
# and payment workflows into SealedSecrets:
#   platform/wallet-fixtures/sealed-wallet-a.yaml
#   platform/wallet-fixtures/sealed-wallet-b.yaml
#
# Each secret holds the wallet's BIP39 mnemonic plus its birthday height, so a
# wallet can be restored anywhere with:
#   zcash-devtool wallet -w <dir> restore-mnemonic --birthday <birthday> ... < mnemonic
#
# The mnemonics are NEVER stored in this script. Supply them via the
# environment, e.g. read them into your shell first:
#   read -rs WALLET_A_MNEMONIC; export WALLET_A_MNEMONIC
#   read -rs WALLET_B_MNEMONIC; export WALLET_B_MNEMONIC
#   ./scripts/seal-wallet-fixtures.sh
#
# These are throwaway mainnet test wallets holding a token amount. Do not put
# anything of value in them.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTEXT="${KUBECONTEXT:-zingo-infra}"
NS="wallet-fixtures"

# The chart installs the controller as `sealed-secrets` in kube-system, not
# kubeseal's default `sealed-secrets-controller`, so name it explicitly.
CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets}"
CONTROLLER_NS="${CONTROLLER_NS:-kube-system}"

: "${WALLET_A_MNEMONIC:?set WALLET_A_MNEMONIC}"
: "${WALLET_B_MNEMONIC:?set WALLET_B_MNEMONIC}"

# Birthday = chain height when the wallet was created (2026-09-11). Public.
WALLET_A_BIRTHDAY="${WALLET_A_BIRTHDAY:-3480072}"
WALLET_B_BIRTHDAY="${WALLET_B_BIRTHDAY:-3480072}"

seal() {
  name="$1"; mnemonic="$2"; birthday="$3"
  kubectl create secret generic "$name" \
    --namespace="$NS" \
    --from-literal=mnemonic="$mnemonic" \
    --from-literal=birthday="$birthday" \
    --dry-run=client -o yaml \
    | kubeseal --context="$CONTEXT" --format=yaml \
        --controller-name="$CONTROLLER_NAME" \
        --controller-namespace="$CONTROLLER_NS" \
    > "$REPO_ROOT/platform/wallet-fixtures/sealed-$name.yaml"
  echo "  -> platform/wallet-fixtures/sealed-$name.yaml"
}

echo "Sealing wallet fixtures into $NS..."
seal wallet-a "$WALLET_A_MNEMONIC" "$WALLET_A_BIRTHDAY"
seal wallet-b "$WALLET_B_MNEMONIC" "$WALLET_B_BIRTHDAY"
echo "Done. Commit the sealed files; ArgoCD applies them to $NS."
