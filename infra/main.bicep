// Azure RAG 構築テンプレート (認証ベース)
// このテンプレートは、SWA、OpenAI、AI Search、Storage を一括でプロビジョニングし、
// それらの機密情報を SWA の環境変数へ安全に自動注入します。

@description('基本リソース（Storage）の配置リージョン')
param location string = 'japaneast'

@description('AI関連リソース（OpenAI/Search）の配置リージョン。gpt-4o-mini の供給が安定している eastus2 を推奨')
param aiLocation string = 'eastus2'

@description('リソース名が世界で重複しないようにするための接頭辞')
param prefix string = 'azVCtest'

// uniqueSuffix: 成功実績のあるサフィックスを固定。リソース名の競合を物理的に回避します
var uniqueSuffix = 'mxjpgw'

// 各リソース名の組み立て
var storageAccountName = toLower('${prefix}st${uniqueSuffix}')
var searchServiceName = toLower('${prefix}search${uniqueSuffix}')
var openaiName = toLower('${prefix}oai${uniqueSuffix}')
var staticWebAppName = toLower('${prefix}swa${uniqueSuffix}')

// --- 1. Storage Account (ファイル保存用の器) ---
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' } // コスト効率の良いローカル冗長ストレージ
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    // サイト全体に認証をかけているため、ネットワーク制限は緩和（バックエンド通信を優先）
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// 1.1 Blob Service (Blob 操作の基盤)
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    // CORS 設定: ブラウザから直接 Blob ストレージへファイルを PUT するために必須
    cors: {
      corsRules: [
        {
          allowedOrigins: [
            'https://${staticWebApp.properties.defaultHostname}' // 自身の SWA ドメインのみ許可
            'http://localhost:16441' // ローカル開発エミュレータ用
          ]
          allowedMethods: [ 'GET', 'PUT', 'OPTIONS' ]
          maxAgeInSeconds: 3600
          exposedHeaders: [ '*' ]
          allowedHeaders: [ '*' ]
        }
      ]
    }
  }
}

// 1.2 uploads コンテナ (実ファイルを格納する場所)
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'uploads'
  properties: {
    publicAccess: 'None' // 外部への直接公開は禁止（セキュア）
  }
}

// --- 2. Azure AI Search (文書検索エンジン) ---
resource searchService 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchServiceName
  location: aiLocation
  sku: { name: 'free' } // 無料枠を使用
}

// --- 3. Azure OpenAI Service (推論 AI) ---
resource openaiService 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openaiName
  location: aiLocation
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: openaiName
    publicNetworkAccess: 'Enabled'
    // サイト認証で保護するため全許可とし、バックエンド（SWA）との通信を確実にする
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

// 3.1 モデルのデプロイ (gpt-4o-mini)
resource gpt4oMini 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  parent: openaiService
  name: 'gpt-4o-mini'
  properties: {
    model: { format: 'OpenAI', name: 'gpt-4o-mini', version: '2024-07-18' }
  }
  sku: { name: 'GlobalStandard', capacity: 1 }
}

// --- 4. Azure Static Web Apps (フロントエンド & 統合API) ---
resource staticWebApp 'Microsoft.Web/staticSites@2023-12-01' = {
  name: staticWebAppName
  location: 'eastasia' // japaneast 未対応のため eastasia 固定
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    // provider: 'Custom' を明示することで、ソースコード連携なしのデプロイを許可
    provider: 'Custom'
  }
}

// --- 5. SWA アプリケーション設定 (環境変数) の自動注入 ---
// ここで取得したキーは人間が触れることなく SWA へ直接渡されます
var storageKey = storageAccount.listKeys().keys[0].value

resource swaConfig 'Microsoft.Web/staticSites/config@2023-12-01' = {
  parent: staticWebApp
  name: 'appsettings'
  properties: {
    // OpenAI 関連
    OPENAI_API_KEY: openaiService.listKeys().key1
    OPENAI_ENDPOINT: openaiService.properties.endpoint
    OPENAI_DEPLOYMENT_NAME: 'gpt-4o-mini'
    // Storage 関連 (REST API 通信および SAS 発行用)
    STORAGE_CONNECTION_STRING: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageKey};EndpointSuffix=core.windows.net'
    // AI Search 関連 (RAG 検索およびインデックス構築用)
    SEARCH_ENDPOINT: 'https://${searchService.name}.search.windows.net'
    SEARCH_API_KEY: searchService.listAdminKeys().primaryKey
  }
}

// 構築後の情報を出力
output swaDefaultHostname string = staticWebApp.properties.defaultHostname
output storageAccountName string = storageAccountName
output openaiEndpoint string = openaiService.properties.endpoint
