#!/bin/sh
# Run pg_dump to /tmp and report sizes only. No data shipped anywhere.
DUMP=/tmp/prod-sizing.dump
GZ=/tmp/prod-sizing.dump.gz
B64=/tmp/prod-sizing.dump.gz.b64

# Strip ?sslmode=require for pg_dump (it uses PGSSLMODE env instead)
CONN=$(echo "$DATABASE_URL" | sed 's/?sslmode=[^&]*//')
export PGSSLMODE=require

pg_dump --format=custom --schema=public --no-owner --no-acl \
  --exclude-table-data=public.gmail_tokens \
  --exclude-table-data=public.prs_credentials \
  -f "$DUMP" "$CONN" 2>&1 | head -20

if [ -f "$DUMP" ]; then
  RAW=$(wc -c < "$DUMP")
  gzip -c "$DUMP" > "$GZ"
  GZIPPED=$(wc -c < "$GZ")
  base64 -w 0 "$GZ" > "$B64"
  B64SIZE=$(wc -c < "$B64")
  CHUNKS=$(( (B64SIZE + 65535) / 65536 ))
  SHA=$(sha256sum "$DUMP" | cut -d' ' -f1)
  echo "DUMPSIZE raw=$RAW gz=$GZIPPED b64=$B64SIZE chunks_64k=$CHUNKS sha256=$SHA"
  rm -f "$DUMP" "$GZ" "$B64"
else
  echo "DUMPSIZE DUMP_FAILED"
fi
