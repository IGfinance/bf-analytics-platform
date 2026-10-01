#!/usr/bin/env bash
# Автозагрузка операций ПланФакта (API) в planfact_operations_api.
# Запускается по cron на прод-VPS, НЕ на машине разработки (ClickHouse слушает
# только 127.0.0.1:8123 там же).
#
# Два режима (аргумент):
#   weekly  — по понедельникам: прошлая календарная неделя (сегодня-7 .. сегодня-1).
#   monthly — 4-го числа: перепроверка последних 3 месяцев — с 1-го числа месяца
#             3 месяца назад по сегодня, ловит правки и удаления в старых операциях.
# API не отдаёт «изменено с даты», поэтому окно всегда перетягивается целиком
# (см. src/planfact_api_core.py). Сбой не должен ломать соседние cron-задачи —
# `set -e` нет, ошибка идёт в лог.

set -uo pipefail

MODE="${1:-}"
case "$MODE" in
    weekly)
        DATE_FROM=$(date -d '7 days ago' +%Y-%m-%d)
        DATE_TO=$(date -d 'yesterday' +%Y-%m-%d)
        ;;
    monthly)
        DATE_FROM=$(date -d "$(date +%Y-%m-01) -3 months" +%Y-%m-%d)
        DATE_TO=$(date +%Y-%m-%d)
        ;;
    *)
        echo "Использование: $0 weekly|monthly" >&2
        exit 2
        ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source venv/bin/activate

exec 9>/tmp/planfact-api-sync.lock
flock -w 3600 9 || { echo "$(date -Iseconds) — не дождался предыдущего прогона, выхожу"; exit 0; }

echo "=== $(date -Iseconds) — ПланФакт API ($MODE), окно $DATE_FROM..$DATE_TO ==="
python3 src/ingest_planfact_api.py --date-from "$DATE_FROM" --date-to "$DATE_TO" \
    || echo "ОШИБКА: ПланФакт ($MODE) упал, см. вывод выше"
echo "=== $(date -Iseconds) — готово ==="
