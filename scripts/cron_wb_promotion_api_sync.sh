#!/usr/bin/env bash
# Ежедневная загрузка расходов на продвижение WB из рекламного API
# (/adv/v1/upd → wb_promotion_api) по всем WB-кабинетам, БД cloudsix.
# Запускается по cron на прод-VPS, НЕ на машине разработки.
#
# Скользящее окно 35 дней: списания за вчера/сегодня приходят с задержкой, а
# ключ строки естественный (кабинет, кампания, документ, время, источник) —
# повторная загрузка окна ничего не дублирует. Окно > 31 дня режется загрузчиком.
# Нет `set -e`: ошибка кабинета идёт в лог и не ломает соседние cron-задачи.
#   45 5 * * * /var/www/report.finance-black.ru/scripts/cron_wb_promotion_api_sync.sh >> /var/log/wb-promotion-api-sync.log 2>&1

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source venv/bin/activate

exec 9>/tmp/wb-promotion-api-sync.lock
flock -n 9 || { echo "$(date -Iseconds) — уже выполняется, выхожу"; exit 0; }

DATE_TO=$(date +%Y-%m-%d)
DATE_FROM=$(date -d '35 days ago' +%Y-%m-%d)
echo "=== $(date -Iseconds) — WB продвижение (API), окно $DATE_FROM..$DATE_TO ==="
python3 src/ingest_wb_promotion_api.py --all-cabinets --date-from "$DATE_FROM" --date-to "$DATE_TO" --database cloudsix \
    || echo "ОШИБКА: WB продвижение (API) — часть кабинетов упала, см. вывод выше"
echo "=== $(date -Iseconds) — готово ==="
