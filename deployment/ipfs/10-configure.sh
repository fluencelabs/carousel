#! /usr/bin/env sh

if ! (( (ls -1 "$IPFS_PATH" | wc -l) )); then
	ipfs init
fi

ipfs bootstrap rm --all

ipfs config Addresses.API "/ip4/0.0.0.0/tcp/5020"

ipfs config --json API.HTTPHeaders.Access-Control-Allow-Origin '["*"]'
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Methods '["PUT", "POST"]'

ipfs config --json Pubsub.Enabled true
