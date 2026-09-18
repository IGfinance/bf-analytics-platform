-- Metabase: native SQL карточки "Таблица - Реальт - Список врачей
-- (справочник фильтра)" (id 185), коллекция "Реальт" (id 8).
-- 2026-09-18: создана как источник значений для дашборд-параметра «Врач»
-- (id 7) через values_source_type=card — Metabase подставляет DISTINCT
-- значения колонки "Врач" в дропдаун фильтра. Обновляется сама по мере
-- появления новых врачей в realt_doctor_month, руками список поддерживать
-- не нужно. Не участвует в расчётах напрямую, только как справочник.

SELECT DISTINCT doctor_name AS "Врач"
FROM realt_doctor_month
WHERE doctor_name IS NOT NULL AND doctor_name != ''
ORDER BY doctor_name
