import boto3
import os

def lambda_handler(event, context):
    rds = boto3.client('rds')
    db_instance = os.environ['DB_INSTANCE_IDENTIFIER']
    snapshot_id = f"{db_instance}-snapshot-{datetime.datetime.now().strftime('%Y-%m-%d-%H-%M')}"
    
    response = rds.create_db_snapshot(
        DBSnapshotIdentifier=snapshot_id,
        DBInstanceIdentifier=db_instance
    )
    
    return {
        'statusCode': 200,
        'body': f"Started snapshot {snapshot_id}"
    }