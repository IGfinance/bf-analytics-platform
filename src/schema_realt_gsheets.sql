-- Данные Google-Таблиц Реальта (зарплаты/ФОТ, расходы по статьям).
-- Обе таблицы держим отдельно, т.к. это разные по смыслу сущности (ФОТ vs
-- расходы по статьям), а не варианты одного отчёта.
--
-- realt_payroll — вкладка «Импорт ФОТ» (детализация начислений по сотрудникам
-- помесячно), тянется через Google Sheets API (см. realt_gsheets_core.py).
-- Берутся только строки-данные (Роль начинается с «ФОТ»); строки-заголовки
-- секций и итоги отсекаются. Числа в таблице в русском формате (неразрывный
-- пробел + запятая), парсер нормализует их в Float64. Нераспознанные столбцы
-- (часы/KPI/приёмы и т.п.) уходят в extra_columns.
CREATE TABLE IF NOT EXISTS realt_payroll
(
    project_id          UInt32,
    period              Nullable(Date)      COMMENT 'Месяц начисления (из колонки «Месяц»)',
    employee_id         String              COMMENT 'ID сотрудника (код из выгрузки)',
    department          Nullable(String)    COMMENT 'Проект/подразделение (этаж), НЕ project_id платформы',
    role                Nullable(String)    COMMENT 'Роль ФОТ (Психиатры/Психологи/Администраторы/Управление/Маркетинг/Шмилович)',
    category            Nullable(String)    COMMENT 'Категория сотрудника (Опытный и т.п.)',
    pay_type            Nullable(String)    COMMENT 'Тип оплаты (Оклад/Процент/...)',
    salary              Nullable(Float64)   COMMENT 'Оклад',
    accrued_total       Nullable(Float64)   COMMENT 'Начислено ИТОГО',
    to_pay              Nullable(Float64)   COMMENT 'К оплате',
    ndfl                Nullable(Float64)   COMMENT 'Вычет НДФЛ (обычно отрицательный)',
    contributions       Nullable(Float64)   COMMENT 'Страховые взносы (обычно отрицательные)',
    revenue             Nullable(Float64)   COMMENT 'Выручка, приписанная сотруднику',
    fot_revenue_share   Nullable(Float64)   COMMENT 'Доля ФОТ/Выручка, %',
    comment             Nullable(String)    COMMENT 'Комментарий',
    extra_columns       Map(String, String) COMMENT 'Нераспознанные столбцы (часы/KPI/приёмы и пр.)',
    row_num             UInt32              COMMENT 'Позиция строки во вкладке, для дедупа при перезаливке',
    source_file         String,
    loaded_at           DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(period, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);

-- realt_expenses — вкладка «Остальные расходы» (матрица: столбец = статья с
-- двумя шапками «Статья»/«Дата/Тип», строка = месяц). parse_expenses в
-- realt_gsheets_core.py разворачивает её в длинные записи (месяц × статья).
-- Суммы отрицательные (расход), рус. формат нормализуется в Float64. Набор
-- статей 2025 ≠ 2026 — в семантическом слое группируем по expense_type.
CREATE TABLE IF NOT EXISTS realt_expenses
(
    project_id     UInt32,
    period         Nullable(Date)      COMMENT 'Месяц расхода (1-е число, из метки вкладки «янв.-25»)',
    article        String              COMMENT 'Статья расхода — имя столбца (напр. «Аренда - 2 этаж»)',
    expense_type   Nullable(String)    COMMENT 'Группа/тип статьи (строка «Дата/Тип»): Аренда+коммуналка/Налоги ФОТ/Санпэдрежим/…',
    amount         Nullable(Float64)   COMMENT 'Сумма за месяц, обычно отрицательная (расход)',
    is_shaa        UInt8               COMMENT 'Статья Шмиловича (ШАА): 1/0, для тумблера «с/без Шмиловича»',
    row_num        UInt32              COMMENT 'Позиция строки-месяца во вкладке',
    col_num        UInt32              COMMENT 'Индекс столбца-статьи; (row_num,col_num) — ключ дедупа ячейки',
    source_file    String,
    loaded_at      DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(period, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num, col_num);
