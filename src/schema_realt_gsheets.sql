-- Данные Google-Таблиц Реальта (зарплаты/ФОТ, расходы по статьям).
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

-- realt_bank_account / realt_cash / realt_accruals — вкладки «Расчетный счет»,
-- «Наличные», «Начисления» (выгрузка из учётной системы клиента, регистры
-- движений денег и начислений по счетам/кассе). В отличие от realt_expenses
-- это УЖЕ плоские регистры (строка = операция), не матрицы — parse_bank_account
-- / parse_cash / parse_accruals в realt_gsheets_core.py читают их позиционно.
-- «Проект» здесь — этаж/направление внутри Реальта (3 этаж/АПДШ/…), НЕ путать
-- с project_id платформы. «Мес» (month_seq) — сырой порядковый номер месяца
-- из вкладки, не переинтерпретируется. «Начисления» — регистр по методу
-- начисления (без «Проект»/«Мес», в отличие от двух других).
CREATE TABLE IF NOT EXISTS realt_bank_account
(
    project_id             UInt32,
    account_label          Nullable(String)  COMMENT 'Номера счетов (метка счёта, напр. «ИП Шмилович - Мед - 4437»)',
    account_number         Nullable(String)  COMMENT 'Счет — номер расчётного счёта',
    operation_date         Nullable(Date)    COMMENT 'Дата операции (из колонки «Дата», формат ДД/ММ/ГГ)',
    amount                 Nullable(Float64) COMMENT 'Сумма (в источнике без знака)',
    amount_signed          Nullable(Float64) COMMENT 'Со знаком — та же сумма со знаком (+/-)',
    counterparty           Nullable(String)  COMMENT 'Контрагент',
    counterparty_inn       Nullable(String)  COMMENT 'ИНН контрагента',
    counterparty_account   Nullable(String)  COMMENT 'Р/с контрагента',
    purpose                Nullable(String)  COMMENT 'Назначение по документу',
    cf_subarticle          Nullable(String)  COMMENT 'Подстатья ДДС',
    project                Nullable(String)  COMMENT 'Проект — этаж/направление внутри Реальта (не platform project_id)',
    tag                    Nullable(String)  COMMENT 'Тег',
    pl_article             Nullable(String)  COMMENT 'Статья PL',
    accrual_date           Nullable(Date)    COMMENT 'Дата начисления (метод начисления, напр. «5 янв. 26»)',
    accrual_amount         Nullable(Float64) COMMENT 'Сумма начисления',
    cf_article             Nullable(String)  COMMENT 'Статья ДДС',
    month_seq              Nullable(Int32)   COMMENT 'Мес — сырой номер месяца из вкладки, без переинтерпретации',
    comment                Nullable(String)  COMMENT 'Комментарий',
    company_form           Nullable(String)  COMMENT 'Форма компании (ИП/ООО)',
    row_num                UInt32            COMMENT 'Позиция строки во вкладке, для дедупа при перезаливке',
    source_file            String,
    loaded_at              DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(accrual_date, operation_date, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);

CREATE TABLE IF NOT EXISTS realt_cash
(
    project_id      UInt32,
    operation_date  Nullable(Date)    COMMENT 'Дата операции',
    account_name    Nullable(String)  COMMENT 'Название счета (напр. «Таджикская карта», «Сейф Чай»)',
    amount          Nullable(Float64) COMMENT 'Сумма (со знаком)',
    purpose         Nullable(String)  COMMENT 'Назначение платежа',
    cf_subarticle   Nullable(String)  COMMENT 'Подстатья ДДС',
    project         Nullable(String)  COMMENT 'Проект — этаж/направление внутри Реальта',
    tag             Nullable(String)  COMMENT 'Тег',
    pl_article      Nullable(String)  COMMENT 'Статья PL',
    accrual_date    Nullable(Date)    COMMENT 'Дата начисления',
    accrual_amount  Nullable(Float64) COMMENT 'Сумма начисления',
    cf_article      Nullable(String)  COMMENT 'Статья ДДС',
    month_seq       Nullable(Int32)   COMMENT 'Мес — сырой номер месяца из вкладки',
    company_form    Nullable(String)  COMMENT 'Форма компании (ИП/ООО)',
    row_num         UInt32            COMMENT 'Позиция строки во вкладке, для дедупа при перезаливке',
    source_file     String,
    loaded_at       DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(accrual_date, operation_date, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);

-- realt_service_categories — вкладка «Категорирование услуг»: справочник
-- услуга → категории (без дублей по названию услуги). Ключ для джойна —
-- service, совпадает с klientiks_operations.service. qualification —
-- квалификация врача (джун/мидл/синьор/топ/неизв) — то, чего не хватало для
-- среза «Уровень врача» в помесячной юнитке.
CREATE TABLE IF NOT EXISTS realt_service_categories
(
    project_id    UInt32,
    service       String            COMMENT 'Название услуги (изначальное) — ключ, совпадает с klientiks_operations.service',
    doctor_type   Nullable(String)  COMMENT 'Тип врача (Психиатр/Психолог/Психотерапевт/Невролог/Другое)',
    duration      Nullable(String)  COMMENT 'Продолжительность приёма (напр. «50 мин»)',
    service_kind  Nullable(String)  COMMENT 'Тип услуги (Разовый/Повторный)',
    format        Nullable(String)  COMMENT 'Формат (Оффлайн/Онлайн/Выезд)',
    periodicity   Nullable(String)  COMMENT 'Периодичность (Первичный/Вторичный)',
    qualification Nullable(String)  COMMENT 'Квалификация врача (джун/мидл/синьор/топ/неизв)',
    row_num       UInt32            COMMENT 'Позиция строки во вкладке, для дедупа при перезаливке',
    source_file   String,
    loaded_at     DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (project_id, source_file, row_num);

-- realt_employees — вкладка «Справочник сотрудников»: employee_id (сокращённый
-- код, как в realt_payroll.employee_id, напр. «АрсТБ_ТД») → ФИО. Без дублей,
-- 84 строки. Связывает ФОТ (по коду сотрудника) с визитами klientiks_operations
-- (по полю doctor — полное ФИО).
CREATE TABLE IF NOT EXISTS realt_employees
(
    project_id  UInt32,
    employee_id String            COMMENT 'ID сотрудника (сокращённый код, ключ — совпадает с realt_payroll.employee_id)',
    full_name   Nullable(String)  COMMENT 'ФИО сотрудника',
    row_num     UInt32            COMMENT 'Позиция строки во вкладке, для дедупа при перезаливке',
    source_file String,
    loaded_at   DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (project_id, source_file, row_num);

CREATE TABLE IF NOT EXISTS realt_accruals
(
    project_id      UInt32,
    account_name    Nullable(String)  COMMENT 'Название счета',
    operation_date  Nullable(Date)    COMMENT 'Дата операции',
    amount          Nullable(Float64) COMMENT 'Сумма',
    purpose         Nullable(String)  COMMENT 'Назначение платежа',
    comment         Nullable(String)  COMMENT 'Комментарий',
    cf_subarticle   Nullable(String)  COMMENT 'Подстатья ДДС',
    tag             Nullable(String)  COMMENT 'Тег',
    pl_article      Nullable(String)  COMMENT 'Статья PL',
    accrual_date    Nullable(Date)    COMMENT 'Дата начисления',
    accrual_amount  Nullable(Float64) COMMENT 'Сумма начисления',
    cf_article      Nullable(String)  COMMENT 'Статья ДДС',
    row_num         UInt32            COMMENT 'Позиция строки во вкладке, для дедупа при перезаливке',
    source_file     String,
    loaded_at       DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(accrual_date, operation_date, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);
