-- Metabase: "Список - Bottling - Компании" (id 207), коллекция
-- "Bottling | Админка" (15). Служебная карточка.
--
-- 2026-09-30: БОЛЬШЕ НЕ подключена как values_source к дашбордному
-- фильтру "Компания" — фильтр переведён на взаимный каскад с "Продукт"
-- (chain-filter по реальному field_id), а каскад несовместим с
-- values_source_type: "card" (см. bottling_revenue_pivot.sql и
-- вики-гочтю "Metabase каскадные фильтры требуют реальный field_id,
-- values_source card их ломает"). Карточка не удалена — оставлена на
-- случай, если каскад понадобится снова отключить.

SELECT DISTINCT counterparty AS "Компания"
FROM realization_revenue
ORDER BY counterparty
