#!/usr/bin/env python3
"""
Генерирует вьюхи «Детального адаптера»: ВСЕ статьи отчётов WB и Ozon в длинном
формате (кабинет × бренд × месяц × блок × группа × статья → сумма). Результат —
src/schema_detail_adapter_views.sql. Поверх них в Metabase строятся сводные таблицы
с раскрытием строк «Блок → Группа → Статья» и месяцами в столбцах.

ЧТО ТАКОЕ «СТАТЬЯ» (решение владельца 2026-10-04 — использовать статьи самих отчётов):
  * Ozon .xlsx: «группа услуг → тип начисления» ровно как в отчёте (11 групп, ~100 типов);
  * Ozon API: статьи cash-flow-statement (item_name) с русскими названиями, сгруппированные
    категориями канонической вьюхи (логистика, последняя миля, штрафы …);
  * WB: у отчёта нет готовых «статей-столбцов», поэтому группы взяты из формулы
    адаптера, а раскрываются они до реальных значений полей отчёта: «Обоснование для
    оплаты» (К перечислению за товар), «Тип операции» (логистика, штрафы, удержания).

БЛОКИ. Строки «1 Начисления» аддитивны: их сумма = «К перечислению итого» (payable_total)
канонической вьюхи. Остальные блоки — справочные и НЕ складываются с первым (выручка и
комиссия, количество, себестоимость, валовая прибыль, покрытие себестоимости): у каждого
своя единица измерения или это та же сумма под другим углом. Поэтому в сводной таблице
общий итог по всем блокам выключен, подытоги — по блоку и группе.

ФОРМУЛЫ НЕ КОПИРУЮТСЯ. Справочные блоки читаются из бренд-вьюх (они уже совпадают с
каноническими), «Начисления» WB считаются разбором тех же слагаемых по значению поля, а
белый список типов WB и классификация Ozon cash-flow ИЗВЛЕКАЮТСЯ из канонических файлов.
Сумма листьев каждой группы сверяется с канонической метрикой (проверка на данных —
см. docs в шапке src/schema_detail_adapter_views.sql и tests/test_detail_adapter_views.py).

БРЕНД — по правилам бренд-вьюх (пустой/«Нет бренда» → кабинет, CloudSix → «Cloud Six»);
расходы Ozon без артикула / уровня кабинета раскладываются пропорционально выручке бренда
(оценка), всё привязанное к артикулу — точно.

Запуск:
    python3 scripts/gen_detail_adapter_views.py          # записать файл
    python3 scripts/gen_detail_adapter_views.py --check  # только проверить
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "src"
sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen_wb_metrics_brand_views import brand_expr, cab_name_expr  # noqa: E402

CANON_WB_SKU = SRC / "schema_wb_metrics_views_sku.sql"
CANON_CASHFLOW = SRC / "schema_ozon_cashflow_metrics_views.sql"
OUT = SRC / "schema_detail_adapter_views.sql"

BLK_ACCR = "1 Начисления (сумма = К перечислению итого)"
BLK_REV = "2 Выручка и комиссия (справочно)"
BLK_QTY = "3 Количество, шт. (справочно)"
BLK_COGS = "4 Себестоимость (справочно)"
BLK_GP = "5 Валовая прибыль (справочно)"
BLK_COV = "6 Покрытие себестоимости, шт. (справочно)"
BLK_EXCL = "7 Не входит в итог (справочно)"


def q(s: str) -> str:
    """SQL-литерал строки."""
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


# --------------------------------------------------------------------------- WB

def wb_whitelist() -> str:
    """Белый список payment_reason (cs_k_types) — из канонического файла."""
    text = CANON_WB_SKU.read_text(encoding="utf-8")
    m = re.search(r"SELECT arrayJoin\(\[(.*?)\]\) AS v", text, re.S)
    if not m:
        raise SystemExit("в каноническом sku-файле WB не найден cs_k_types — генератор устарел")
    items = re.findall(r"'([^']+)'", m.group(1))
    if len(items) < 10:
        raise SystemExit(f"cs_k_types разобран неверно: {items}")
    return ", ".join(q(i) for i in items)


# регулярки очистки номера документа — те же, что в каноническом файле (дословно)
WB_TYPE_CLEAN = (r"trim(REGEXP_REPLACE(REGEXP_REPLACE(coalesce(logistics_fines_corrections_type, ''), "
                 r"',\\s*документ\\s*№\\s*\\d+', ''), '\\s+\\d+$', ''))")
WB_PROMO = "'Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»'"


def wb_view(api: bool) -> str:
    src = "wb_api_realization_as_reports" if api else "wb_reports"
    suf = "_api" if api else ""
    brand_view = f"wb_metrics_by_cabinet_brand_month{suf}"
    name = f"detail_adapter_wb{suf}"
    brand = brand_expr("cabinet", "brand")
    wl = wb_whitelist()

    # ОДИН проход по сырой таблице: каждая строка отчёта превращается в набор (группа, статья, сумма)
    # через ARRAY JOIN. Раньше каждая статья была отдельным SELECT к b — это 11 сканирований
    # почти миллиона строк API и запрос не укладывался в таймаут Metabase.
    # Внутреннее имя бренда — brand_key, НЕ brand: псевдоним с именем колонки перекрывает её.
    sign_doc = "multiIf(dt = 'продажа', payable_to_seller, dt = 'возврат', -payable_to_seller, toFloat64(0))"
    loy_sign = "if(document_type = 'Возврат', -1, 1)"
    is_promo = f"typ_clean IN ({WB_PROMO})"
    tuples = [
        # 01/02: по «Обоснованию для оплаты», знак по типу документа
        f"if(pr_l IN (SELECT v FROM cs_k_types), '01 К перечислению за товар', '02 Корректировки продаж'), pr, {sign_doc}",
        f"'03 Логистика', typ, -delivery_service_cost",
        f"'04 Штрафы', typ, -total_fines",
        f"'05 Доплаты (корректировка вознаграждения)', 'Корректировка вознаграждения WB', -wb_commission_correction",
        f"'06 Хранение', 'Платное хранение', -storage_cost",
        f"'07 Платная приёмка', 'Платная приёмка', -acceptance_operations",
        f"if({is_promo}, '09 Продвижение WB', '08 Удержания'), typ_clean, -deductions",
        f"'10 Программа лояльности (Wibes)', 'Стоимость участия в программе лояльности', -loyalty_program_cost * {loy_sign}",
        f"'10 Программа лояльности (Wibes)', 'Удержанные баллы лояльности', -loyalty_points_deducted * {loy_sign}",
    ]
    arr = ",\n                ".join(f"({t})" for t in tuples)

    # ОДНО обращение к бренд-вьюхе: она тяжёлая (1-2 с), отдельный SELECT на каждый справочный
    # блок пересчитывал её 5 раз.
    ref_tuples = [
        (BLK_REV, "01 Продажи, СПП и комиссия WB", "Продажи", "sales_amount"),
        (BLK_REV, "01 Продажи, СПП и комиссия WB", "СПП", "spp_amount"),
        (BLK_REV, "01 Продажи, СПП и комиссия WB", "Комиссия WB", "wb_commission"),
        (BLK_QTY, "01 Продано за вычетом возвратов", "Продано, шт.", "sales_qty"),
        (BLK_COGS, "01 Себестоимость проданного", "Себестоимость", "cogs"),
        (BLK_GP, "01 Валовая прибыль", "Валовая прибыль", "gross_profit"),
        (BLK_COV, "01 Покрытие справочником себестоимости", "С себестоимостью, шт.", "cogs_qty_covered"),
        (BLK_COV, "01 Покрытие справочником себестоимости", "Без себестоимости, шт.", "cogs_qty_uncovered"),
    ]
    ref_arr = ", ".join(f"({q(b)}, {q(g)}, {q(a)}, toFloat64({e}))" for b, g, a, e in ref_tuples)
    refs = [f"""    SELECT cabinet, brand, formatDateTime(month, '%Y-%m') AS month, t.1 AS blk, t.2 AS grp, t.3 AS art, t.4 AS amount
    FROM {brand_view}
    ARRAY JOIN [{ref_arr}] AS t"""]
    accr = f"""    SELECT cabinet, brand_key AS brand, month, {q(BLK_ACCR)} AS blk, t.1 AS grp, t.2 AS art, sum(t.3) AS amount
    FROM b
    ARRAY JOIN [
                {arr}
    ] AS t
    GROUP BY cabinet, brand, month, grp, art
    HAVING abs(amount) > 0"""
    body = "\n    UNION ALL\n".join([accr] + refs)
    return f"""CREATE VIEW IF NOT EXISTS {name} AS
WITH
cs_k_types AS (
    SELECT arrayJoin([{wl}]) AS v
),
b AS (
    SELECT
        cabinet,
        {brand} AS brand_key,
        formatDateTime(toStartOfMonth(sale_date), '%Y-%m') AS month,
        lowerUTF8(trim(coalesce(document_type, ''))) AS dt,
        lowerUTF8(trim(coalesce(payment_reason, ''))) AS pr_l,
        coalesce(nullIf(trim(payment_reason), ''), 'Без обоснования') AS pr,
        coalesce(nullIf(trim(logistics_fines_corrections_type), ''), 'Без типа операции') AS typ,
        {WB_TYPE_CLEAN} AS typ_clean,
        document_type,
        toFloat64(coalesce(payable_to_seller, 0)) AS payable_to_seller,
        toFloat64(coalesce(delivery_service_cost, 0)) AS delivery_service_cost,
        toFloat64(coalesce(total_fines, 0)) AS total_fines,
        toFloat64(coalesce(wb_commission_correction, 0)) AS wb_commission_correction,
        toFloat64(coalesce(storage_cost, 0)) AS storage_cost,
        toFloat64(coalesce(acceptance_operations, 0)) AS acceptance_operations,
        toFloat64(coalesce(deductions, 0)) AS deductions,
        toFloat64(coalesce(loyalty_program_cost, 0)) AS loyalty_program_cost,
        toFloat64(coalesce(loyalty_points_deducted, 0)) AS loyalty_points_deducted
    FROM {src}
    WHERE sale_date IS NOT NULL
)
SELECT
    cabinet AS cabinet, brand AS brand, month AS month, blk AS blk, grp AS grp, art AS art,
    toFloat64(amount) AS amount
FROM (
{body}
);

ALTER TABLE {name} COMMENT COLUMN brand 'Бренд (по строке отчёта; пустой — название кабинета, CloudSix = «Cloud Six»).';
ALTER TABLE {name} COMMENT COLUMN blk 'Блок: «1 Начисления» аддитивен (сумма = К перечислению итого), остальные — справочные и не складываются с ним.';
ALTER TABLE {name} COMMENT COLUMN art 'Статья: значение поля отчёта WB — «Обоснование для оплаты» (К перечислению за товар) или «Тип операции» (логистика, штрафы, удержания).';
"""


# --------------------------------------------------------------------------- Ozon

OZON_GROUPS = [
    ("Продажи", "01 Продажи"),
    ("Возвраты", "02 Возвраты"),
    ("Вознаграждение Ozon", "03 Вознаграждение Ozon"),
    ("Услуги доставки", "04 Услуги доставки"),
    ("Услуги агентов", "05 Услуги агентов"),
    ("Услуги партнёров", "06 Услуги партнёров"),
    ("Услуги FBO", "07 Услуги FBO"),
    ("Продвижение и реклама", "08 Продвижение и реклама"),
    ("Другие услуги", "09 Другие услуги и штрафы"),
    ("Другие услуги и штрафы", "09 Другие услуги и штрафы"),
    ("Компенсации и декомпенсации", "10 Компенсации и декомпенсации"),
    ("Прочие начисления", "11 Прочие начисления"),
]


def ozon_group_expr(col: str) -> str:
    g = f"trim({col})"
    arms = ", ".join(f"{g} = {q(a)}, {q(b)}" for a, b in OZON_GROUPS)
    return f"multiIf({arms}, concat('99 ', {g}))"


def ozon_xlsx_view() -> str:
    cab = cab_name_expr("r.cabinet")
    cab_k = cab_name_expr("k.cabinet")
    return f"""CREATE VIEW IF NOT EXISTS detail_adapter_ozon AS
WITH
raw AS (
    SELECT
        r.cabinet AS cabinet,
        formatDateTime(toStartOfMonth(r.accrual_date), '%Y-%m') AS month,
        {ozon_group_expr('r.service_group')} AS grp,
        coalesce(nullIf(trim(r.accrual_type), ''), 'Без типа') AS art,
        if(trim(coalesce(r.article, '')) = '', '', coalesce(nullIf(pb.brand_key, ''), {cab})) AS brand_key,
        toFloat64(r.total_amount) AS amount
    FROM ozon_reports AS r
    LEFT JOIN ozon_product_brands AS pb
           ON pb.cabinet = r.cabinet AND pb.offer_key = lowerUTF8(trim(r.article))
    WHERE r.accrual_date IS NOT NULL
),
att AS (
    -- привязано к артикулу — на бренд артикула ТОЧНО
    SELECT cabinet, month, brand_key AS brand, grp, art, sum(amount) AS amount
    FROM raw WHERE brand_key != '' GROUP BY cabinet, month, brand_key, grp, art
),
un AS (
    -- начисления без артикула (Ozon относит на кабинет целиком) — раскладываются по выручке брендов
    SELECT cabinet, month, grp, art, sum(amount) AS amount
    FROM raw WHERE brand_key = '' GROUP BY cabinet, month, grp, art
),
w AS (
    -- веса раскладки = выручка брендов из КАНОНИЧЕСКОЙ sku-вьюхи (дёшево); совпадают с выручкой в
    -- ozon_metrics_by_cabinet_brand_month, откуда считаются справочные блоки ниже
    SELECT k.cabinet AS cabinet, formatDateTime(k.month, '%Y-%m') AS month,
           coalesce(nullIf(pb.brand_key, ''), {cab_k}) AS brand, greatest(sum(k.sales_amount), 0) AS w
    FROM ozon_metrics_by_sku_month AS k
    LEFT JOIN ozon_product_brands AS pb ON pb.cabinet = k.cabinet AND pb.offer_key = lowerUTF8(trim(k.sku))
    WHERE k.sku != 'без артикула'
    GROUP BY cabinet, month, brand
),
wt AS (
    SELECT cabinet, month, sum(w) AS wsum FROM w GROUP BY cabinet, month
),
recv AS (
    SELECT w.cabinet AS cabinet, w.month AS month, w.brand AS brand, w.w / wt.wsum AS share
    FROM w INNER JOIN wt ON wt.cabinet = w.cabinet AND wt.month = w.month
    WHERE wt.wsum > 0
    UNION ALL
    SELECT u.cabinet AS cabinet, u.month AS month, {cab_name_expr('u.cabinet')} AS brand, toFloat64(1) AS share
    FROM (SELECT DISTINCT cabinet, month FROM un) AS u
    LEFT JOIN wt ON wt.cabinet = u.cabinet AND wt.month = u.month
    WHERE coalesce(wt.wsum, 0) = 0
),
accr AS (
    SELECT cabinet, brand, month, grp, art, amount FROM att
    UNION ALL
    SELECT u.cabinet AS cabinet, r.brand AS brand, u.month AS month, u.grp AS grp, u.art AS art,
           u.amount * r.share AS amount
    FROM un AS u INNER JOIN recv AS r ON r.cabinet = u.cabinet AND r.month = u.month
)
SELECT cabinet AS cabinet, brand AS brand, month AS month, blk AS blk, grp AS grp, art AS art, toFloat64(amount) AS amount
FROM (
    SELECT cabinet, brand, month, {q(BLK_ACCR)} AS blk, grp, art, sum(amount) AS amount
    FROM accr GROUP BY cabinet, brand, month, grp, art HAVING abs(amount) > 0
    UNION ALL
    SELECT cabinet, brand, formatDateTime(month, '%Y-%m') AS month, t.1 AS blk, t.2 AS grp, t.3 AS art, t.4 AS amount
    FROM ozon_metrics_by_cabinet_brand_month
    ARRAY JOIN [({q(BLK_QTY)}, '01 Продано за вычетом возвратов', 'Продано, шт.', toFloat64(sales_qty)),
                ({q(BLK_COGS)}, '01 Себестоимость проданного', 'Себестоимость', toFloat64(cogs)),
                ({q(BLK_GP)}, '01 Валовая прибыль', 'Валовая прибыль', toFloat64(gross_profit)),
                ({q(BLK_COV)}, '01 Покрытие справочником себестоимости', 'С себестоимостью, шт.', toFloat64(cogs_qty_covered)),
                ({q(BLK_COV)}, '01 Покрытие справочником себестоимости', 'Без себестоимости, шт.', toFloat64(cogs_qty_uncovered))] AS t
);

ALTER TABLE detail_adapter_ozon COMMENT COLUMN art 'Статья = тип начисления отчёта Ozon (.xlsx «Начисления»); группа = группа услуг отчёта. Начисления без артикула разложены по брендам пропорционально выручке (оценка).';
"""


# Русские названия статей cash-flow-statement (item_name). Переведено по смыслу
# английских кодов, как и в самой cash-flow-вьюхе; код без названия показывается как есть.
CASHFLOW_LABELS = {
    "MarketplaceServiceItemDirectFlowLogisticSum": "Логистика (прямой поток)",
    "MarketplaceServiceItemRedistributionLastMileCourier": "Последняя миля, курьер",
    "MarketplaceServiceItemDeliveryToHandoverPlaceOzon": "Доставка до места выдачи силами Ozon",
    "MarketplaceServiceItemRedistributionLastMilePVZ": "Последняя миля, ПВЗ",
    "MarketplaceServiceItemRedistributionDropoff": "Drop-off, перераспределение",
    "MarketplaceServiceItemDropoff": "Обработка отправления Drop-off",
    "MarketplaceServiceItemReturnFlowLogistic": "Обратная логистика",
    "MarketplaceServiceItemRedistributionReturnsPVZ": "Возвраты, обработка в ПВЗ",
    "MarketplaceServiseItemPointsAwarded": "Баллы за скидки (начислено)",
    "MarketplaceServiceCostPerClick": "Оплата за клик",
    "MarketplaceServicePromotionWithCostPerOrder": "Продвижение с оплатой за заказ",
    "MarketplaceServiseItemAgencyFeeForSale": "Агентское вознаграждение за продажу",
    "MarketplaceRedistributionOfAcquiringItem": "Эквайринг",
    "MarketplaceServiceItemFlexiblePaymentSchedule": "Гибкий график выплат",
    "MarketplaceServiceBrandCommission": "Продвижение бренда",
    "MarketplaceServiceStorageItem": "Размещение на складе",
    "MarketplaceElectronicServiceItemTransferringCards": "Перенос карточек товаров (электронная услуга)",
    "MarketplaceServiceItemCrossdocking": "Кросс-докинг",
    "MarketplaceServiceItemSubscriptionPremiumPlus": "Подписка Premium Plus",
    "InsuranceServiceSellerItem": "Страхование продавца",
    "MarketplaceServiceItemElectronicServicePinReview": "Закрепление отзыва",
    "MarketplaceServiceEarlyPayment": "Досрочная выплата",
    "MarketplaceServiceRedistributionOfDeliveryServicesRFBS": "Перераспределение услуг доставки realFBS",
    "FinesErrorIndexExceeded": "Штраф: превышение индекса ошибок",
    "MarketplaceServiceSellerReturnsCargoAssortment": "Возврат грузов продавцу (ассортимент)",
    "MarketplaceServiceProductMovementFromWarehouse": "Вывоз товара со склада",
    "MarketplaceServiceItemSupplyInboundAdditional": "Дополнительные услуги приёмки поставки",
    "MarketplaceElectronicServicePointforReviews": "Баллы за отзывы",
    "MarketplaceServiceBadgeOriginal": "Бейдж «Оригинал»",
    "MarketplaceServiceItemElectronicServicesPremiumCashbackIndividualPoints": "Premium: индивидуальный кешбэк баллами",
    "MarketplaceServiceItemInternetSiteAdvertising": "Реклама в сети Интернет на сайте",
    "MarketplaceSellerCorrectionOperation": "Корректировка продавца",
    "MarketplaceServiceBadgeBrandVerified": "Бейдж «Проверенный бренд»",
    "MarketplaceServiceItemTransferringCards": "Перенос карточек товаров",
    "MarketplaceServiceItemPremiumProMembership": "Подписка Premium Pro",
    "MarketplaceServiceItemPackageMaterialsProvision": "Обеспечение материалами для упаковки",
    "MarketplaceElectronicServiceAcceleratedProductReviews": "Ускоренный сбор отзывов",
    "MarketplaceServiceItemSupplyInboundCargoShortage": "Недостача грузомест при приёмке",
    "MarketplaceServiceItemDefectRateDetailed": "Брак (детализация)",
    "MarketplaceServiceItemSubscriptionPremiumPro": "Подписка Premium Pro (процент)",
    "MarketplaceServiceItemTemporaryStorageRedistribution": "Временное размещение товара",
    "MarketplaceServiceItemServiceFeeRFBS": "Сервисный сбор realFBS",
    "MarketplaceProductDisposal": "Утилизация товара",
    "MarketplaceServiceItemSupplyInboundExpirationDateProcessing": "Обработка срока годности",
    "MarketplaceServiceItemSupplyInboundCargoSurplus": "Излишки грузомест при приёмке",
    "MarketplaceServiceItemSupplyInboundSupplyShortage": "Недостача поставки при приёмке",
    "MarketplaceAgencyFeeAggregator3plRFBS": "Агентское вознаграждение агрегатора realFBS",
    "MarketplaceServiceProcessingNotIdentifiedSurplus": "Обработка неопознанных излишков",
    "MarketplaceServiceProcessingSpoilage": "Обработка брака",
    "FinesProhibitedProducts": "Штраф: запрещённый товар",
    "FinesProhibitedContent": "Штраф: запрещённый контент",
    "MarketplaceServiceItemPackageRedistribution": "Упаковка товара (перераспределение)",
    "MarketplaceServiceVolumeWeightCharacsProcessing": "Обработка объёмно-весовых характеристик",
    "MarketplaceServiceItemAdditionalPackagingAtWarehouse": "Дополнительная упаковка на складе",
    "MarketplaceServiceItemDisposalDetailed": "Утилизация (детализация)",
    "MarketplaceServiceItemSupplyInboundSupplySurplus": "Излишки поставки при приёмке",
    "AccrualWithoutDocs": "Начисления без документов",
    "AccrualInternalClaim": "Внутренние претензии",
    "AccrualConsigDefectiveWriteOff": "Списание брака (консигнация)",
    "MarketplaceRedistributionOfAcquiringOperation": "Эквайринг (операция)",
    "MarketplaceSellerDecompensationItemByTypeDocOperation": "Декомпенсации по типам документов",
    "MarketplaceSellerReexposureDeliveryReturnOperation": "Повторное выставление доставки/возврата",
    "OperationMarketplaceServicePartialCompensationToClient": "Частичные компенсации покупателям",
    "OperationSetOffBalance": "Взаимозачёт по балансу",
    "MarketplaceCorrectionPointOperation": "Корректировка баллов",
    "AccrualConsigWriteOff": "Списание (консигнация)",
    # есть в классификации канонической вьюхи, в данных пока не встречались
    "MarketplaceServiceItemDirectFlowLogistic": "Логистика (прямой поток, детально)",
    "MarketplaceServiceItemReturnAfterDelivToCustomer": "Возврат после доставки покупателю",
    "MarketplaceServiceItemReturnNotDelivToCustomer": "Возврат недоставленного покупателю",
}

CASHFLOW_GROUPS = [
    ("logistics", "02 Логистика"),
    ("last_mile", "03 Последняя миля и партнёрские услуги"),
    ("fines", "04 Штрафы и прочие услуги"),
    ("surcharges", "05 Доплаты и компенсации"),
    ("storage", "06 Хранение и услуги FBO"),
    ("promotion", "07 Продвижение и реклама"),
    ("other", "08 Прочие начисления"),
]


def cashflow_items_view() -> str:
    """Статьи cash-flow с категорией — из КАНОНИЧЕСКИХ CTE (дубли и классификация не копируются)."""
    text = CANON_CASHFLOW.read_text(encoding="utf-8")
    start = text.find("WITH duplicated_items AS (")
    end = text.find(",\nperiods_agg AS (")
    if start < 0 or end < 0:
        raise SystemExit("в каноническом cash-flow-файле не найдены CTE — генератор устарел")
    ctes = text[start:end]
    old = "        toStartOfMonth(period_begin) AS month,\n        multiIf("
    if ctes.count(old) != 1:
        raise SystemExit("items_classified изменился — генератор устарел")
    ctes = ctes.replace(old, "        toStartOfMonth(period_begin) AS month,\n        item_name AS item_name,\n        multiIf(")
    return f"""CREATE VIEW IF NOT EXISTS ozon_cashflow_items_classified AS
{ctes}
SELECT cabinet, month, category, item_name, value FROM items_classified;

ALTER TABLE ozon_cashflow_items_classified COMMENT COLUMN category 'Категория канонической cash-flow-вьюхи: logistics, last_mile, fines, surcharges, storage, promotion, other; excluded — не входит в итог; unmapped — не распознано.';
"""


def ozon_api_view() -> str:
    keys = ", ".join(q(k) for k in CASHFLOW_LABELS)
    vals = ", ".join(q(v) for v in CASHFLOW_LABELS.values())
    label = f"if(has([{keys}], item_name), arrayElement([{vals}], indexOf([{keys}], item_name)), item_name)"
    grp_arms = ", ".join(f"category = {q(c)}, {q(g)}" for c, g in CASHFLOW_GROUPS)
    cats = ", ".join(q(c) for c, _ in CASHFLOW_GROUPS)
    return f"""CREATE VIEW IF NOT EXISTS detail_adapter_ozon_api AS
WITH
cf AS (
    SELECT cabinet, formatDateTime(month, '%Y-%m') AS month, category, item_name, value
    FROM ozon_cashflow_items_classified
),
c AS (
    SELECT cabinet, formatDateTime(month, '%Y-%m') AS month, brand, share, payable_for_goods, payable_total
    FROM ozon_metrics_by_cabinet_brand_month_cashflow_api
),
r AS (
    SELECT cabinet, formatDateTime(month, '%Y-%m') AS month, brand, sales_qty, sales_amount, spp_amount, commission,
           returns_corrections, cogs, cogs_qty_covered, cogs_qty_uncovered
    FROM ozon_realization_by_cabinet_brand_month
)
SELECT cabinet AS cabinet, brand AS brand, month AS month, blk AS blk, grp AS grp, art AS art, toFloat64(amount) AS amount
FROM (
    -- «К перечислению за товар» по бренду — ТОЧНО из реализации (совпадает с cash-flow до рубля)
    SELECT cabinet, brand, month, {q(BLK_ACCR)} AS blk, '01 К перечислению за товар' AS grp,
           'К перечислению за товар' AS art, payable_for_goods AS amount
    FROM c
    UNION ALL
    -- расходы кабинета по статьям cash-flow — по доле выручки бренда (оценка)
    SELECT c.cabinet AS cabinet, c.brand AS brand, c.month AS month, {q(BLK_ACCR)} AS blk,
           multiIf({grp_arms}, '99 Прочее') AS grp, {label} AS art, cf.value * c.share AS amount
    FROM cf INNER JOIN c ON c.cabinet = cf.cabinet AND c.month = cf.month
    WHERE cf.category IN ({cats})
    UNION ALL
    -- статьи, исключённые из итога канонической вьюхи (двойной счёт / realFBS) и нераспознанные — справочно
    SELECT c.cabinet AS cabinet, c.brand AS brand, c.month AS month, {q(BLK_EXCL)} AS blk,
           if(cf.category = 'excluded', '01 Исключено из итога (двойной счёт, realFBS)', '02 Не распознано каталогом') AS grp,
           {label} AS art, cf.value * c.share AS amount
    FROM cf INNER JOIN c ON c.cabinet = cf.cabinet AND c.month = cf.month
    WHERE cf.category IN ('excluded', 'unmapped')
    UNION ALL
    SELECT cabinet, brand, month, {q(BLK_REV)} AS blk, '01 По отчёту о реализации' AS grp, t.1 AS art, t.2 AS amount
    FROM r
    ARRAY JOIN [('Выручка', toFloat64(sales_amount)), ('СПП', toFloat64(spp_amount)),
                ('Комиссия', toFloat64(commission)),
                ('Корректировки, брак, потери и возвраты', toFloat64(returns_corrections))] AS t
    UNION ALL
    SELECT cabinet, brand, month, {q(BLK_QTY)} AS blk, '01 Продано за вычетом возвратов' AS grp,
           'Продано, шт.' AS art, toFloat64(sales_qty) AS amount
    FROM r
    UNION ALL
    SELECT cabinet, brand, month, {q(BLK_COGS)} AS blk, '01 Себестоимость проданного' AS grp,
           'Себестоимость' AS art, toFloat64(cogs) AS amount
    FROM r
    UNION ALL
    -- валовая прибыль как в адаптере: итог к перечислению бренда + себестоимость
    SELECT c.cabinet AS cabinet, c.brand AS brand, c.month AS month, {q(BLK_GP)} AS blk, '01 Валовая прибыль' AS grp,
           'Валовая прибыль' AS art, c.payable_total + r.cogs AS amount
    FROM c INNER JOIN r ON r.cabinet = c.cabinet AND r.month = c.month AND r.brand = c.brand
    UNION ALL
    SELECT cabinet, brand, month, {q(BLK_COV)} AS blk, '01 Покрытие справочником себестоимости' AS grp,
           t.1 AS art, t.2 AS amount
    FROM r
    ARRAY JOIN [('С себестоимостью, шт.', toFloat64(cogs_qty_covered)),
                ('Без себестоимости, шт.', toFloat64(cogs_qty_uncovered))] AS t
);

ALTER TABLE detail_adapter_ozon_api COMMENT COLUMN art 'Статья cash-flow-statement Ozon с русским названием (переведено по смыслу кода). Расходы кабинета разложены по брендам пропорционально выручке бренда (оценка); «К перечислению за товар» — точно из реализации.';
"""


HEADER = f"""-- СГЕНЕРИРОВАННЫЙ ФАЙЛ. Не правьте руками.
--
-- Генератор: scripts/gen_detail_adapter_views.py (принципы — в его шапке).
--
-- «Детальный адаптер»: все статьи отчётов WB и Ozon в длинном формате
-- (кабинет, бренд, месяц, блок, группа, статья, сумма). Блок «1 Начисления» аддитивен:
-- его сумма = «К перечислению итого» (payable_total) канонических вьюх, остальные блоки
-- справочные и с ним не складываются. Расходы Ozon уровня кабинета разложены по брендам
-- пропорционально выручке (оценка), всё привязанное к артикулу — точно.
--
-- Порядок накатки: после schema_wb_metrics_views_brand.sql и schema_ozon_metrics_views_brand.sql
-- (читают бренд-вьюхи). Применять под пользователем с правом DDL (default). Вьюхи новые.
--
-- ПРОВЕРКА НА ДАННЫХ (инварианты, гонять после любой правки):
--   * WB: по каждому (кабинет, бренд, месяц) сумма листьев группы = каноническая метрика
--     бренд-вьюхи: 01+02 = payable_for_goods; 03 = logistics_direct + logistics_reverse; 04 = fines;
--     05 = commission_correction; 06 = storage_cost; 07 = acceptance_cost; 08 = deductions;
--     09 = promotion_cost; 10 = wibes_discount; весь блок «1» = payable_total.
--   * Ozon xlsx: блок «1» = payable_total бренд-вьюхи ozon_metrics_by_cabinet_brand_month.
--   * Ozon API: блок «1» = payable_total ozon_metrics_by_cabinet_brand_month_cashflow_api.
"""


def build() -> str:
    return "".join([
        HEADER,
        "\n-- ==== Ozon cash-flow: статьи с категорией (из канонических CTE) ====\n", cashflow_items_view(),
        "\n-- ==== WB, из .xlsx ====\n", wb_view(api=False),
        "\n-- ==== WB, из API ====\n", wb_view(api=True),
        "\n-- ==== Ozon, из .xlsx ====\n", ozon_xlsx_view(),
        "\n-- ==== Ozon, из API ====\n", ozon_api_view(),
    ])


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--check", action="store_true",
                   help="не писать файл, а проверить что он совпадает с генерируемым")
    args = p.parse_args()
    generated = build()
    if args.check:
        if not OUT.exists():
            print(f"НЕТ ФАЙЛА {OUT.relative_to(REPO)} — прогоните генератор", file=sys.stderr)
            sys.exit(1)
        if OUT.read_text(encoding="utf-8") != generated:
            print(f"{OUT.relative_to(REPO)} отстал — прогоните scripts/gen_detail_adapter_views.py", file=sys.stderr)
            sys.exit(1)
        print("ок: сгенерированный файл совпадает с генератором")
        return
    OUT.write_text(generated, encoding="utf-8")
    print(f"записано: {OUT.relative_to(REPO)} ({len(generated)} символов)")


if __name__ == "__main__":
    main()
