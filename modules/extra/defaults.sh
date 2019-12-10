#!/usr/bin/env bash

# Extra module options
######################

## Stern
STERN_ARGS="${STERN_ARGS:---all-namespaces .}"
STERN_VERSION="${STERN_VERSION:-1.11.0}"
STERN_OS_TYPE="${STERN_OS_TYPE:-linux_amd64}"

## Kwt
KWT_VERSION="${KWT_VERSION:-v0.0.5}"
KWT_OS_TYPE="${KWT_OS_TYPE:-linux-amd64}"

## Catapult-web
# required to be able to mount configs in deployments containers (dind mount for deployments from web interface)
TMPDIR="${TMPDIR:-/tmp}"