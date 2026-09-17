#!/usr/bin/env bash
# Unggah index.html ke Supabase Storage (bucket app) — aplikasi disajikan di /functions/v1/app
# Pakai: ./deploy.sh <username-master> <kata-sandi>
set -e
URL=https://vfffkwayrjepacmbasmo.supabase.co
KEY=sb_publishable_hfSq3vLE6u05YHJMREJXOw_aNPDX2KO
TOK=$(curl -s "$URL/auth/v1/token?grant_type=password" -H "apikey: $KEY" -H "Content-Type: application/json" -d "{\"email\":\"$1@upscale.local\",\"password\":\"$2\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
curl -s -X POST "$URL/storage/v1/object/app/index.html" -H "apikey: $KEY" -H "Authorization: Bearer $TOK" -H "Content-Type: text/html; charset=utf-8" -H "x-upsert: true" --data-binary @index.html
echo; echo "Terpasang: $URL/functions/v1/app"
