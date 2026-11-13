# Application architecture

```mermaid
flowchart LR
    Browser["Browser<br/>React app"]

    subgraph Azure["Azure"]
        subgraph AKS["Azure Kubernetes Service"]
            AppService["Frontend LoadBalancer<br/>port 3000"]
            App["todo-app<br/>serves React"]
            ApiService["API LoadBalancer<br/>port 5000"]
            Api["todo-api<br/>todo operations"]
            AppService --> App
            ApiService --> Api
        end

        Function["Azure Function App<br/>GET /api/statistics"]
        Database[("Cosmos DB for MongoDB<br/>todosDB / todos")]
    end

    Browser -->|"Loads frontend"| AppService
    Browser -->|"Todo requests"| ApiService
    Browser -->|"Statistics request"| Function
    Api -->|"Reads and writes todos"| Database
    Function -->|"Reads todo counts"| Database
```

The browser calls the API and Function directly. The Function is an anonymous endpoint; CORS allows the
configured frontend origin but does not provide authorization. The API's demo seed replaces todos on startup.
