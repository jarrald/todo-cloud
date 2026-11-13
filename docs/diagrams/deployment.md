# Automated deployment

```mermaid
block-beta
    columns 5
    Start["Commit and push to main<br/>Sign in to Azure and GitHub"] a1<[" "]>(right) Run["Run infra/deploy.sh"] a2<[" "]>(right) Check["Check tools, authentication,<br/>clean relevant files and matching main commit"]
    space:4 a3<[" "]>(down)
    Address["Wait for service addresses<br/>and configure Function CORS"] a4<[" "]>(left) Kubernetes["Configure AKS database secret<br/>and apply deployments and services"] a5<[" "]>(left) Provision["Deploy Bicep resources<br/>including GitHub federated identity"]
    a6<[" "]>(down) space:4
    GitHub["Set GitHub Actions<br/>secrets and variables"] a7<[" "]>(right) Function["Run and wait for Function workflow<br/>OIDC identity deploys Function"] a8<[" "]>(right) Api["Run and wait for API workflow<br/>build image, push to ACR, deploy to AKS"]
    space:4 a9<[" "]>(down)
    Cleanup["Optional: when finished,<br/>run infra/destroy.sh<br/>and confirm deletion"] a10<["later"]>(left) Verify["Verify API, frontend, statistics and CORS<br/>print frontend URL"] a11<[" "]>(left) App["Run and wait for frontend workflow<br/>build with URLs, push to ACR, deploy to AKS"]
```

The script stops if a step fails. Azure identity permissions may take time to propagate; see the
[deployment guide](../cicd-aks-acr.md) for prerequisites and troubleshooting.
