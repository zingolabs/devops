#!/usr/bin/env bash
set -euo pipefail

# Seals the test wallet fixtures used by the wallet-sync and payment workflows
# into SealedSecrets under platform/wallet-fixtures/:
#   sealed-wallet-a.yaml        payment fixture A
#   sealed-wallet-b.yaml        payment fixture B
#   sealed-wallet-devsync.yaml  full-sync check wallet (known-leaked, non-critical)
#
# Each secret holds the wallet's BIP39 mnemonic plus its birthday height, so a
# wallet can be restored anywhere with:
#   zcash-devtool wallet -w <dir> restore-mnemonic --birthday <birthday> ... < mnemonic
#
# The mnemonics are NEVER stored in this script. Supply them via the
# environment; each wallet is sealed only if its mnemonic is set, so you can
# reseal one without re-supplying the others, e.g.:
#   read -rs WALLET_DEVSYNC_MNEMONIC; export WALLET_DEVSYNC_MNEMONIC
#   ./scripts/seal-wallet-fixtures.sh
#
# The A/B wallets are throwaway mainnet test wallets holding a token amount; the
# devsync wallet is a known-leaked test wallet with a small shielded balance.
# Do not put anything of value in any of them.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTEXT="${KUBECONTEXT:-zingo-infra}"
NS="wallet-fixtures"

# The chart installs the controller as `sealed-secrets` in kube-system, not
# kubeseal's default `sealed-secrets-controller`, so name it explicitly.
CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets}"
CONTROLLER_NS="${CONTROLLER_NS:-kube-system}"

# Birthday = chain height when the wallet was created. Public.
WALLET_A_BIRTHDAY="${WALLET_A_BIRTHDAY:-3480072}"        # 2026-09-11
WALLET_B_BIRTHDAY="${WALLET_B_BIRTHDAY:-3480072}"        # 2026-09-11
WALLET_DEVSYNC_BIRTHDAY="${WALLET_DEVSYNC_BIRTHDAY:-2800000}"

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
  echo "  sealed -> platform/wallet-fixtures/sealed-$name.yaml"
}

echo "Sealing wallet fixtures into $NS (only wallets whose mnemonic is set)..."
sealed_any=0
if [ -n "${WALLET_A_MNEMONIC:-}" ]; then
  seal wallet-a "$WALLET_A_MNEMONIC" "$WALLET_A_BIRTHDAY"; sealed_any=1
else
  echo "  skip wallet-a (WALLET_A_MNEMONIC unset)"
fi
if [ -n "${WALLET_B_MNEMONIC:-}" ]; then
  seal wallet-b "$WALLET_B_MNEMONIC" "$WALLET_B_BIRTHDAY"; sealed_any=1
else
  echo "  skip wallet-b (WALLET_B_MNEMONIC unset)"
fi
if [ -n "${WALLET_DEVSYNC_MNEMONIC:-}" ]; then
  seal wallet-devsync "$WALLET_DEVSYNC_MNEMONIC" "$WALLET_DEVSYNC_BIRTHDAY"; sealed_any=1
else
  echo "  skip wallet-devsync (WALLET_DEVSYNC_MNEMONIC unset)"
fi

if [ "$sealed_any" = "0" ]; then
  echo "Nothing sealed: set at least one of WALLET_{A,B,DEVSYNC}_MNEMONIC." >&2
  exit 1
fi
echo "Done. Commit the sealed files; ArgoCD applies them to $NS."
