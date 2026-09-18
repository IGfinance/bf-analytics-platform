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
-- 2026-09-19: добавлена «Полная выручка (с ШАА)» (full_revenue — единственная
-- строка, где ШАА не исключается) и «Выручка с 1 визита ШАА»
-- (new_client_revenue_shaa — та же логика, что «Выручка с 1 визита», но
-- отдельная когорта «первый визит к ШАА»). «Выручка с первых визитов»
-- переименована в «Выручка с 1 визита» (формула не менялась).
-- 2026-09-19 (ещё правка): добавлены «Кол-во 1 визитов»/«Кол-во 1 визитов
-- ШАА» (= new_clients/new_clients_shaa под другой подписью — количество, а
-- не выручка) и «Визиты на нового клиента (3 мес, скользящее)» —
-- когортная метрика: для клиентов, ставших новыми в месяце M, считаем ИХ
-- визиты за месяцы [M..M+2] и делим на количество этих клиентов. «За год»
-- этой строки — НЕ сумма помесячных средних (та же ловушка, что со
-- «Средний чек»), а sum(«Визиты новых клиентов (3 мес, сумма)») /
-- sum(«Новые клиенты») за год. ВАЖНО: последние 1-2 загруженных месяца
-- занижены — окно уходит в ещё не загруженные визиты (см. комментарий к
-- new_client_visits_3m в schema_realt_metrics_views.sql).

SELECT "Метрика","Янв","Фев","Мар","Апр","Май","Июн","Июл","Авг","Сен","Окт","Ноя","Дек","За год"
FROM (
SELECT 1 AS rn, 'Полная выручка (с ШАА)' AS "Метрика",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=1)  AS "Янв",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=2)  AS "Фев",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=3)  AS "Мар",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=4)  AS "Апр",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=5)  AS "Май",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=6)  AS "Июн",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=7)  AS "Июл",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=8)  AS "Авг",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=9)  AS "Сен",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=10) AS "Окт",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=11) AS "Ноя",
    sumIf(toFloat64("Полная выручка (с ШАА)"), toMonth("Месяц")=12) AS "Дек",
    sum(toFloat64("Полная выручка (с ШАА)"))                        AS "За год"
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
UNION ALL
SELECT 2, 'Выручка',
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
SELECT 3, 'Визиты',
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
SELECT 4, 'Клиенты',
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
SELECT 5, 'Средний чек',
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
SELECT 6, 'Новые клиенты',
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
SELECT 7, 'Кол-во 1 визитов',
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=1),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=2),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=3),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=4),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=5),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=6),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=7),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=8),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=9),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=10),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=11),
    sumIf(toFloat64("Кол-во 1 визитов"), toMonth("Месяц")=12),
    sum(toFloat64("Кол-во 1 визитов"))
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
UNION ALL
SELECT 8, 'Кол-во 1 визитов ШАА',
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=1),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=2),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=3),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=4),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=5),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=6),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=7),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=8),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=9),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=10),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=11),
    sumIf(toFloat64("Кол-во 1 визитов ШАА"), toMonth("Месяц")=12),
    sum(toFloat64("Кол-во 1 визитов ШАА"))
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
UNION ALL
SELECT 9, 'Выручка с 1 визита',
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=1),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=2),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=3),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=4),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=5),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=6),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=7),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=8),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=9),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=10),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=11),
    sumIf(toFloat64("Выручка с 1 визита"), toMonth("Месяц")=12),
    sum(toFloat64("Выручка с 1 визита"))
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
UNION ALL
SELECT 10, 'Выручка с 1 визита ШАА',
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=1),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=2),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=3),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=4),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=5),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=6),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=7),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=8),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=9),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=10),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=11),
    sumIf(toFloat64("Выручка с 1 визита ШАА"), toMonth("Месяц")=12),
    sum(toFloat64("Выручка с 1 визита ШАА"))
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
UNION ALL
-- «За год» здесь тоже НЕ сумма помесячных средних — а сумма визитов
-- когорт за год / сумма новых клиентов за год (см. шапку файла).
SELECT 11, 'Визиты на нового клиента (3 мес, скользящее)',
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=1),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=2),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=3),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=4),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=5),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=6),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=7),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=8),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=9),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=10),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=11),
    sumIf(toFloat64("Визиты на нового клиента (3 мес, скользящее)"), toMonth("Месяц")=12),
    sum(toFloat64("Визиты новых клиентов (3 мес, сумма)")) / nullIf(sum(toFloat64("Новые клиенты")), 0)
FROM {{#98}}
WHERE toYear("Месяц") = toInt32({{year}})
) ORDER BY rn
