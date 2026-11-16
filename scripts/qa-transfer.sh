#!/usr/bin/env bash
# Sends testnet sats from a QA wallet to a testnet address.
#
#   scripts/qa-transfer.sh <testnet-address> <sats> [A|B|T]
#
# The paying wallet is HMAC(ONESAT_QA_ROOT, "<ONESAT_QA_SET>/<role>"), role T by default.
# ONESAT_QA_ROOT comes from the environment, or on macOS from the keychain item onesat-qa-root.
# ONESAT_QA_SET defaults to mac on macOS and sandbox elsewhere. Testnet only: the tool refuses a
# mainnet address, a mainnet host and more than 10,000,000 sats.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -lt 2 || $# -gt 3 ]]; then
	echo "usage: scripts/qa-transfer.sh <testnet-address> <sats> [A|B|T]" >&2
	exit 64
fi

case "$1" in
m* | n*) ;;
*)
	echo "refusing: $1 is not a testnet P2PKH address (testnet addresses start with m or n)" >&2
	exit 65
	;;
esac

if [[ -z "${ONESAT_QA_ROOT:-}" ]]; then
	if [[ "$(uname)" == "Darwin" ]]; then
		keychain_error="$(mktemp)"
		if ! ONESAT_QA_ROOT="$(security find-generic-password -s onesat-qa-root -w 2>"$keychain_error")"; then
			echo "ONESAT_QA_ROOT is unset and reading the keychain item onesat-qa-root failed: $(cat "$keychain_error")" >&2
			rm -f "$keychain_error"
			exit 66
		fi
		rm -f "$keychain_error"
	else
		echo "ONESAT_QA_ROOT is unset" >&2
		exit 66
	fi
fi

if [[ -z "${ONESAT_QA_SET:-}" ]]; then
	if [[ "$(uname)" == "Darwin" ]]; then ONESAT_QA_SET=mac; else ONESAT_QA_SET=sandbox; fi
fi

export ONESAT_QA_ROOT ONESAT_QA_SET
export ONESAT_LIVE=testnet
export ONESAT_TRANSFER_TO="$1" ONESAT_TRANSFER_SATS="$2" ONESAT_TRANSFER_FROM="${3:-T}"

cd "$ROOT"
exec swift test --filter 'OneSatLiveTests.TestnetTransfer'
