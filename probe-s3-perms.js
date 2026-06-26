// Probe what S3 perms the prod ECS task role has.
const { S3Client, ListBucketsCommand, CreateBucketCommand, PutBucketEncryptionCommand, PutBucketLifecycleConfigurationCommand, PutPublicAccessBlockCommand, HeadBucketCommand, PutObjectCommand, GetObjectCommand } = require('/app/node_modules/@aws-sdk/client-s3');

const REGION = 'us-west-2';
const BUCKET = 'atlas-acuity-prod-db-staging';

const s3 = new S3Client({ region: REGION });

async function safe(label, fn) {
  try {
    const r = await fn();
    return { ok: true, label, code: r?.$metadata?.httpStatusCode, info: r ? Object.keys(r).filter(k=>k!=='$metadata').join(',') : 'ok' };
  } catch (e) {
    return { ok: false, label, code: e.$metadata?.httpStatusCode, name: e.name, msg: (e.message||'').slice(0,200) };
  }
}

(async () => {
  const out = [];
  out.push(await safe('list_buckets', () => s3.send(new ListBucketsCommand({}))));
  out.push(await safe('head_bucket_exists', () => s3.send(new HeadBucketCommand({ Bucket: BUCKET }))));
  out.push(await safe('create_bucket', () => s3.send(new CreateBucketCommand({ Bucket: BUCKET, CreateBucketConfiguration: { LocationConstraint: REGION } }))));
  out.push(await safe('block_public', () => s3.send(new PutPublicAccessBlockCommand({ Bucket: BUCKET, PublicAccessBlockConfiguration: { BlockPublicAcls: true, IgnorePublicAcls: true, BlockPublicPolicy: true, RestrictPublicBuckets: true } }))));
  out.push(await safe('put_encryption', () => s3.send(new PutBucketEncryptionCommand({ Bucket: BUCKET, ServerSideEncryptionConfiguration: { Rules: [{ ApplyServerSideEncryptionByDefault: { SSEAlgorithm: 'AES256' } }] } }))));
  out.push(await safe('put_lifecycle', () => s3.send(new PutBucketLifecycleConfigurationCommand({ Bucket: BUCKET, LifecycleConfiguration: { Rules: [{ ID: 'expire-1d', Status: 'Enabled', Filter: { Prefix: '' }, Expiration: { Days: 1 } }] } }))));
  out.push(await safe('put_test_object', () => s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: '__probe.txt', Body: 'probe' }))));
  out.push(await safe('get_test_object', () => s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: '__probe.txt' }))));
  console.error('S3_PROBE_RESULT=' + JSON.stringify(out));
})().catch(e => { console.error('S3_PROBE_ERR=' + e.message); process.exit(1); });
