# Carousel

Continuous Delivery

## How to deploy on stage

- bump nox or cli version in `versions.json` or make changes in `deployment/*`
- create and merge PR with changes

Or merge renovate PR.

## How to deploy on testnet/kras

- merge release PR

## How to deploy tag or branch

Go to `Actions` -> `deploy` and press `Run workflow`

## How to cleanup nox volumes

Add a label `cleanup` to a PR before merge.
