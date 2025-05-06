import json
import boto3
import os
import datetime
import uuid

s3 = boto3.client("s3")
bucket = os.environ["S3_BUCKET"]

def lambda_handler(event, context):
    # HTTP API では event["body"] に JSON 文字列が入る
    body = event.get("body")
    try:
        payload = json.loads(body) if isinstance(body, str) else body
    except json.JSONDecodeError:
        # JSON でない場合はそのまま文字列を保存
        payload = body

    # YYYYMMDD フォルダ名＋ユニークなファイル名
    today = datetime.datetime.utcnow().strftime("%Y%m%d")
    filename = f"{today}/{uuid.uuid4().hex}.json"

    s3.put_object(
        Bucket=bucket,
        Key=filename,
        Body=json.dumps(payload),
        ContentType="application/json"
    )

    return {
        "statusCode": 200,
        "body": json.dumps({"message": "stored", "key": filename})
    }

