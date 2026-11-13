# CI/CD demo: GitHub Actions -> ACR -> AKS (student account, minimal cost)

Goal: a low-cost demo that works on an Azure for Students subscription.

- The Function workflow uses a GitHub-federated Azure managed identity; creating it and assigning its role
  requires appropriate Azure permissions.
- No MongoDB pod: the database is Azure Cosmos DB for MongoDB (free tier).
- Two small AKS nodes, free AKS control plane, ACR Basic.
- Each service has its own workflow, triggered by relevant pushes to `main` or manually in GitHub Actions.

The container workflows use GitHub secrets (ACR admin user + AKS kubeconfig). The Function workflow uses
OIDC and a managed identity instead. Treat the kubeconfig and registry credentials as sensitive.

## Rough cost

| Resource                   | Choice                       | Cost                        |
| -------------------------- | ---------------------------- | --------------------------- |
| AKS control plane          | Free tier                    | $0                          |
| AKS nodes                  | 2 x `Standard_B2s`           | ~ $60/month if left running |
| ACR                        | Basic                        | ~ $5/month                  |
| Cosmos DB for MongoDB (RU) | Free tier (1000 RU/s, 25 GB) | $0                          |
| Public IPs                 | 2 x LoadBalancer             | ~ a few $/month             |
| Function App and storage   | Flex Consumption and LRS     | Usage-based; varies by region |

**Delete the demo resources when finished:** run `bash infra/destroy.sh` and confirm when prompted. It starts
deleting `todo-rg` in the background. Alternatively, delete the group directly with
`az group delete -n todo-rg --yes`. Both options delete all resources in the group.
You can also pause the cluster between sessions: `az aks stop -g todo-rg -n todo-aks` (and `az aks start ...`).
The node estimate is approximate; actual pricing varies by region. Set `AKS_NODE_COUNT=1` for a lower-cost demo.

## Prerequisites

The scripts use command-line tools. The Azure extensions for VS Code are not needed and do not replace them.
Run the commands in the VS Code integrated terminal (bash).

| Tool                        | Needed for                            | Install                                                                                                                                                           |
| --------------------------- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Azure CLI (`az`)            | everything in `infra/`                | macOS: `brew install azure-cli`<br>Windows: `winget install -e --id Microsoft.AzureCLI`<br>Linux: <https://learn.microsoft.com/cli/azure/install-azure-cli-linux> |
| `kubectl`                   | secrets and deployments in AKS        | after installing `az`: `az aks install-cli` (or `brew install kubectl`)                                                                                           |
| GitHub CLI (`gh`), optional | sets the GitHub secrets automatically | macOS: `brew install gh`<br>Windows: `winget install -e --id GitHub.cli`<br>then `gh auth login`                                                                  |
| Git                         | clone and push the repository         | Windows: `winget install -e --id Git.Git`<br>Other platforms: <https://git-scm.com/install/>                                                                     |
| Bash                        | running the scripts                   | built in on macOS/Linux; on Windows use Git Bash or WSL                                                                                                           |

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

## Automated setup: deploy and destroy scripts

Run the following from the repository root in Bash. Install the tools in **Prerequisites** first. Git is also needed
to clone the repository and push the manifests and workflows. Docker is not needed locally when using GitHub Actions.

### 1. Sign in

```bash
az login
az account show             # check the subscription
kubectl version --client    # check kubectl is installed
gh auth login               # optional, for automatic GitHub configuration
```

For `gh`, sign in to an account with permission to manage the target repository's Actions secrets and variables.
If you skip it, the deploy script prints instructions to configure them manually.

### 2. Deploy infrastructure

```bash
bash infra/deploy.sh
```

The script registers providers, deploys [infra/main.bicep](../infra/main.bicep) (ACR, AKS, Cosmos DB, Function App and storage),
creates the `mongo-secret` in AKS, replaces the `YOUR_ACR.azurecr.io` placeholder in the manifests, and sets
GitHub repository secrets (`ACR_USERNAME`, `ACR_PASSWORD`, `KUBE_CONFIG`) and the `ACR_LOGIN_SERVER`,
`AZURE_FUNCTIONAPP_NAME`, and `VITE_STATISTICS_URL` variables
when `gh` is installed and authenticated. If the manifests already contain a registry address, verify and update
them manually: the script only replaces the placeholder. Do not commit credentials or kubeconfig.
The Function reads the same Cosmos database as the API. Its database connection is stored in Azure app
settings, not in the frontend or GitHub.

The default location is `norwayeast` for AKS and ACR, and `uksouth` for Cosmos DB. Available regions may differ for
each Azure for Students subscription.
Cosmos DB uses UK South because account creation in Norway East returned a high-demand capacity error. Availability
can change, so set `COSMOS_LOCATION` to another permitted region if necessary.
An existing resource group is reused even if its own location differs;
its location does not change. Use a new `RG` if existing resources need to remain in another region; changing the
location setting does not move an existing Cosmos DB account.
Settings can be overridden with environment variables, for example
`LOCATION=northeurope COSMOS_LOCATION=uksouth AKS_VM_SIZE=Standard_B2ms bash infra/deploy.sh`.
The Function and its storage default to `LOCATION`; use `FUNCTIONS_LOCATION` to select a region
that supports Flex Consumption. Check available regions with
`az functionapp list-flexconsumption-locations -o table` and your subscription's restrictions.
The default AKS node count is two (`AKS_NODE_COUNT=1` overrides it). Existing clusters do not change until you
redeploy or scale the node pool manually:

```bash
az aks scale -g todo-rg -n todo-aks --nodepool-name system --node-count 2
kubectl config current-context  # confirm this is the AKS context
kubectl get nodes
kubectl get pods -l app=todo-api -o wide
```

An additional node does not guarantee that replicas run on different nodes; existing pods are not automatically
redistributed. Switching or scaling nodes can affect availability, and the extra VM consumes student credits.
If the deployment fails: select a region allowed by your subscription policy, use `ATTACH_ACR=false` when role
assignments are not allowed, and `COSMOS_SERVERLESS=true` when the free tier is already used.
### 3. Create the Kubernetes deployments

The script creates infrastructure and the database secret, but does not deploy the application. Connect `kubectl`
to AKS and check the context before applying manifests:

```bash
az aks get-credentials -g todo-rg -n todo-aks --admin
kubectl config current-context
kubectl apply -f kubernetes-aks/todo-api-deployment.yaml -f kubernetes-aks/todo-api-service.yaml
kubectl get svc todo-api -w
```

Use the resource group name from `RG` if overridden. Once an `EXTERNAL-IP` appears, stop watching with Ctrl+C.
Set the GitHub Actions variable `VITE_API_URL` to `http://<API_EXTERNAL_IP>:5000`, then create the frontend:

```bash
kubectl apply -f kubernetes-aks/todo-app-deployment.yaml -f kubernetes-aks/todo-app-service.yaml
```

The production frontend embeds both URLs at **image build time**. Changing environment variables in the
Kubernetes deployment alone does not change the built application; rerun the `todo-app` workflow after
changing either GitHub variable.

### 4. Build and deploy the application

Before running `todo-functions CI/CD`, configure GitHub OIDC:

1. Create a user-assigned managed identity and grant it **Website Contributor** on the Function App.
2. Add a federated credential for this repository and the `main` branch.
3. Set GitHub Actions variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID`
   to the identity client ID, tenant ID, and subscription ID.

See the [Azure Functions action OIDC instructions](https://github.com/Azure/functions-action#use-oidc-recommended).
If your account cannot create the identity or role assignment, ask a subscription administrator.

Review, commit and push the updated manifests and workflow files to `main`. In GitHub **Actions**, manually run
`todo-api CI/CD`, `todo-app CI/CD`, and `todo-functions CI/CD` using **Run workflow**. The container workflows build and push the images,
then update the existing AKS deployments. Pods may show image-pull errors until the first images are available.
Once both workflows succeed:

```bash
kubectl get pods
kubectl get svc todo-app -w
```

When the frontend `EXTERNAL-IP` appears, open `http://<APP_EXTERNAL_IP>:3000`. Later pushes to `main` affecting
the relevant service or workflow trigger its pipeline automatically.

Allow the exact frontend origin in Function CORS (no trailing slash), then redeploy the infrastructure:

```bash
FRONTEND_ORIGIN=http://<APP_EXTERNAL_IP>:3000 bash infra/deploy.sh
```

Keep the same overrides used for the initial deployment. The Function is anonymous and CORS is not an
authorization mechanism; this is intended as a public demo endpoint. Check the Function URL from the
deployment output with `curl "<FUNCTION_BASE_URL>/api/statistics"` and confirm the counts change in the UI.
Monitor Function errors and MongoDB connections, particularly if the Function scales out.

### 5. Clean up

```bash
bash infra/destroy.sh
```

Confirm with `y`. The script deletes the entire `todo-rg` resource group asynchronously, including its data.
For a custom group use `RG=<group-name> bash infra/destroy.sh`. Verify deletion has finished in the Azure portal
or with `az group exists -n todo-rg`; also check that the AKS-managed `MC_...` group has disappeared.
Unrelated groups such as `NetworkWatcherRG` are not targeted.
Alternatively, run `az group delete -n todo-rg --yes` to delete the default group directly.

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

# AKS: free tier, 2 small nodes
az aks create -g $RG -n $AKS --tier free --node-count 2 --node-vm-size Standard_B2s \
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
| `VITE_API_URL` | Browser-accessible API base URL |
| `VITE_STATISTICS_URL` | Function base URL, without `/api/statistics` |
| `AZURE_FUNCTIONAPP_NAME` | Function App name |
| `AZURE_CLIENT_ID` | Federated managed identity client ID |
| `AZURE_TENANT_ID` | Azure tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |

Docker Hub secrets are no longer needed.

## 5. Kubernetes manifests

`kubectl` uses the same commands for local clusters and AKS; its current context determines the target cluster.
Check the context before making changes:

```bash
kubectl config current-context
kubectl config get-contexts
kubectl config use-context <context-name>  # for example, docker-desktop for Docker Desktop
```

Switching to a local context does not stop or delete Azure resources, which may continue to incur charges.

The AKS manifests live in `kubernetes-aks/` (the `kubernetes/` folder, with the MongoDB pod, stays for local clusters).
Differences from `kubernetes/`:

- No MongoDB manifests: Cosmos DB replaces them.
- `todo-api` reads `MONGO_URI` from the `mongo-secret` Kubernetes secret.
- Images come from ACR. Replace `YOUR_ACR` with your ACR name in both Deployments.
- Both services are `type: LoadBalancer`.
- The frontend image must be built with browser-accessible `VITE_API_URL` and `VITE_STATISTICS_URL` values.

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
docker build -f ./todo-app/Dockerfile-prod-azure --build-arg VITE_API_URL=<API_BASE_URL> \
  --build-arg VITE_STATISTICS_URL=<FUNCTION_BASE_URL> -t <ACR_LOGIN_SERVER>/todo-app:latest ./todo-app
docker push <ACR_LOGIN_SERVER>/todo-app:latest
```

Then:

```bash
kubectl apply -f kubernetes-aks/todo-api-deployment.yaml -f kubernetes-aks/todo-api-service.yaml
kubectl get svc todo-api -w          # wait for EXTERNAL-IP
```

Build the frontend with `VITE_API_URL=http://<API_EXTERNAL_IP>:5000` and the Function base URL, then apply the rest:

```bash
kubectl apply -f kubernetes-aks/todo-app-deployment.yaml -f kubernetes-aks/todo-app-service.yaml
kubectl get svc todo-app -w          # open http://<APP_EXTERNAL_IP>:3000
```

The Azure frontend image serves a production Vite build, so changing either URL requires rebuilding the image.

## 7. Workflows

The existing workflows are `.github/workflows/todo-api.yml`, `todo-app.yml`, and `todo-functions.yml`.
Once they are on the default branch, each can also be started from GitHub Actions using **Run workflow**.
The deployment must already exist in AKS for the rollout step to succeed.

## 8. Verify

```bash
az acr repository list -n $ACR -o table
kubectl get pods
kubectl logs deploy/todo-api        # should print "Connected to MongoDB"
```

Push a change inside `todo-api/` or `todo-app/` to `main`: only that service's workflow runs, pushes a new
image to ACR and rolls it out.
