// Azure RAG 環境構築用 Bicep テンプレート (Windows版最終調整)
// 修正内容: Linux クォータ不足を回避するため Windows ベースの App Service を採用

@description('基本リソースのリージョン')
param location string = 'japaneast'

@description('AI関連リソースのリージョン')
param aiLocation string = 'eastus2'

@description('リソース名の接頭辞')
param prefix string = 'azVCtest'

var uniqueSuffix = substring(uniqueString(resourceGroup().id, deployment().name), 0, 6)
var storageAccountName = toLower('${prefix}st${uniqueSuffix}')
var searchServiceName = toLower('${prefix}search${uniqueSuffix}')
var openaiName = toLower('${prefix}oai${uniqueSuffix}')
var appServicePlanName = toLower('${prefix}asp${uniqueSuffix}')
var webAppName = toLower('${prefix}app${uniqueSuffix}')

// --- 1. Storage Account ---
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

// --- 2. Azure AI Search ---
resource searchService 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchServiceName
  location: aiLocation
  sku: { name: 'free' }
}

// --- 3. Azure OpenAI Service ---
resource openaiService 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openaiName
  location: aiLocation
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: { customSubDomainName: openaiName }
}

resource gpt4oMini 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  parent: openaiService
  name: 'gpt-4o-mini'
  properties: {
    model: { format: 'OpenAI', name: 'gpt-4o-mini', version: '2024-07-18' }
  }
  sku: { name: 'GlobalStandard', capacity: 10 }
}

resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  parent: openaiService
  name: 'text-embedding-3-small'
  dependsOn: [ gpt4oMini ]
  properties: {
    model: { format: 'OpenAI', name: 'text-embedding-3-small', version: '1' }
  }
  sku: { name: 'GlobalStandard', capacity: 10 }
}

// --- 4. App Service Plan (Windows - B1 Basic) ---
// Windows 版は Linux 版とは別のクォータ枠を使用するため、成功の可能性があります
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  kind: 'app' // Windows 用
  sku: {
    name: 'B1'
  }
  properties: {} // reserved: true を削除 (Windows 用)
}

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  kind: 'app'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      // Windows 用のランタイム指定 (Python を使用)
      pythonVersion: '3.11'
      appSettings: [
        { name: 'AZURE_STORAGE_ACCOUNT', value: storageAccountName }
        { name: 'AZURE_SEARCH_SERVICE', value: searchServiceName }
        { name: 'AZURE_OPENAI_ENDPOINT', value: openaiService.properties.endpoint }
      ]
    }
  }
}

// --- 5. RBAC ---
var roles = {
  storage: 'ba92f572-36d1-451a-93c6-f1d713c79cce'
  search: '8ebe580b-b695-422d-8305-95f2ae03ef02'
  openai: 'a97b65f3-24c7-4388-baec-2e87135dc908'
}

resource storageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, webApp.id, roles.storage)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storage)
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource searchRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, webApp.id, roles.search)
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.search)
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource openaiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(openaiService.id, webApp.id, roles.openai)
  scope: openaiService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.openai)
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output webAppUrl string = webApp.properties.defaultHostName
