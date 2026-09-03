-- Metabase: native SQL карточек "Таблица - Метрики для отчета Wb" (id 40) и
-- "Таблица - Полный отчет Wb" (id 42) — обе идентичны с 2026-09-03, обе
-- разворачивают "Модель - WB метрики по кабинету и месяцу" (см.
-- wb_metrics_model.sql) в long-формат (строка = метрика), нужный для
-- Metabase pivot table (visual-карточки "Визуал - ..." строят breakout по
-- колонкам metric/month поверх этого).
--
-- {{#49}} — Metabase-плейсхолдер card-ссылки на модель. Это НЕ переносимый
-- SQL: если модель пересоздать, id изменится и текст карточки в Metabase
-- нужно поправить руками (этот файл — документация того, что должно быть
-- в Metabase, не то, что можно скопипастить в консоль ClickHouse — для
-- прямого запуска см. wb_metrics_model.sql, он самодостаточный).
--
-- До 2026-09-03 карточки 40 и 42 пересчитывали формулы метрик независимо
-- друг от друга (и от reconciliation_rules_wb.yaml) — см. инцидент 2026-09-03
-- в .claude/knowledge/architecture-standarts.md. Теперь обе читают из одной
-- модели, разночтений между панелями дашборда быть не должно.
--
-- Дата "заякорена" на 12:00 (INTERVAL 12 HOUR) внутри модели, а не 00:00 —
-- иначе Report Timezone в Metabase сдвигает 1-е число месяца на последний
-- день предыдущего (28/29/30/31).

SELECT * FROM (
SELECT "Месяц" AS month, '01 Кол-во продаж' AS metric, toFloat64("Кол-во продаж") AS value FROM {{#49}}
UNION ALL SELECT "Месяц", '02 Продажи + СПП', toFloat64("Продажи" + "СПП") FROM {{#49}}
UNION ALL SELECT "Месяц", '03 Продажи', toFloat64("Продажи") FROM {{#49}}
UNION ALL SELECT "Месяц", '04 СПП', toFloat64("СПП") FROM {{#49}}
UNION ALL SELECT "Месяц", '05 Комиссия ВБ', toFloat64("Комиссия ВБ") FROM {{#49}}
UNION ALL SELECT "Месяц", '06 К перечислению за товар', toFloat64("К перечислению за товар") FROM {{#49}}
UNION ALL SELECT "Месяц", '07 Логистика', toFloat64("Логистика прямая" + "Логистика обратная") FROM {{#49}}
UNION ALL SELECT "Месяц", '07.01 Логистика прямая', toFloat64("Логистика прямая") FROM {{#49}}
UNION ALL SELECT "Месяц", '07.02 Логистика обратная', toFloat64("Логистика обратная") FROM {{#49}}
UNION ALL SELECT "Месяц", '07.03 Компенсация логистики/склада', toFloat64("Компенсация логистики склада") FROM {{#49}}
UNION ALL SELECT "Месяц", '08 Штрафы', toFloat64("Штрафы") FROM {{#49}}
UNION ALL SELECT "Месяц", '09 Доплаты', toFloat64("Доплаты") FROM {{#49}}
UNION ALL SELECT "Месяц", '10 Хранение', toFloat64("Хранение") FROM {{#49}}
UNION ALL SELECT "Месяц", '11 Платная приемка', toFloat64("Платная приемка") FROM {{#49}}
UNION ALL SELECT "Месяц", '12 Удержание', toFloat64("Удержание") FROM {{#49}}
UNION ALL SELECT "Месяц", '13 Скидка Wibes', toFloat64("Скидка Wibes") FROM {{#49}}
UNION ALL SELECT "Месяц", '14 Продвижение WB', toFloat64("Продвижение WB") FROM {{#49}}
UNION ALL SELECT "Месяц", '15 К перечислению', toFloat64("К перечислению итого") FROM {{#49}}
)
ORDER BY month, metric
