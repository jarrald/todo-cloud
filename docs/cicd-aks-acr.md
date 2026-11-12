# CI/CD demo: GitHub Actions -> ACR -> AKS (student account, minimal cost)

Goal: the cheapest possible demo that works on an Azure for Students subscription.

- No service principal / Entra app registration (students usually cannot create them).
- No MongoDB pod: the database is Azure Cosmos DB for MongoDB (free tier).
- One tiny AKS node, free AKS control plane, ACR Basic.
- Each service has its own workflow, triggered only by pushes to `main` in its folder.

Credentials are stored as GitHub secrets (ACR admin user + AKS kubeconfig). This is less secure than OIDC
but needs no directory permissions, which is fine for a demo.

## Rough cost

| Resource                   | Choice                       | Cost                        |
| -------------------------- | ---------------------------- | --------------------------- |
| AKS control plane          | Free tier                    | $0                          |
| AKS node                   | 1 x `Standard_B2s`           | ~ $30/month if left running |
| ACR                        | Basic                        | ~ $5/month                  |
| Cosmos DB for MongoDB (RU) | Free tier (1000 RU/s, 25 GB) | $0                          |
| Public IPs                 | 2 x LoadBalancer             | ~ a few $/month             |

**Delete everything when the demo is done:** `az group delete -n todo-rg --yes`.
You can also pause the cluster between sessions: `az aks stop -g todo-rg -n todo-aks` (and `az aks start ...`).

## Prerequisites

The scripts use command-line tools. The Azure extensions for VS Code are not needed and do not replace them.
Run the commands in the VS Code integrated terminal (bash).

| Tool | Needed for | Install |
| --- | --- | --- |
| Azure CLI (`az`) | everything in `infra/` | macOS: `brew install azure-cli`<br>Windows: `winget install -e --id Microsoft.AzureCLI`<br>Linux: <https://learn.microsoft.com/cli/azure/install-azure-cli-linux> |
| `kubectl` | secrets and deployments in AKS | after installing `az`: `az aks install-cli` (or `brew install kubectl`) |
| GitHub CLI (`gh`), optional | sets the GitHub secrets automatically | macOS: `brew install gh`<br>Windows: `winget install -e --id GitHub.cli`<br>then `gh auth login` |
| Bash | running the scripts | built in on macOS/Linux; on Windows use Git Bash or WSL |

Check the installation and sign in. **After installing, close and reopen the terminal, or restart VS Code completely**
(on Windows, sign out and in again if `az` is still not found). Terminals only pick up new tools at startup.

```bash
az --version
az login            # opens a browser; sign in with your student account
az account show     # confirm the right subscription is selected
```

If several subscriptions are listed, choose the student one: `az account set --subscription "<name or id>"`.

**No installs alternative:** use Azure Cloud Shell (<https://shell.azure.com>, choose Bash). It already has `az`,
`kubectl` and Bicep, and you are already logged in. Run `gh auth login` there if you want the GitHub secrets set
automatically, then `git clone` the repo and run the scripts.

## Quick start: infrastructure as code (Bicep + bash)

`infra/` creates everything in sections 1-4 below with one command:

```bash
az login
bash infra/deploy.sh          # macOS, Linux, Git Bash/WSL on Windows, or Azure Cloud Shell
```

It registers the resource providers, deploys [infra/main.bicep](../infra/main.bicep) (ACR, AKS, Cosmos DB for MongoDB),
creates the `mongo-secret` in the cluster, fills in the ACR name in `kubernetes-aks/`, and sets the GitHub secrets and
variable with `gh` (if `gh` is installed and logged in, otherwise it prints what to set by hand).
Requires `az` and `kubectl` (and optionally `gh`). Azure Cloud Shell has all three; run `gh auth login` there first.

The default location is `norwayeast` for AKS and ACR, and `uksouth` for Cosmos DB. Available regions may differ for
each Azure for Students subscription.
Cosmos DB uses UK South because account creation in Norway East returned a high-demand capacity error. Availability
can change, so set `COSMOS_LOCATION` to another permitted region if necessary.
An existing resource group is reused even if its own location differs;
its location does not change. Use a new `RG` if existing resources need to remain in another region; changing the
location setting does not move an existing Cosmos DB account.
Settings can be overridden with environment variables, for example
`LOCATION=northeurope COSMOS_LOCATION=uksouth AKS_VM_SIZE=Standard_B2ms bash infra/deploy.sh`.
If the deployment fails: select a region allowed by your subscription policy, use `ATTACH_ACR=false` when role
assignments are not allowed, and `COSMOS_SERVERLESS=true` when the free tier is already used.
After it finishes, continue with section 6 (first deploy).
Delete everything with `bash infra/destroy.sh`.

# The sections below do the same thing by hand, for reference.

## 1. Create Azure resources (one time)

Use Azure Cloud Shell or the Azure CLI (`az login`).

```bash
RG=todo-rg
LOC=norwayeast              # pick a region allowed by your subscription policy
COSMOS_LOC=uksouth          # pick an available region allowed by your subscription policy
ACR=todoacr<unique>         # globally unique, lowercase letters and digits only
AKS=todo-aks
COSMOS=todo-cosmos-<unique> # globally unique

az group create -n $RG -l $LOC

# Container registry (admin user enabled so GitHub can push with a password)
az acr create -g $RG -n $ACR --sku Basic --admin-enabled true

# Cheapest AKS: free tier, 1 small node
az aks create -g $RG -n $AKS --tier free --node-count 1 --node-vm-size Standard_B2s \
  --generate-ssh-keys --attach-acr $ACR

# Cosmos DB for MongoDB (free tier is allowed once per subscription)
az cosmosdb create -g $RG -n $COSMOS -l $COSMOS_LOC --kind MongoDB --server-version 4.2 \
  --enable-free-tier true --default-consistency-level Session \
  --locations regionName=$COSMOS_LOC failoverPriority=0
```

Notes:

- If `--attach-acr` fails (no permission to create role assignments), drop it and use an image pull secret
  instead (see section 5, "If AKS cannot pull from ACR").
- If the VM size or region is unavailable for your subscription, check `az vm list-skus -l $LOC --size Standard_B -o table`
  and pick another small size or region.
- If `--enable-free-tier` is rejected (already used), replace it with `--capabilities EnableServerless`.
  Serverless costs cents for a demo.

## 2. Create the Cosmos DB database

```bash
az cosmosdb mongodb database create -g $RG -a $COSMOS -n todosDB
```

Get the connection string:

```bash
az cosmosdb keys list -g $RG -n $COSMOS --type connection-strings \
  --query "connectionStrings[0].connectionString" -o tsv
```

It looks like `mongodb://<account>:<key>@<account>.mongo.cosmos.azure.com:10255/?ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000&appName=@<account>@`.
Insert the database name before the `?`: `...:10255/todosDB?ssl=true&...`. Keep `retrywrites=false`, Cosmos requires it.

## 3. Collect the credentials for GitHub

```bash
# ACR login server, username, password
az acr show -n $ACR --query loginServer -o tsv
az acr credential show -n $ACR --query "[username, passwords[0].value]" -o tsv

# kubeconfig with cluster-admin rights (printed to the terminal, copy the whole content)
az aks get-credentials -g $RG -n $AKS --admin -f -
```

## 4. GitHub configuration

Repository -> Settings -> Secrets and variables -> Actions.

Secrets:

| Name           | Value                                  |
| -------------- | -------------------------------------- |
| `ACR_USERNAME` | ACR admin username                     |
| `ACR_PASSWORD` | ACR admin password                     |
| `KUBE_CONFIG`  | full kubeconfig content from section 3 |

Variables:

| Name               | Value                        |
| ------------------ | ---------------------------- |
| `ACR_LOGIN_SERVER` | e.g. `todoacr123.azurecr.io` |

Docker Hub secrets are no longer needed.

## 5. Kubernetes manifests

The AKS manifests live in `kubernetes-aks/` (the `kubernetes/` folder, with the MongoDB pod, stays for local clusters).
Differences from `kubernetes/`:

- No MongoDB manifests: Cosmos DB replaces them.
- `todo-api` reads `MONGO_URI` from the `mongo-secret` Kubernetes secret.
- Images come from ACR. Replace `YOUR_ACR` with your ACR name in both Deployments.
- Both services are `type: LoadBalancer`.
- `VITE_API_URL` in the `todo-app` Deployment must be the public address of the API (replace `API_EXTERNAL_IP`, see section 6),
  because the browser calls the API directly.

Store the Cosmos connection string as a Kubernetes secret (never commit it):

```bash
az aks get-credentials -g $RG -n $AKS
kubectl create secret generic mongo-secret --from-literal=MONGO_URI='<connection string from section 2>'
```

If AKS cannot pull from ACR (no `--attach-acr`), create a pull secret and add
`imagePullSecrets: [{name: acr-secret}]` to both Deployments' pod spec:

```bash
kubectl create secret docker-registry acr-secret --docker-server=<ACR_LOGIN_SERVER> \
  --docker-username=<ACR_USERNAME> --docker-password=<ACR_PASSWORD>
```

## 6. First deploy (one time)

Images must exist in ACR before the pods can start, so run the workflows first (section 7), or push once manually:

```bash
az acr login -n $ACR
docker build -t <ACR_LOGIN_SERVER>/todo-api:latest ./todo-api && docker push <ACR_LOGIN_SERVER>/todo-api:latest
docker build -t <ACR_LOGIN_SERVER>/todo-app:latest ./todo-app && docker push <ACR_LOGIN_SERVER>/todo-app:latest
```

Then:

```bash
kubectl apply -f kubernetes-aks/todo-api-deployment.yaml -f kubernetes-aks/todo-api-service.yaml
kubectl get svc todo-api -w          # wait for EXTERNAL-IP
```

Put that IP in `VITE_API_URL` (`http://<API_EXTERNAL_IP>:5000`) in `todo-app-deployment.yaml`, commit it, and apply the rest:

```bash
kubectl apply -f kubernetes-aks/todo-app-deployment.yaml -f kubernetes-aks/todo-app-service.yaml
kubectl get svc todo-app -w          # open http://<APP_EXTERNAL_IP>:3000
```

The todo-app container runs the Vite dev server (`npm run dev`), so `VITE_API_URL` is read at container start
and does not need to be a build argument.

## 7. Workflows

Replace `.github/workflows/todo-api.yml` with the following. For `todo-app.yml`, use the same file with
`SERVICE: todo-app`, the `todo-app/**` path and the name `todo-app CI/CD`.
Once the workflows are on the default branch, either can also be started from GitHub Actions using **Run workflow**.
The deployment must already exist in AKS for the rollout step to succeed.

```yaml
name: todo-api CI/CD

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths:
      - "todo-api/**"
      - ".github/workflows/todo-api.yml"

env:
  SERVICE: todo-api
  IMAGE: ${{ vars.ACR_LOGIN_SERVER }}/todo-api

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          registry: ${{ vars.ACR_LOGIN_SERVER }}
          username: ${{ secrets.ACR_USERNAME }}
          password: ${{ secrets.ACR_PASSWORD }}

      - uses: docker/build-push-action@v6
        with:
          context: ./${{ env.SERVICE }}
          push: true
          tags: |
            ${{ env.IMAGE }}:${{ github.sha }}
            ${{ env.IMAGE }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - uses: azure/k8s-set-context@v4
        with:
          method: kubeconfig
          kubeconfig: ${{ secrets.KUBE_CONFIG }}

      - name: Deploy to AKS
        run: |
          kubectl set image deployment/${{ env.SERVICE }} ${{ env.SERVICE }}=${{ env.IMAGE }}:${{ github.sha }}
          kubectl rollout status deployment/${{ env.SERVICE }} --timeout=180s
```

## 8. Verify

```bash
az acr repository list -n $ACR -o table
kubectl get pods
kubectl logs deploy/todo-api        # should print "Connected to MongoDB"
```

Push a change inside `todo-api/` or `todo-app/` to `main`: only that service's workflow runs, pushes a new
image to ACR and rolls it out.

## Caveats

- `todo-api` logs `MONGO_URI` on startup (`startup/dbConnect.ts`), which would print the Cosmos key to the pod logs.
  Remove that `console.log` or log only the host.
- Keep the kubeconfig and ACR password only in GitHub secrets. Rotate them (`az acr credential renew`) after the demo,
  or just delete the resource group.
