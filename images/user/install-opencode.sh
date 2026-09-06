#!/bin/bash
set -ex
OPENCODE_VERSION=v1.18.17
# hardcode env for Dockerfile
platform="linux-x64"
curl -s -L https://github.com/anomalyco/opencode/releases/download/${OPENCODE_VERSION}/opencode-${platform}.tar.gz | tar -xzv -C "$CONDA_PREFIX/bin"
test -f $CONDA_PREFIX/bin/opencode

BIOROUTER_VERSION=v1.89.0
curl -s -L https://github.com/BaranziniLab/biorouter/releases/download/${BIOROUTER_VERSION}/biorouter-headless-${platform}.tar.gz | tar -xzv --strip 1 -C "$CONDA_PREFIX"
test -f $CONDA_PREFIX/bin/biorouter
# fix and verify rpath to lookup libxcb
patchelf --set-rpath '$ORIGIN/../lib' $CONDA_PREFIX/bin/biorouter*
biorouter --help
