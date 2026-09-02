#!/usr/bin/env bash
# Деплой webapp на прод-VPS (report.finance-black.ru) через rsync + systemd restart.
# Реквизиты — из .env (DEPLOY_SSH_HOST / DEPLOY_SSH_USER / DEPLOY_SSH_PASSWORD).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
source .env
set +a

: "${DEPLOY_SSH_HOST:?DEPLOY_SSH_HOST не задан в .env}"
: "${DEPLOY_SSH_USER:?DEPLOY_SSH_USER не задан в .env}"
: "${DEPLOY_SSH_PASSWORD:?DEPLOY_SSH_PASSWORD не задан в .env}"

REMOTE_PATH="/var/www/report.finance-black.ru"
SERVICE="report-cloudsix.service"

echo "→ Сборка style.css"
npm run build:css

echo "→ rsync на $DEPLOY_SSH_HOST:$REMOTE_PATH"
sshpass -p "$DEPLOY_SSH_PASSWORD" rsync -av --delete -e "ssh -o StrictHostKeyChecking=no" \
  --exclude 'webapp/uploads/' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  --exclude '.git/' \
  --exclude 'node_modules/' \
  --exclude 'venv/' \
  --exclude '.env' \
  --exclude 'webapp/.env' \
  ./ "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST:$REMOTE_PATH/"

echo "→ Перезапуск $SERVICE"
sshpass -p "$DEPLOY_SSH_PASSWORD" ssh -o StrictHostKeyChecking=no "$DEPLOY_SSH_USER@$DEPLOY_SSH_HOST" \
  "systemctl restart $SERVICE"

echo "Готово."
