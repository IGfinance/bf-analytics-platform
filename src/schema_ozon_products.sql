-- Справочник товаров Ozon из каталога Seller API: кабинет × товар → бренд.
-- Источник: POST /v3/product/list (список товаров: product_id, offer_id, sku)
-- + POST /v4/product/info/attributes (атрибуты; бренд — атрибут id 85 «Бренд»).
--
-- ЗАЧЕМ. В отчётах Ozon (xlsx «Начисления» и /v2/finance/realization) бренда
-- нет — только артикул (offer_id/article), SKU и название. Чтобы разбить
-- кабинет по брендам (в одном кабинете бывает несколько, напр. MaxJansen в
-- кабинете CloudSix), бренд берётся отсюда по offer_id / sku.
--
-- ЧЕСТНЫЕ ПРОПУСКИ. Товар, которого нет в каталоге (удалён), или без бренда
-- в карточке остаётся без бренда; дозаполнять догадками нельзя (решение
-- владельца 2026-10-04 по WB, тот же принцип). Покрытие считается отдельно.
--
-- Значение бренда хранится как пришло от Ozon (в т.ч. «Нет бренда» —
-- справочное значение Ozon, а не пусто). Пустая строка — атрибута нет.
--
-- ReplacingMergeTree(loaded_at): повторный прогон перезаписывает строки
-- (кабинет, product_id) свежими значениями. Читать с FINAL.

CREATE TABLE IF NOT EXISTS ozon_products
(
    cabinet     String,
    product_id  Int64,
    offer_id    String,                 -- артикул продавца (= offer_id в ozon_realization)
    sku         Int64,                  -- SKU Ozon (= sku в ozon_realization/ozon_reports)
    name        String,
    brand       String,                 -- атрибут 85; '' если у карточки нет бренда
    archived    UInt8,
    loaded_at   DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (cabinet, product_id);
