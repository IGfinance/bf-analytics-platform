-- Metabase: "Список - Bottling - Компании" (id 207), коллекция
-- "Bottling | Админка" (15). Служебная карточка — источник значений
-- (values_source_type: card) для дашбордного фильтра "Компания" на
-- "Дашборд - Bottling - Выручка" (id 16). Не выносится на дашборд сама
-- (правило иерархии: Таблицы/справочники на дашборд не идут).

SELECT DISTINCT counterparty AS "Компания"
FROM realization_revenue
ORDER BY counterparty
