# Azure VibeCoding RAG実装検証 

Gemini CLI (Vibe Coding) を用いて構築された、 RAG (検索拡張生成) 基盤の検証プロジェクトです。

## 🚀 プロジェクトの概要
本プロジェクトは、自然言語による指示のみで複雑なクラウドインフラとバックエンドロジックを構築する「バイブコーディング」の可能性を証明するために計画しました。

### 特徴
- **Secure by Default**: API キーや接続文字列をフロントエンドに一切持たせず、Azure 環境変数に隠蔽。
- **Zero Dependency API**: Python 標準ライブラリのみを使用し、外部ライブラリのビルド失敗を物理的に排除した、究極の再現性を誇るバックエンド。
- **Self-Constructing RAG**: 初回起動時に Azure AI Search のインデックス等を自動構築する「自己修復・自己構築型」ロジック。
- **Full Auth Protection**: Azure Static Web Apps の標準認証機能を統合し、サイト全体を Microsoft アカウントで保護。

## 🏗️ システムアーキテクチャ
- **Frontend**: HTML5 / Tailwind CSS / JavaScript
- **Backend**: Azure Functions (Python 3.10 / v2 model)
- **Infrastructure**: Azure Bicep (IaC)
- **AI Services**: Azure OpenAI (gpt-4o-mini)
- **Search**: Azure AI Search (Free Tier)
- **Storage**: Azure Blob Storage

## 🛠️ クイックスタート
詳細な構築手順は、次の記事を参照してください。
https://qiita.com/mkt_tmng/items/04f9055e803d86341c03

1. **インフラのプロビジョニング**
   ```powershell
   az group create --name rg-VibeVerification --location japaneast
   az deployment group create --resource-group rg-VibeVerification --template-file infra/main.bicep --parameters infra/main.bicepparam
   ```

2. **アプリケーションのデプロイ**
   `index.html`, `api/`, `staticwebapp.config.json` を Zip 圧縮し、Azure Cloud Shell または SWA CLI でデプロイします。

## 📜 ライセンス
このプロジェクトは MIT ライセンスの下で公開されています。

---
**Created with Gemini CLI (Vibe Coding)**
