-- Metabase: «Таблица - Детальный адаптер …» (4 карточки, коллекция «CloudSix | Админка», id 11).
-- Плоская таблица всех статей отчёта: Кабинет, Бренд, Группа и Статья повторяются в каждой строке,
-- месяцы выбранного года — столбцами Янв…Дек, справа «Итого». Блок из столбцов убран (владелец
-- 2026-10-04): справочные группы называются «Справочно: …», порядок блоков держит ORDER BY blk.
-- Сводная таблица (Metabase pivot) отвергнута: для native SQL она не работает, поверх модели делает
-- по 8 запросов на карточку (8–14 с), а плоская таблица — один запрос.
--
-- Шаблон ниже — карточка WB API; остальные отличаются только вьюхой в FROM и отсутствием комментария
-- про 2026 год (он нужен только API-данным WB):
--   237 Таблица - Детальный адаптер WB API    — detail_adapter_wb_api
--   238 Таблица - Детальный адаптер WB xlsx   — detail_adapter_wb
--   239 Таблица - Детальный адаптер Ozon API  — detail_adapter_ozon_api
--   240 Таблица - Детальный адаптер Ozon xlsx — detail_adapter_ozon
-- Переменные (все три — фильтры дашбордов): year (число, по умолчанию 2026), cabinet, brand (текст).
-- Дашборды: 20 «04 … Детальный адаптер API» (237, 239), 21 «05 … Детальный адаптер xlsx» (238, 240).

-- Загружен только 2026 год (решение владельца 2026-09-28): конец 2025 внутри отчётов — огрызок периода, не данные.
SELECT
    cabinet AS "Кабинет",
    brand   AS "Бренд",
    if(startsWith(blk, '1 '), grp, concat('Справочно: ', replaceRegexpOne(replaceRegexpOne(blk, '^\\d+ ', ''), ' \\(справочно\\)$', ''),
        if(startsWith(blk, '7 '), concat(' — ', replaceRegexpOne(grp, '^\\d+ ', '')), ''))) AS "Группа",
    art     AS "Статья",
    sumIf(amount, month = concat(toString({{year}}), '-01')) AS "Янв",
    sumIf(amount, month = concat(toString({{year}}), '-02')) AS "Фев",
    sumIf(amount, month = concat(toString({{year}}), '-03')) AS "Мар",
    sumIf(amount, month = concat(toString({{year}}), '-04')) AS "Апр",
    sumIf(amount, month = concat(toString({{year}}), '-05')) AS "Май",
    sumIf(amount, month = concat(toString({{year}}), '-06')) AS "Июн",
    sumIf(amount, month = concat(toString({{year}}), '-07')) AS "Июл",
    sumIf(amount, month = concat(toString({{year}}), '-08')) AS "Авг",
    sumIf(amount, month = concat(toString({{year}}), '-09')) AS "Сен",
    sumIf(amount, month = concat(toString({{year}}), '-10')) AS "Окт",
    sumIf(amount, month = concat(toString({{year}}), '-11')) AS "Ноя",
    sumIf(amount, month = concat(toString({{year}}), '-12')) AS "Дек",
    sum(amount) AS "Итого"
FROM detail_adapter_wb_api
WHERE startsWith(month, concat(toString({{year}}), '-'))
[[AND cabinet = {{cabinet}}]]
[[AND brand = {{brand}}]]
GROUP BY cabinet, brand, blk, grp, art
HAVING sum(abs(amount)) > 0
ORDER BY cabinet, brand, blk, grp, art
