#!/usr/bin/env bash
# Ежедневная загрузка Google-Таблицы «Продвижение CS» (ручная таблица маркетолога:
# Продв WB / Продв Ozon / Справочник) в ClickHouse, БД cloudsix.
# Запускается по cron на прод-VPS, НЕ на машине разработки.
#
# Вкладки читаются целиком каждый раз; каждая загрузка — новый снимок с общей
# меткой loaded_at, вьюхи *_current показывают только последний (старые строки
# не удаляем — у app_cloudsix нет DELETE). Поэтому повторный прогон безопасен,
# а правки маркетолога (вставка/удаление строк) подхватываются без дублей.
# Время — после API-синка CloudSix (05:00 UTC), например:
#   30 5 * * * /opt/bf-analytics-platform/scripts/cron_cloudsix_promotion_sync.sh >> /var/log/cloudsix-promotion-sync.log 2>&1
# Нет `set -e`: ошибка идёт в лог и не ломает соседние cron-задачи.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source venv/bin/activate

exec 9>/tmp/cloudsix-promotion-sync.lock
flock -n 9 || { echo "$(date -Iseconds) — уже выполняется, выхожу"; exit 0; }

echo "=== $(date -Iseconds) — Продвижение CS (Google-Таблица) ==="
python3 src/ingest_promotion.py --project-id 1 --database cloudsix \
    || echo "ОШИБКА: Продвижение CS упало, см. вывод выше"
echo "=== $(date -Iseconds) — готово ==="
