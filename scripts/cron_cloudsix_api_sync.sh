#!/usr/bin/env bash
# Ежедневная автозагрузка API-данных CloudSix (WB + Ozon) в ClickHouse.
# Запускается по cron на прод-VPS (91.245.225.207), НЕ на машине разработки —
# ClickHouse слушает только 127.0.0.1:8123 там же (см. docs/architecture-map.md).
#
# WB: скользящее окно 7 дней (сегодня-7 .. сегодня) на каждый кабинет —
# лимит 1 запрос/мин ПРИВЯЗАН К ТОКЕНУ (не к IP, см. scripts/backfill_wb_api.py),
# поэтому кабинеты можно грузить последовательно без взаимной конкуренции за
# лимит, окно в неделю — 1-2 запроса на кабинет, весь прогон занимает минуты,
# не часы. CloudNew вернулся в список 2026-10-04 (новый токен; история 2026
# догружена scripts/backfill_wb_api.py).
#
# Ozon: /v1/finance/cash-flow-statement/list запрашивается ПО МЕСЯЦУ (не по дню,
# см. src/ozon_cashflow_core.py) — без lookback, поэтому повторный запрос
# текущего и прошлого месяца каждый день подхватывает и новые операции, и
# поздние корректировки у границы месяца. --all-cabinets сам берёт список
# кабинетов с заполненным ozon.client_id из secrets/cabinet_api_keys.json —
# включая известный сломанный X-Tech (см. docs/architecture-map.md, раздел
# про X-Tech): не вредит (ReplacingMergeTree, 0 останется 0), но и не чинит
# сам себя — если ключ починят, кабинет просто начнёт грузиться корректно
# без правки этого скрипта.
#
# Ozon «Отчёт о реализации» (/v2/finance/realization) — источник строк 01-06
# отчёта для адаптера (кол-во, Выручка+СПП, Выручка, СПП, Комиссия,
# корректировки) и себестоимости. Ozon отдаёт его только за ЗАКРЫТЫЙ месяц:
# за текущий — 404 «Report was not found», скрипт это тихо пропускает (не
# ошибка). До 2026-10-04 эту загрузку не автоматизировали, и сентябрь в отчёте
# для адаптера был пустым. Прошлый месяц перезаписывается каждый день — ловит
# поздние правки Ozon. Пауза 5 с вместо 15: лимит у этого метода не упирался.
#
# Идемпотентность обеих загрузок — ReplacingMergeTree, повторный прогон того
# же окна перезаписывает те же строки, а не дублирует (см. docstring каждого
# ingest_*.py). Одна ошибка (кабинет/месяц) не должна валить остальные — нет
# `set -e`, каждый шаг просто падает в лог и продолжаем.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source venv/bin/activate

# Не даём двум запускам наложиться, если предыдущий прогон завис/не успел.
exec 9>/tmp/cloudsix-api-sync.lock
flock -n 9 || { echo "$(date -Iseconds) — уже выполняется, выхожу"; exit 0; }

WB_CABINETS="ARB CloudNew CloudSix Feel Hauser INOVO Lampa NoxLab Torado"
DATE_TO=$(date +%Y-%m-%d)
DATE_FROM=$(date -d '7 days ago' +%Y-%m-%d)

echo "=== $(date -Iseconds) — WB API, окно $DATE_FROM..$DATE_TO ==="
for CABINET in $WB_CABINETS; do
    echo "--- WB $CABINET ---"
    python3 src/ingest_wb_api.py --cabinet "$CABINET" --date-from "$DATE_FROM" --date-to "$DATE_TO" \
        || echo "ОШИБКА: WB $CABINET упал, см. вывод выше"
done

MONTH_FROM=$(date -d '1 month ago' +%Y-%m)
MONTH_TO=$(date +%Y-%m)
echo "=== $(date -Iseconds) — Ozon cash-flow-statement, $MONTH_FROM..$MONTH_TO, все кабинеты ==="
python3 src/ingest_ozon_cashflow.py --all-cabinets --from "$MONTH_FROM" --to "$MONTH_TO" \
    || echo "ОШИБКА: Ozon cash-flow упал, см. вывод выше"

echo "=== $(date -Iseconds) — Ozon реализация, $MONTH_FROM..$MONTH_TO, все кабинеты ==="
python3 src/ingest_ozon_realization.py --all-cabinets --from "$MONTH_FROM" --to "$MONTH_TO" --delay 5 \
    || echo "ОШИБКА: Ozon реализация упала, см. вывод выше"

echo "=== $(date -Iseconds) — готово ==="
