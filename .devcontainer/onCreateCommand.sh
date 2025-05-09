#!/bin/sh

set -o errexit
set -o nounset
set -o pipefail

echo "Starting On Create Command"

# Create k3d cluster and forwarded ports
k3d cluster delete
k3d cluster create \
-i rancher/k3s:v1.30.11-k3s1 \
-p '1883:1883@loadbalancer' \
-p '8883:8883@loadbalancer'

echo "Ending On Create Command"
