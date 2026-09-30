-- Metabase: "Визуал - Bottling - Выручка по компаниям и месяцам" (id 209,
-- сводная таблица: строки — компания (+ строка "ИТОГО" сверху), столбцы
-- — месяц в формате МММ-ГГ (+ столбец "Итого <ГГ>" после декабря каждого
-- года). Коллекция "Bottling | Админка" (15). Дашборд: "Дашборд -
-- Bottling - Выручка" (id 16, dashcard 91).
-- ·
-- Источник — VIEW bottling.realization_revenue напрямую (формула выручки
-- и фильтр проведения уже внутри неё, см.
-- src/schema_bottling_realization.sql) — тот же источник истины, что у
-- Модели "Модель - Bottling - Выручка по месяцам" (id 205).
-- ·
-- Фильтры (дашборд, id 16): Компания/Продукт — Field Filter (checkbox-
-- мультивыбор "IN (...)" из коробки, НЕ текстовый сентинел), таргет —
-- реальные field_id VIEW realization_revenue (counterparty=1925,
-- nomenclature=1929). 2026-09-30: сделаны ВЗАИМНО каскадными
-- (`filteringParameters` у каждого указывает на id другого) — выбор
-- компании сужает список продуктов до реально проданных ей, и наоборот.
-- Работает через штатный Metabase chain-filter
-- (`/api/dashboard/:id/params/:param-id/values`), НЕ через служебные
-- карточки-справочники (bottling_companies_list.sql /
-- bottling_nomenclature_list.sql остались в коллекции, но больше не
-- подключены как values_source — каскад требует "родной" источник
-- значений по полю, source-type "card" каскад ломает, см. вики-гочтю
-- "Metabase каскадные фильтры требуют реальный field_id, values_source
-- card их ломает"). Период — пара start_month/end_month, опциональные
-- скобки [[ ]], как в card 189/190 (когорты Реальта).
-- ·
-- Строка "ИТОГО" / столбцы "Итого <ГГ>" — НЕ настоящий серверный
-- display:"pivot" (на native SQL он молча ломается, см. вики "Metabase
-- pivot не работает на native SQL"), а вручную сконструированные
-- дополнительные строки результата (UNION ALL), которые клиентский
-- table.pivot просто раскладывает в нужные ячейки кросс-таба. Порядок
-- строк/столбцов в table.pivot определяется порядком ПЕРВОГО появления
-- значения в результате (не алфавитный) — гарантируется явным ORDER BY:
-- строка ИТОГО идёт первой (охватывает все столбцы сразу, поэтому
-- целиком задаёт порядок столбцов), дальше компании по алфавиту;
-- внутри каждой строки — месяцы по toYYYYMM, с синтетическим ключом
-- год*100+13 для "Итого <год>", который сортируется сразу после декабря
-- этого года и перед январём следующего.
-- ·
-- ВАЖНО — лимит 2000 строк на native-запросы (не обходится LIMIT в SQL,
-- см. вики-гочтю "Metabase native-запросы молча обрезаются до 2000
-- строк"). У параметра "С месяца" дефолт 2025-01 — с ним этот запрос
-- даёт 1195 строк (реальные + служебные строки итогов), с запасом.
--
-- Отображение: "Выручка" округлена до целых рублей на уровне
-- visualization_settings.column_settings (decimals: 0), не в самом SQL —
-- в данных копейки остаются, это только форматирование ячеек.

WITH filtered AS (
    SELECT counterparty, month, amount
    FROM realization_revenue
    WHERE 1 = 1
        [[ AND {{company}} ]]
        [[ AND {{product}} ]]
        [[ AND month >= {{start_month}} ]]
        [[ AND month < {{end_month}} + INTERVAL 1 MONTH ]]
),
month_lbl AS (
    SELECT
        counterparty,
        month,
        concat(
            multiIf(toMonth(month)=1,'Янв', toMonth(month)=2,'Фев', toMonth(month)=3,'Мар',
                    toMonth(month)=4,'Апр', toMonth(month)=5,'Май', toMonth(month)=6,'Июн',
                    toMonth(month)=7,'Июл', toMonth(month)=8,'Авг', toMonth(month)=9,'Сен',
                    toMonth(month)=10,'Окт', toMonth(month)=11,'Ноя', 'Дек'),
            '-', substring(toString(toYear(month)), 3, 2)
        ) AS lbl,
        amount
    FROM filtered
),
base AS (
    -- Компания x месяц (реальные данные)
    SELECT counterparty AS company, 0 AS company_is_total, toYYYYMM(month) AS col_sort,
           any(lbl) AS col_label, sum(amount) AS revenue
    FROM month_lbl GROUP BY counterparty, month

    UNION ALL

    -- Компания x "Итого <год>" (субтотал по году для компании, справа от декабря)
    SELECT counterparty AS company, 0 AS company_is_total, toYear(month)*100+13 AS col_sort,
           concat('Итого ', substring(toString(toYear(month)), 3, 2)) AS col_label,
           sum(amount) AS revenue
    FROM month_lbl GROUP BY counterparty, toYear(month)

    UNION ALL

    -- "ИТОГО" x месяц (сумма по всем компаниям за месяц, строка сверху)
    SELECT 'ИТОГО' AS company, 1 AS company_is_total, toYYYYMM(month) AS col_sort,
           any(lbl) AS col_label, sum(amount) AS revenue
    FROM month_lbl GROUP BY month

    UNION ALL

    -- "ИТОГО" x "Итого <год>" (сумма по всем компаниям за год)
    SELECT 'ИТОГО' AS company, 1 AS company_is_total, toYear(month)*100+13 AS col_sort,
           concat('Итого ', substring(toString(toYear(month)), 3, 2)) AS col_label,
           sum(amount) AS revenue
    FROM month_lbl GROUP BY toYear(month)
)
SELECT
    company   AS "Компания",
    col_label AS "Месяц",
    revenue   AS "Выручка"
FROM base
ORDER BY company_is_total DESC, company, col_sort
