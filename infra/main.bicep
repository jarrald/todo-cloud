targetScope = 'resourceGroup'

param location string = resourceGroup().location
param cosmosLocation string = 'uksouth'
param functionsLocation string = location
param prefix string = 'todo'
param aksVmSize string = 'Standard_B2s'
@minValue(1)
param aksNodeCount int = 2
param databaseName string = 'todosDB'

@description('Exact deployed frontend origin, including scheme and port; empty disables cross-origin access')
param frontendOrigin string = ''

@description('Grant AKS pull access to ACR (needs permission to create role assignments)')
param attachAcr bool = true

@description('Cosmos DB free tier, allowed once per subscription')
param cosmosFreeTier bool = true

@description('Use serverless Cosmos DB instead of provisioned throughput')
param cosmosServerless bool = false

var suffix = uniqueString(resourceGroup().id)

module acr 'modules/acr.bicep' = {
  name: 'acr'
  params: {
    name: '${prefix}acr${suffix}'
    location: location
  }
}

module aks 'modules/aks.bicep' = {
  name: 'aks'
  params: {
    name: '${prefix}-aks'
    location: location
    vmSize: aksVmSize
    nodeCount: aksNodeCount
    acrName: acr.outputs.name
    attachAcr: attachAcr
  }
}

module cosmos 'modules/cosmos.bicep' = {
  name: 'cosmos'
  params: {
    name: '${prefix}-cosmos-${suffix}'
    location: cosmosLocation
    databaseName: databaseName
    enableFreeTier: cosmosFreeTier && !cosmosServerless
    serverless: cosmosServerless
  }
}

module functions 'modules/functions.bicep' = {
  name: 'functions'
  params: {
    name: '${prefix}-functions-${suffix}'
    storageName: 'todofunc${suffix}'
    location: functionsLocation
    cosmosName: cosmos.outputs.name
    databaseName: databaseName
    frontendOrigin: frontendOrigin
  }
}

output acrName string = acr.outputs.name
output acrLoginServer string = acr.outputs.loginServer
output aksName string = aks.outputs.name
output cosmosName string = cosmos.outputs.name
output functionsName string = functions.outputs.name
output statisticsUrl string = functions.outputs.baseUrl
