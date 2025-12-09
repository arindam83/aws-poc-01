import json
import os

def handler(event, context):
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Hello from GitHub Actions deployed Lambda!',
            'environment': os.environ.get('ENVIRONMENT', 'unknown'),
            'requestId': context.request_id
        })
    }
