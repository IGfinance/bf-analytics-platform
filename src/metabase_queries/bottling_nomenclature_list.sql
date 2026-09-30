-- Metabase: "Список - Bottling - Номенклатура" (id 208), коллекция
-- "Bottling | Админка" (15). Служебная карточка.
--
-- 2026-09-30: БОЛЬШЕ НЕ подключена как values_source к дашбордному
-- фильтру "Продукт" — фильтр переведён на взаимный каскад с "Компания"
-- (chain-filter по реальному field_id), а каскад несовместим с
-- values_source_type: "card" (см. bottling_revenue_pivot.sql и
-- вики-гочтю "Metabase каскадные фильтры требуют реальный field_id,
-- values_source card их ломает"). Карточка не удалена — оставлена на
-- случай, если каскад понадобится снова отключить.

SELECT DISTINCT nomenclature AS "Номенклатура"
FROM realization_revenue
ORDER BY nomenclature
