-- «Продвижение CS» — расход на продвижение (реклама) поартикульно, из
-- Google-Таблицы, которую маркетолог ведёт вручную (загрузка отчётов
-- кабинетов WB/Ozon + справочник кампания/SKU→артикул). НЕ путать с
-- promotion_cost в wb_metrics_by_sku_month/ozon_metrics_by_sku_month —
-- тот считается из официальных финотчётов площадок (wb_reports/
-- ozon_realization) и остаётся источником истины для сверки; эта таблица —
-- отдельный, более детальный (по кампании/SKU) источник для маркетинг-аналитики.
--
-- wb_promotion — вкладка «Продв WB»: построчно по кампании (каждая строка —
-- одно списание за день). article (столбец I) — уже готовый результат ВПР
-- по wb_promotion_reference, который ведётся в самой Google-Таблице вручную;
-- здесь просто сохраняем то, что в ячейке.
CREATE TABLE IF NOT EXISTS wb_promotion
(
    project_id        UInt32,
    campaign_id       Nullable(String)  COMMENT 'ID кампании (столбец A)',
    campaign          String            COMMENT 'Имя кампании (столбец B) — часто содержит артикул в самом тексте',
    section           Nullable(String)  COMMENT 'Раздел — Ручная/Единая (столбец C)',
    promo_date        Nullable(Date)    COMMENT 'Дата списания (столбец D)',
    write_off_source  Nullable(String)  COMMENT 'Источник списания — Баланс/Промо бонусы (столбец E)',
    amount            Nullable(Float64) COMMENT 'Сумма списания, руб (столбец F) — используется для подсчёта продвижения поартикульно',
    document_number   Nullable(String)  COMMENT 'Номер документа (столбец G)',
    article           Nullable(String)  COMMENT 'Артикул (тех. столбец I, ВПР по wb_promotion_reference) — используется для подсчёта продвижения поартикульно',
    row_num           UInt32            COMMENT 'Позиция строки во вкладке, для дедупа при перезаливке',
    source_file       String,
    loaded_at         DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(promo_date, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);

-- ozon_promotion — вкладка «Продв Ozon»: построчно по SKU+кампании. В
-- отличие от WB здесь нет посуточной даты — отчёт выгружается за весь
-- месяц целиком, поэтому promo_date (столбец U) проставляется вручную
-- 1-м числом месяца, просто чтобы можно было смотреть хотя бы помесячно.
CREATE TABLE IF NOT EXISTS ozon_promotion
(
    project_id                    UInt32,
    sku                           String            COMMENT 'SKU товара (столбец A)',
    product_name                  Nullable(String)  COMMENT 'Название товара (столбец B)',
    tool                          Nullable(String)  COMMENT 'Инструмент — напр. «Оплата за клик» (столбец C)',
    placement                     Nullable(String)  COMMENT 'Место размещения (столбец D)',
    campaign_id                   Nullable(String)  COMMENT 'ID кампании (столбец E)',
    spend_rub                     Nullable(Float64) COMMENT 'Расход, ₽ (столбец F) — используется для подсчёта продвижения поартикульно',
    drr_in_promotion_pct          Nullable(Float64) COMMENT 'ДРР в продвижении, % (столбец G)',
    sales_in_promotion_rub        Nullable(Float64) COMMENT 'Продажи в продвижении, ₽ (столбец H)',
    items_sold                    Nullable(Float64) COMMENT 'Продано товаров, шт (столбец I)',
    sales_in_promotion_model_rub  Nullable(Float64) COMMENT 'Продажи в продвижении с заказов модели, ₽ (столбец J)',
    items_sold_model              Nullable(Float64) COMMENT 'Продано товаров модели, шт (столбец K)',
    ctr_pct                       Nullable(Float64) COMMENT 'CTR, % (столбец L)',
    impressions                   Nullable(Float64) COMMENT 'Показы (столбец M)',
    clicks                        Nullable(Float64) COMMENT 'Клики (столбец N)',
    cart_adds                     Nullable(Float64) COMMENT 'Добавления в корзину, шт (столбец O)',
    cart_conversion_pct           Nullable(Float64) COMMENT 'Конверсия в корзину, % (столбец P)',
    drr_pct                       Nullable(Float64) COMMENT 'ДРР, % (столбец Q)',
    cost_per_order_rub            Nullable(Float64) COMMENT 'Затраты на заказ, ₽ (столбец R)',
    avg_click_cost_rub            Nullable(Float64) COMMENT 'Средняя стоимость клика, ₽ (столбец S)',
    promo_date                    Nullable(Date)    COMMENT 'Дата (тех. столбец U) — вручную ставится 1-м числом месяца отчёта; используется для подсчёта продвижения поартикульно',
    article                       Nullable(String)  COMMENT 'Артикул (тех. столбец V, ВПР по ozon_promotion_reference) — используется для подсчёта продвижения поартикульно',
    row_num                       UInt32            COMMENT 'Позиция строки во вкладке, для дедупа при перезаливке',
    source_file                   String,
    loaded_at                     DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(promo_date, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);

-- wb_promotion_reference — левый блок вкладки «Справочник» (столбцы A/B,
-- «Для WB»): Кампания → Артикул, ведётся вручную (при новой кампании
-- маркетолог вынимает артикул из её имени и прописывает сюда). Источник
-- истины для формулы ВПР в самой Google-Таблице (столбец I «Продв WB»).
CREATE TABLE IF NOT EXISTS wb_promotion_reference
(
    project_id   UInt32,
    campaign     String            COMMENT 'Имя кампании — ключ, совпадает с wb_promotion.campaign',
    article      Nullable(String)  COMMENT 'Артикул, вручную вынутый из имени кампании',
    row_num      UInt32            COMMENT 'Позиция строки во вкладке, для дедупа при перезаливке',
    source_file  String,
    loaded_at    DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (project_id, source_file, row_num);

-- ozon_promotion_reference — правый блок вкладки «Справочник» (столбцы D/E,
-- «Для Ozon»): SKU → Артикул, берётся вручную из финотчётов Ozon.
CREATE TABLE IF NOT EXISTS ozon_promotion_reference
(
    project_id   UInt32,
    sku          String            COMMENT 'SKU — ключ, совпадает с ozon_promotion.sku',
    article      Nullable(String)  COMMENT 'Артикул из финотчёта Ozon',
    row_num      UInt32            COMMENT 'Позиция строки во вкладке, для дедупа при перезаливке',
    source_file  String,
    loaded_at    DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (project_id, source_file, row_num);

-- promotion_by_article_month — семантический слой «Продвижение CS»: расход
-- на продвижение поартикульно по месяцам, из обоих источников (WB —
-- суммируется из посуточных строк; Ozon — уже помесячно). Независимый
-- источник от promotion_cost в wb_metrics_by_sku_month/ozon_metrics_by_sku_month
-- (тот — из официальных финотчётов площадок, этот — из ручной Google-Таблицы
-- маркетолога); не смешивать при анализе без явного сопоставления.
CREATE VIEW IF NOT EXISTS promotion_by_article_month AS
SELECT
    project_id,
    'wb' AS platform,
    article,
    toStartOfMonth(promo_date) AS month,
    sum(amount) AS promotion_rub
FROM wb_promotion
WHERE article IS NOT NULL AND promo_date IS NOT NULL
GROUP BY project_id, article, month
UNION ALL
SELECT
    project_id,
    'ozon' AS platform,
    article,
    toStartOfMonth(promo_date) AS month,
    sum(spend_rub) AS promotion_rub
FROM ozon_promotion
WHERE article IS NOT NULL AND promo_date IS NOT NULL
GROUP BY project_id, article, month;
