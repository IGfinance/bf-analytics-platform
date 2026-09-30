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
-- Фильтры (дашборд, id 16): Компания/Продукт/Период — ВСЕ три Field
-- Filter, таргет на реальные field_id VIEW realization_revenue
-- (counterparty=1925, nomenclature=1929, month=1924). 2026-09-30:
-- Компания/Продукт сделаны ВЗАИМНО каскадными между собой
-- (`filteringParameters` у каждого указывает на id другого), позже в
-- тот же день — оба дополнительно каскадируют ОТ Периода тоже (третий
-- id в `filteringParameters`): выбор компании/продукта/периода сужает
-- значения двух остальных фильтров до реально сочетающихся комбинаций.
-- Период сам ни от чего не зависит (не имеет смысла ограничивать месяцы
-- по выбранной компании).
-- ·
-- Период раньше был парой текстовых переменных start_month/end_month
-- (опциональные скобки [[ ]]) — пришлось перевести в ОДИН Field Filter
-- "date/range" ({{period}}, поле month=1924), т.к. каскад (chain-filter)
-- умеет считать зависимые значения только от параметров, замапленных
-- через `dimension`, не через `variable` — обычная текстовая переменная
-- в принципе не может быть "родителем" каскада. Тот же паттерн уже был
-- в проекте (Период → Артикул на дашборде 4 "WB Полный отчёт по
-- артикулу"), так что это не новое решение, а возврат к проверенному.
-- ·
-- Причина завести каскад от периода: без него чекбокс-список компаний
-- показывал все 402 компании независимо от периода — при дефолтном
-- периоде "с 2025-01" реально продававших всего ~117 (285 из 402, 71%,
-- не имели продаж с начала 2025; 323, 80%, не имели продаж в 2026).
-- ·
-- Работает через штатный Metabase chain-filter
-- (`/api/dashboard/:id/params/:param-id/values`), НЕ через служебные
-- карточки-справочники (bottling_companies_list.sql /
-- bottling_nomenclature_list.sql остались в коллекции, но больше не
-- подключены как values_source — каскад требует "родной" источник
-- значений по полю, source-type "card" каскад ломает, см. вики-гочтю
-- "Metabase каскадные фильтры требуют реальный field_id, values_source
-- card их ломает").
-- ·
-- Известная мелкая аномалия в данных (не чинится здесь, это реальные
-- данные клиента): 2 компании с нулевой суммарной выручкой за всю
-- историю ("ЕМР", "\" ЦЕНТР КАПИТАЛ ООО\"") и 23 строки 2017 года с
-- пустым именем контрагента (8300 ₽) — попадают в чекбокс-список
-- Компания как обычные значения, выбор даст пустую/нулевую строку.
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
-- строк"). У параметра "Период" дефолт "с 2025-01-01" — с ним этот
-- запрос даёт ~1195 строк (реальные + служебные строки итогов), с
-- запасом.
-- ·
-- Отображение: "Выручка" округлена до целых рублей на уровне
-- visualization_settings.column_settings (decimals: 0), не в самом SQL —
-- в данных копейки остаются, это только форматирование ячеек.

WITH filtered AS (
    SELECT counterparty, month, amount
    FROM realization_revenue
    WHERE 1 = 1
        [[ AND {{company}} ]]
        [[ AND {{product}} ]]
        [[ AND {{period}} ]]
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
