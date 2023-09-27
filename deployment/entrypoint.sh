#! /usr/bin/env bash

if [[ -z $CERAMIC_HOST ]]; then
  echo "\$CERAMIC_HOST is unset. Skipping ceramic CLI initialization"
else
  echo "Setting ceramic url to to $CERAMIC_HOST"
  ceramic config set ceramicHost "$CERAMIC_HOST"
  glaze config:set ceramic-url "$CERAMIC_HOST"
fi

exec nox $@
