#!/bin/bash
# Deletes the resource group with all demo resources (ACR, AKS, Cosmos DB).
# Run:  bash infra/destroy.sh

set -euo pipefail

RG="${RG:-todo-rg}"

read -r -p "Delete resource group '$RG' and everything in it? [y/N] " answer
[ "$answer" = "y" ] || { echo "Cancelled."; exit 0; }

az group delete -n "$RG" --yes --no-wait
echo "Deletion of $RG started (runs in the background)."
