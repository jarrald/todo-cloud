param name string
param location string
param databaseName string
param enableFreeTier bool
param serverless bool

resource account 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = {
  name: name
  location: location
  kind: 'MongoDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableFreeTier: enableFreeTier
    apiProperties: {
      serverVersion: '4.2'
    }
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
      }
    ]
    capabilities: concat(
      [
        { name: 'EnableMongo' }
      ],
      serverless ? [{ name: 'EnableServerless' }] : []
    )
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/mongodbDatabases@2023-11-15' = {
  parent: account
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
    options: serverless ? {} : {
      throughput: 400
    }
  }
}

output name string = account.name
