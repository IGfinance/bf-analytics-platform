-- Расходы на продвижение WB из рекламного API (advert-api.wildberries.ru,
-- GET /adv/v1/upd — «история затрат»: одна строка = одно списание по кампании,
-- в разрезе документа). Токен — тот же, что для финансового API (категория
-- «Продвижение», бит 6 — есть у всех WB-кабинетов). Это ПЕРВОИСТОЧНИК того,
-- что маркетолог вручную копирует в Google-Таблицу «Продвижение CS»
-- (wb_promotion), поэтому сверка двух источников — wb_promotion_api_vs_sheet_month.
-- Артикул в API нет: он зашит в имя кампании («<id>/<артикул>/<Поиск|АРК>»),
-- берём второй сегмент — см. wb_promotion_api_by_article_month.
--
-- Ключ ReplacingMergeTree — естественный (кабинет, кампания, документ, время,
-- источник списания): повторная загрузка окна перезаписывает те же строки,
-- ни снимки, ни DELETE не нужны.
CREATE TABLE IF NOT EXISTS wb_promotion_api
(
    cabinet        String,
    advert_id      UInt64            COMMENT 'ID кампании',
    upd_num        UInt64            COMMENT 'Номер документа списания (updNum)',
    upd_time       DateTime          COMMENT 'Время списания (updTime), приведено к МСК',
    promo_date     Date              COMMENT 'Дата списания по МСК',
    camp_name      String            COMMENT 'Имя кампании — содержит артикул',
    advert_type    Nullable(UInt16),
    advert_status  Nullable(Int16),
    payment_type   String            COMMENT 'Источник списания — Баланс/Бонусы/…',
    upd_sum        Float64           COMMENT 'Сумма списания, руб',
    currency       String,
    loaded_at      DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(promo_date)
ORDER BY (cabinet, advert_id, upd_num, upd_time, payment_type);

-- Расход по кабинету/артикулу/месяцу. Артикул — второй сегмент имени кампании;
-- имя без такого сегмента → «без артикула» (не выбрасываем, сумма сохраняется).
CREATE OR REPLACE VIEW wb_promotion_api_by_article_month AS
SELECT
    cabinet,
    if(length(splitByChar('/', camp_name)) >= 3 AND splitByChar('/', camp_name)[2] != '',
       splitByChar('/', camp_name)[2], 'без артикула') AS article,
    toStartOfMonth(promo_date) AS month,
    sum(upd_sum) AS promotion_rub,
    count() AS rows_total,
    uniqExact(advert_id) AS campaigns
FROM wb_promotion_api
GROUP BY cabinet, article, month;

-- Сверка API с ручной Google-Таблицей (wb_promotion_current, проект 1 = CloudSix):
-- по месяцу и артикулу, обе суммы и разница. Строка есть, даже если артикул
-- только в одном источнике (FULL JOIN) — расхождения не прячутся.
CREATE OR REPLACE VIEW wb_promotion_api_vs_sheet_month AS
SELECT
    coalesce(nullIf(a.month, toDate(0)), s.month) AS month,
    if(a.article != '', a.article, s.article) AS article,
    a.promotion_rub AS api_rub,
    s.promotion_rub AS sheet_rub,
    a.promotion_rub - s.promotion_rub AS diff_rub
FROM
    (SELECT article, month, promotion_rub FROM wb_promotion_api_by_article_month WHERE cabinet = 'CloudSix') AS a
FULL OUTER JOIN
    (SELECT if(article IS NULL OR article = '' OR article LIKE '#%', 'без артикула', article) AS article,
            toStartOfMonth(promo_date) AS month, sum(amount) AS promotion_rub
     FROM wb_promotion_current WHERE project_id = 1 GROUP BY article, month) AS s
ON a.article = s.article AND a.month = s.month;
