-- Metabase: native SQL карточки "Таблица - Реальт - Ежемесячные метрики"
-- (id 186), дашборд "Реальт - Ежемесячные метрики" (id 8).
-- 2026-09-18: пересобрана из GUI-question (breakout по месяцу + 3
-- Metric поверх модели 98) в native SQL с ручным разворотом месяцев в
-- столбцы. Причина: GUI-агрегация кладёт метрики в СТОЛБЦЫ (по одной
-- строке на месяц), а визуал "Сводная таблица" в Metabase умеет строить
-- строки только по РАЗМЕРНОСТИ (breakout), а не по нескольким колонкам
-- агрегации — три метрики так и остаются тремя соседними столбцами под
-- каждым месяцем, а не строками. Тот же приём разворота уже используется
-- в realt_unitka_by_doctor.sql (карточка 183) — здесь применён к тем же
-- трём базовым метрикам без разбивки по врачам/ролям.
-- {{#98}} — плейсхолдер card-ссылки на "Модель - Реальт метрики по
-- месяцам" (тонкая обёртка над realt_metrics_by_month, см.
-- realt_metrics_model.sql). Если модель пересоздать, id изменится и
-- текст карточки в Metabase нужно поправить руками.
-- Гочтя (см. realt_doctors_table.sql/realt_unitka_by_doctor.sql): в этом
-- файле нет ни одной голой строки-комментария "--" без пробела/текста
-- после — такая строка ломает разбор параметров в ClickHouse
-- JDBC-драйвере Metabase, даже без переменных в самом комментарии.
-- 2026-09-18: добавлены строки «Средний чек», «Новые клиенты», «Выручка
-- с первых визитов» (по просьбе клиента). Для «Средний чек» столбец «За
-- год» — НЕ sum(avg_check) по месяцам (сумма средних величин была бы
-- бессмысленной), а sum(Выручка)/sum(Визиты) за год — см. блок ниже.
-- «Выручка с первых визитов» = new_client_revenue из
-- realt_metrics_by_month (см. schema_realt_metrics_views.sql) — сумма
-- amount по визитам с visit_seq=1, та же когорта, что и «Новые клиенты».

SELECT "Метрика","Янв","Фев","Мар","Апр","Май","Июн","Июл","Авг","Сен","Окт","Ноя","Дек","За год"
FROM (
SELECT 1 AS rn, 'Выручка' AS "Метрика",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=1)  AS "Янв",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=2)  AS "Фев",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=3)  AS "Мар",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=4)  AS "Апр",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=5)  AS "Май",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=6)  AS "Июн",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=7)  AS "Июл",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=8)  AS "Авг",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=9)  AS "Сен",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=10) AS "Окт",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=11) AS "Ноя",
    sumIf(toFloat64("Выручка"), toMonth("Месяц")=12) AS "Дек",
    sum(toFloat64("Выручка"))                        AS "За год"
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
UNION ALL
SELECT 2, 'Визиты',
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=1),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=2),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=3),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=4),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=5),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=6),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=7),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=8),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=9),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=10),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=11),
    sumIf(toFloat64("Визиты"), toMonth("Месяц")=12),
    sum(toFloat64("Визиты"))
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
UNION ALL
SELECT 3, 'Клиенты',
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=1),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=2),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=3),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=4),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=5),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=6),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=7),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=8),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=9),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=10),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=11),
    sumIf(toFloat64("Клиенты"), toMonth("Месяц")=12),
    sum(toFloat64("Клиенты"))
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
UNION ALL
-- «За год» здесь — НЕ sum(avg_check) по месяцам (это была бы сумма
-- средних, бессмысленная величина), а выручка за год / визиты за год.
SELECT 4, 'Средний чек',
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=1),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=2),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=3),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=4),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=5),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=6),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=7),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=8),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=9),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=10),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=11),
    sumIf(toFloat64("Средний чек"), toMonth("Месяц")=12),
    sum(toFloat64("Выручка")) / nullIf(sum(toFloat64("Визиты")), 0)
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
UNION ALL
SELECT 5, 'Новые клиенты',
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=1),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=2),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=3),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=4),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=5),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=6),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=7),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=8),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=9),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=10),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=11),
    sumIf(toFloat64("Новые клиенты"), toMonth("Месяц")=12),
    sum(toFloat64("Новые клиенты"))
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
UNION ALL
SELECT 6, 'Выручка с первых визитов',
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=1),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=2),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=3),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=4),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=5),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=6),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=7),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=8),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=9),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=10),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=11),
    sumIf(toFloat64("Выручка с первых визитов"), toMonth("Месяц")=12),
    sum(toFloat64("Выручка с первых визитов"))
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
) ORDER BY rn
