#!/usr/bin/env bash

check_ipfs() {
  local multiaddr="$1"
  echo "Using IPFS at $multiaddr"
  ipfs --api "${multiaddr}" id >&2
  return $?
}

if [[ -z $CERAMIC_HOST ]]; then
  echo "\$CERAMIC_HOST is unset. Skipping ceramic CLI initialization" >&2
else
  echo "Setting ceramic url to $CERAMIC_HOST" >&2
  ceramic config set ceramicHost "$CERAMIC_HOST"
  glaze config:set ceramic-url "$CERAMIC_HOST"
fi

if [[ $FLUENCE_SYSTEM_SERVICES__ENABLE == *"aqua-ipfs"* ]]; then
  RETRY_COUNT=${RETRY_COUNT:-5}
  until check_ipfs "$FLUENCE_ENV_AQUA_IPFS_LOCAL_API_MULTIADDR"; do
    while ((RETRY_COUNT)); do
      if [[ $RETRY_COUNT == 0 ]]; then
        echo "IPFS check failed after $RETRY_COUNT attempts. Exiting with an error." >&2
        exit 1
      fi
      echo "Waiting for IPFS to be up..." >&2
      sleep 10
    done
  done
fi

exec nox $@
