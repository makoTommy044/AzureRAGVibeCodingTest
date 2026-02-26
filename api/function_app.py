import azure.functions as func
import logging
import os
import json
import urllib.request
import urllib.parse
import traceback
import base64
import hmac
import hashlib
import datetime

# Azure Functions (v2 Python プログラミングモデル) の初期化
app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

# ==================================================================
# 共通ユーティリティ関数
# ==================================================================

def get_storage_creds():
    """環境変数からストレージ接続情報を取得し、アカウント名とキーを抽出します。"""
    conn_str = os.getenv("STORAGE_CONNECTION_STRING")
    if not conn_str: return None, None, None
    conn_dict = {}
    for pair in conn_str.split(';'):
        if '=' in pair:
            key, val = pair.split('=', 1)
            conn_dict[key] = val
    return conn_dict.get('AccountName'), conn_dict.get('AccountKey'), conn_str

def search_api_request(path, method="GET", body=None):
    """Azure AI Search の REST API に対して認証済みリクエストを送信します。"""
    endpoint = os.getenv("SEARCH_ENDPOINT")
    api_key = os.getenv("SEARCH_API_KEY")
    if not endpoint or not api_key: return None
    
    url = f"{endpoint.rstrip('/')}/{path}?api-version=2023-11-01"
    headers = {
        "api-key": api_key,
        "Content-Type": "application/json"
    }
    data = json.dumps(body).encode('utf-8') if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as res:
            return json.loads(res.read().decode('utf-8'))
    except Exception as e:
        logging.error(f"Search API Error ({path}): {str(e)}")
        return None

# ==================================================================
# RAG インフラの自己構築
# ==================================================================

def ensure_rag_infrastructure():
    """
    AI Search 上にインデックス等のリソースがなければ、自動的に構築します。
    これにより、手動設定なしでの再現性を担保します。
    """
    index_name = "rag-index"
    # インデックスが既にあれば何もしない
    if search_api_request(f"indexes/{index_name}"):
        return True

    logging.info("RAG インフラを自動構築中...")
    acc_name, acc_key, conn_str = get_storage_creds()

    # 1. データソース作成: uploads コンテナをソースとして登録
    search_api_request("datasources", "POST", {
        "name": "blob-datasource",
        "type": "azureblob",
        "credentials": {"connectionString": conn_str},
        "container": {"name": "uploads"}
    })

    # 2. インデックス作成: 日本語アナライザーを指定
    search_api_request("indexes", "POST", {
        "name": index_name,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "searchable": False},
            {"name": "content", "type": "Edm.String", "searchable": True, "analyzer": "ja.microsoft"},
            {"name": "metadata_storage_name", "type": "Edm.String", "searchable": True}
        ]
    })

    # 3. インデクサー作成: ファイルの読み込みルールを定義
    search_api_request("indexers", "POST", {
        "name": "blob-indexer",
        "dataSourceName": "blob-datasource",
        "targetIndexName": index_name,
        "parameters": {
            "configuration": {
                "indexedFileNameExtensions": ".txt,.pdf,.docx",
                "parsingMode": "default"
            }
        }
    })
    
    # 初回同期を実行
    search_api_request(f"indexers/blob-indexer/run", "POST")
    return True

# ==================================================================
# HTTP トリガー関数 (エンドポイント)
# ==================================================================

@app.route(route="chat", methods=["POST"])
def chat_handler(req: func.HttpRequest) -> func.HttpResponse:
    """
    チャットリクエストを処理します。
    AI Search で資料を検索し、その結果を OpenAI のプロンプトに組み込んで回答を生成します。
    """
    logging.info('RAG チャット処理を開始します。')
    try:
        req_body = req.get_json()
        user_prompt = req_body.get('prompt')

        # 1. インフラの自己構築チェックと同期実行
        ensure_rag_infrastructure()
        search_api_request("indexers/blob-indexer/run", "POST")

        # 2. AI Search で関連ドキュメントを検索 (日本語対応)
        context_data = ""
        search_res = search_api_request("indexes/rag-index/docs/search", "POST", {
            "search": user_prompt,
            "top": 3,
            "select": "content,metadata_storage_name"
        })
        
        if search_res and "value" in search_res:
            for doc in search_res["value"]:
                content = doc.get('content', '')
                source = doc.get('metadata_storage_name', '不明')
                context_data += f"\n[出典: {source}]\n{content}\n"

        # 3. OpenAI 用のシステムプロンプト組み立て
        system_content = "あなたは優秀なアシスタントです。"
        if context_data:
            system_content += f"\n\n以下の資料に基づいて回答してください。不明な場合は『記載がありません』と答えてください。\n---\n{context_data}\n---"

        # 4. OpenAI 呼び出し (依存関係なしの REST API 方式)
        endpoint = os.getenv("OPENAI_ENDPOINT")
        api_key = os.getenv("OPENAI_API_KEY")
        deployment_name = os.getenv("OPENAI_DEPLOYMENT_NAME", "gpt-4o-mini")
        
        url = f"{endpoint.rstrip('/')}/openai/deployments/{deployment_name}/chat/completions?api-version=2024-02-15-preview"
        payload = {
            "messages": [
                {"role": "system", "content": system_content},
                {"role": "user", "content": user_prompt}
            ]
        }
        
        headers = {"api-key": api_key, "Content-Type": "application/json"}
        request = urllib.request.Request(url, data=json.dumps(payload).encode('utf-8'), headers=headers)
        with urllib.request.urlopen(request) as response:
            res_data = json.loads(response.read().decode('utf-8'))
            answer = res_data['choices'][0]['message']['content']

        return func.HttpResponse(json.dumps({"answer": answer}), status_code=200, mimetype="application/json")
    except Exception as e:
        return func.HttpResponse(json.dumps({"error": str(e), "details": traceback.format_exc()}), status_code=500)

@app.route(route="get_upload_sas", methods=["POST"])
def get_sas_handler(req: func.HttpRequest) -> func.HttpResponse:
    """
    ブラウザが Blob ストレージに直接アップロードするための「期間限定URL (SAS)」を発行します。
    """
    try:
        req_body = req.get_json()
        filename = req_body.get('filename')
        acc_name, acc_key, _ = get_storage_creds()
        container = "uploads"
        
        # SAS トークンの有効期限設定
        start = datetime.datetime.utcnow() - datetime.timedelta(minutes=5)
        expiry = start + datetime.timedelta(hours=1)
        start_str = start.strftime('%Y-%m-%dT%H:%M:%SZ')
        expiry_str = expiry.strftime('%Y-%m-%dT%H:%M:%SZ')
        
        # 署名用文字列の構成 (Azure Blob REST API 規約準拠)
        signed_permissions, signed_version, signed_resource = "rcw", "2021-12-02", "b"
        canonical_res = f"/blob/{acc_name}/{container}/{filename}"
        string_to_sign = f"{signed_permissions}\n{start_str}\n{expiry_str}\n{canonical_res}\n\n\nhttps\n{signed_version}\nb\n\n\n\n\n\n\n"
        
        # HMAC-SHA256 による署名計算
        signature = base64.b64encode(hmac.new(
            base64.b64decode(acc_key), string_to_sign.encode('utf-8'), hashlib.sha256
        ).digest()).decode('utf-8')
        
        sas_token = f"sv={signed_version}&st={urllib.parse.quote(start_str)}&se={urllib.parse.quote(expiry_str)}&sr=b&sp={signed_permissions}&spr=https&sig={urllib.parse.quote(signature)}"
        sas_url = f"https://{acc_name}.blob.core.windows.net/{container}/{filename}?{sas_token}"

        return func.HttpResponse(json.dumps({"sas_url": sas_url}), status_code=200, mimetype="application/json")
    except Exception as e:
        return func.HttpResponse(json.dumps({"error": str(e)}), status_code=500)
