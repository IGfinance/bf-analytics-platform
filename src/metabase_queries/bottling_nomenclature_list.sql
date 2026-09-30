-- Metabase: "Список - Bottling - Номенклатура" (id 208), коллекция
-- "Bottling | Админка" (15). Служебная карточка — источник значений
-- (values_source_type: card) для дашбордного фильтра "Продукт" на
-- "Дашборд - Bottling - Выручка" (id 16). Не выносится на дашборд сама
-- (правило иерархии: Таблицы/справочники на дашборд не идут).

SELECT DISTINCT nomenclature AS "Номенклатура"
FROM realization_revenue
ORDER BY nomenclature
