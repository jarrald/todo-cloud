#!/bin/bash
# Creates the Azure infrastructure (ACR, AKS, Cosmos DB for MongoDB) and wires up Kubernetes and GitHub.
# Run from anywhere:  bash infra/deploy.sh
# Requires: az (logged in with "az login"), kubectl. Optional: gh (logged in) to set GitHub secrets.
# Works on macOS, Linux, Windows (Git Bash / WSL) and Azure Cloud Shell.
#
# Optional overrides (environment variables), e.g.  LOCATION=northeurope bash infra/deploy.sh
#   RG=todo-rg  LOCATION=norwayeast  COSMOS_LOCATION=uksouth  AKS_VM_SIZE=Standard_B2s
#   AKS_NODE_COUNT=2  ATTACH_ACR=true
#   COSMOS_SERVERLESS=true|false (default: auto)  GITHUB_REPO=owner/repo (default: current repo)

set -euo pipefail
cd "$(dirname "$0")/.."

RG="${RG:-todo-rg}"
LOCATION="${LOCATION:-norwayeast}"
COSMOS_LOCATION="${COSMOS_LOCATION:-uksouth}"
AKS_VM_SIZE="${AKS_VM_SIZE:-Standard_B2s}"
AKS_NODE_COUNT="${AKS_NODE_COUNT:-2}"
ATTACH_ACR="${ATTACH_ACR:-true}"
DB_NAME="todosDB"
DEPLOYMENT="todo-infra"

for tool in az kubectl; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; exit 1; }
done
az account show >/dev/null 2>&1 || { echo "Not logged in. Run: az login"; exit 1; }

echo "Subscription: $(az account show --query name -o tsv)"

echo "Registering resource providers..."
for provider in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.DocumentDB; do
  az provider register --namespace "$provider" --wait
done

GROUP_EXISTS=$(az group exists -n "$RG" -o tsv)
if [ "$GROUP_EXISTS" = "true" ]; then
  echo "Using existing resource group $RG."
else
  echo "Creating resource group $RG in $LOCATION..."
  az group create -n "$RG" -l "$LOCATION" -o none
fi

# Cosmos DB free tier is allowed once per subscription: use serverless if it is taken elsewhere
EXISTING_COSMOS=$(az cosmosdb list -g "$RG" --query '[0].name' -o tsv 2>/dev/null || true)
if [ -n "$EXISTING_COSMOS" ]; then
  COSMOS_FREE=$(az cosmosdb show -g "$RG" -n "$EXISTING_COSMOS" --query enableFreeTier -o tsv)
  COSMOS_SERVERLESS=$(az cosmosdb show -g "$RG" -n "$EXISTING_COSMOS" --query "contains(capabilities[].name, 'EnableServerless')" -o tsv)
else
  COSMOS_FREE=true
  if [ -z "${COSMOS_SERVERLESS:-}" ]; then
    FREE_ELSEWHERE=$(az cosmosdb list --query "[?enableFreeTier==\`true\` && resourceGroup!='$RG'].name" -o tsv)
    if [ -n "$FREE_ELSEWHERE" ]; then COSMOS_SERVERLESS=true; else COSMOS_SERVERLESS=false; fi
  fi
fi
COSMOS_FREE=$(echo "$COSMOS_FREE" | tr '[:upper:]' '[:lower:]')
COSMOS_SERVERLESS=$(echo "$COSMOS_SERVERLESS" | tr '[:upper:]' '[:lower:]')
echo "Locations: AKS/ACR=$LOCATION Cosmos DB=$COSMOS_LOCATION"
echo "AKS: nodeCount=$AKS_NODE_COUNT vmSize=$AKS_VM_SIZE"
echo "Cosmos DB: freeTier=$COSMOS_FREE serverless=$COSMOS_SERVERLESS"

echo "Deploying Bicep template (this takes about 5-10 minutes)..."
if ! az deployment group create -g "$RG" -n "$DEPLOYMENT" -f infra/main.bicep \
  -p location="$LOCATION" cosmosLocation="$COSMOS_LOCATION" aksVmSize="$AKS_VM_SIZE" \
     aksNodeCount="$AKS_NODE_COUNT" attachAcr="$ATTACH_ACR" \
     cosmosFreeTier="$COSMOS_FREE" cosmosServerless="$COSMOS_SERVERLESS" -o none; then
  echo
  echo "Deployment failed. Common fixes:"
  echo "  - Role assignment denied:       ATTACH_ACR=false bash infra/deploy.sh"
  echo "  - Region blocked/unavailable:   set LOCATION or COSMOS_LOCATION to an available, allowed region"
  echo "  - VM size not available:        AKS_VM_SIZE=Standard_B2ms bash infra/deploy.sh"
  echo "  - Free tier already used:       COSMOS_SERVERLESS=true bash infra/deploy.sh"
  exit 1
fi

output() { az deployment group show -g "$RG" -n "$DEPLOYMENT" --query "properties.outputs.$1.value" -o tsv; }
ACR_NAME=$(output acrName)
ACR_LOGIN=$(output acrLoginServer)
AKS_NAME=$(output aksName)
COSMOS_NAME=$(output cosmosName)

ACR_USER=$(az acr credential show -n "$ACR_NAME" --query username -o tsv)
ACR_PASS=$(az acr credential show -n "$ACR_NAME" --query 'passwords[0].value' -o tsv)

# Cosmos connection string with the database name added
MONGO_URI=$(az cosmosdb keys list -g "$RG" -n "$COSMOS_NAME" --type connection-strings \
  --query 'connectionStrings[0].connectionString' -o tsv | sed "s#:10255/?#:10255/${DB_NAME}?#")

# Admin kubeconfig in a temp file so the secrets below go to the new cluster
KUBECONFIG_FILE=$(mktemp)
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
az aks get-credentials -g "$RG" -n "$AKS_NAME" --admin --file "$KUBECONFIG_FILE" --overwrite-existing >/dev/null
export KUBECONFIG="$KUBECONFIG_FILE"

echo "Creating Kubernetes secrets..."
kubectl create secret generic mongo-secret --from-literal=MONGO_URI="$MONGO_URI" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if [ "$ATTACH_ACR" != "true" ]; then
  kubectl create secret docker-registry acr-secret --docker-server="$ACR_LOGIN" \
    --docker-username="$ACR_USER" --docker-password="$ACR_PASS" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"acr-secret"}]}' >/dev/null
fi

echo "Setting the ACR name in kubernetes-aks/ manifests..."
sed -i.bak "s#YOUR_ACR\.azurecr\.io#${ACR_LOGIN}#g" kubernetes-aks/*.yaml
rm -f kubernetes-aks/*.bak

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  REPO="${GITHUB_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
  echo "Setting GitHub secrets and variables in $REPO..."
  gh secret set ACR_USERNAME --repo "$REPO" --body "$ACR_USER"
  gh secret set ACR_PASSWORD --repo "$REPO" --body "$ACR_PASS"
  gh secret set KUBE_CONFIG --repo "$REPO" < "$KUBECONFIG_FILE"
  gh variable set ACR_LOGIN_SERVER --repo "$REPO" --body "$ACR_LOGIN"
else
  echo
  echo "gh is not installed or not logged in. Set these manually in GitHub (Settings > Secrets and variables > Actions):"
  echo "  Secret   ACR_USERNAME = $ACR_USER"
  echo "  Secret   ACR_PASSWORD = (az acr credential show -n $ACR_NAME --query 'passwords[0].value' -o tsv)"
  echo "  Secret   KUBE_CONFIG  = (az aks get-credentials -g $RG -n $AKS_NAME --admin --file - )"
  echo "  Variable ACR_LOGIN_SERVER = $ACR_LOGIN"
fi

cat <<EOF

Done.
  ACR:    $ACR_LOGIN
  AKS:    $AKS_NAME (resource group $RG)
  Cosmos: $COSMOS_NAME (database $DB_NAME)

Next steps:
  1. Commit and push the updated kubernetes-aks/ manifests, then push a change to todo-api/ and todo-app/
     (or push the images manually, see docs/cicd-aks-acr.md section 6).
  2. az aks get-credentials -g $RG -n $AKS_NAME --admin
     kubectl apply -f kubernetes-aks/todo-api-deployment.yaml -f kubernetes-aks/todo-api-service.yaml
     kubectl get svc todo-api -w        # wait for EXTERNAL-IP
  3. Put http://<API_EXTERNAL_IP>:5000 in VITE_API_URL in kubernetes-aks/todo-app-deployment.yaml, then
     kubectl apply -f kubernetes-aks/todo-app-deployment.yaml -f kubernetes-aks/todo-app-service.yaml

Remove everything when finished:  bash infra/destroy.sh
EOF
