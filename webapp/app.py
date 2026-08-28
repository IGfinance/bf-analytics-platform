#!/usr/bin/env python3
"""
Веб-форма для ручной загрузки отчётов WB в ClickHouse.

Маршруты:
  GET  /          — форма загрузки детального отчёта
  POST /upload    — обработка детального отчёта
  GET  /summary   — форма загрузки сводного отчёта
  POST /upload-summary — обработка сводного отчёта + сверка
  GET  /dashboard — обзор кабинетов

Логин/пароль берутся из .env (WEBAPP_USER / WEBAPP_PASSWORD).
"""

import ntpath
import os
import posixpath
import sys
from functools import wraps
from pathlib import Path

from dotenv import load_dotenv
from flask import Flask, Response, render_template, render_template_string, request

WEBAPP_DIR = Path(__file__).parent
CLICKHOUSE_DIR = WEBAPP_DIR.parent
sys.path.insert(0, str(CLICKHOUSE_DIR))

load_dotenv(CLICKHOUSE_DIR / ".env")   # реквизиты ClickHouse
load_dotenv(WEBAPP_DIR / ".env")       # логин/пароль формы (может переопределить)

from wb_core import ingest_files, get_client          # noqa: E402
from wb_summary_core import ingest_files as ingest_summary  # noqa: E402
from reconcile_wb import run_reconciliation            # noqa: E402

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 100 * 1024 * 1024  # 100 МБ на запрос


class PrefixMiddleware:
    """Подставляет внешний префикс пути (например, /cloudsix из nginx
    location) в SCRIPT_NAME, чтобы url_for генерировал абсолютные ссылки
    (/static/..., /dashboard и т.п.), рабочие из-под этого префикса.

    Нужен, потому что nginx проксирует `location /cloudsix/` на бэкенд
    БЕЗ префикса (proxy_pass с trailing slash), а Flask ничего не знает
    о внешнем пути, если явно не сказать через SCRIPT_NAME/URL_PREFIX.
    """

    def __init__(self, wsgi_app, prefix=""):
        self.wsgi_app = wsgi_app
        self.prefix = prefix.rstrip("/")

    def __call__(self, environ, start_response):
        if self.prefix:
            environ["SCRIPT_NAME"] = self.prefix
        return self.wsgi_app(environ, start_response)


URL_PREFIX = os.environ.get("URL_PREFIX", "")
if URL_PREFIX:
    app.wsgi_app = PrefixMiddleware(app.wsgi_app, prefix=URL_PREFIX)

UPLOAD_DIR = WEBAPP_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)

# Единый источник навигации оболочки — endpoint=None рендерится как
# отключённый пункт (фича ещё не реализована), а не мёртвая ссылка.
NAV_ITEMS = [
    {"label": "Дашборд", "endpoint": "dashboard", "icon": "layout-dashboard"},
    {"label": "Детальный отчёт", "endpoint": "index", "icon": "upload"},
    {"label": "Сводный отчёт + сверка", "endpoint": "summary_form", "icon": "git-compare"},
    {"label": "Алерты", "endpoint": None, "icon": "bell"},
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def safe_filename(filename: str) -> str:
    """Убирает путь и null-байты, сохраняет юникод (в т.ч. '№')."""
    filename = filename.replace("\x00", "")
    filename = ntpath.basename(filename)
    filename = posixpath.basename(filename)
    return filename


def get_cabinets() -> list[str]:
    """Возвращает список уникальных кабинетов из wb_reports. При ошибке — []."""
    try:
        client = get_client()
        rows = client.query(
            "SELECT DISTINCT cabinet FROM wb_reports FINAL ORDER BY cabinet"
        ).result_rows
        return [r[0] for r in rows if r[0]]
    except Exception:
        return []


def check_auth(username, password):
    expected_user = os.environ.get("WEBAPP_USER", "admin")
    expected_password = os.environ.get("WEBAPP_PASSWORD")
    if not expected_password:
        raise RuntimeError("WEBAPP_PASSWORD не задан в .env")
    return username == expected_user and password == expected_password


def requires_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.authorization
        if not auth or not check_auth(auth.username, auth.password):
            return Response(
                "Требуется авторизация", 401,
                {"WWW-Authenticate": 'Basic realm="Finance Black reports upload"'},
            )
        return f(*args, **kwargs)
    return decorated


@app.context_processor
def inject_shell_context():
    """Общие данные оболочки (header + sidebar) для всех шаблонов.

    current_project/unread_alerts — заглушки до миграций
    projects/project_cabinets/alerts (см. текущие приоритеты в вики).
    """
    return {
        "nav_items": NAV_ITEMS,
        "current_project": None,
        "unread_alerts": 0,
    }


# ---------------------------------------------------------------------------
# Routes — дашборд
# ---------------------------------------------------------------------------

_BASE_STYLE = """
<style>
  body { font-family: -apple-system, sans-serif; max-width: 680px; margin: 40px auto; padding: 0 16px; }
  nav { margin-bottom: 24px; }
  nav a { margin-right: 16px; color: #0066cc; }
  label { display: block; margin-top: 16px; font-weight: 600; }
  input[type=text] { width: 100%; padding: 8px; margin-top: 4px; box-sizing: border-box; }
  input[type=submit] { margin-top: 24px; padding: 10px 24px; cursor: pointer; }
  .error { color: #c00; margin-top: 16px; }
  .ok    { color: #080; }
  .warn  { color: #a60; }
  .hint  { color: #666; font-size: 0.9em; }
  pre    { background: #f5f5f5; padding: 12px; overflow-x: auto; white-space: pre-wrap; }
  table  { border-collapse: collapse; width: 100%; margin-top: 16px; font-size: 0.9em; }
  th, td { border: 1px solid #ddd; padding: 6px 10px; text-align: left; }
  th     { background: #f0f0f0; }
  tr.fail     { background: #fff0f0; }
  tr.warn-row { background: #fffbe6; }
  .status-table td { border: none; padding: 6px 12px 6px 0; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 0.85em; font-weight: 600; }
  .badge-ok      { background: #e6f4ea; color: #1a7a34; }
  .badge-fail    { background: #fce8e6; color: #c00; }
  .badge-warn    { background: #fef9e3; color: #7a5c00; }
  .badge-neutral { background: #f0f0f0; color: #555; }
</style>
"""

_NAV = """
<nav>
  <a href="./">Детальный отчёт</a>
  <a href="summary">Сводный отчёт + сверка</a>
</nav>
"""

FORM_HTML = """
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>Загрузка детальных отчётов WB</title>{{ style | safe }}</head>
<body>
  {{ nav | safe }}
  <h1>Загрузка детальных отчётов WB</h1>
  {% if error %}<p class="error">{{ error }}</p>{% endif %}
  <form action="upload" method="post" enctype="multipart/form-data">
    <label for="cabinet">Кабинет</label>
    <input type="text" id="cabinet" name="cabinet" list="cabinets"
           placeholder="Выберите или введите новый..." autocomplete="off" required
           oninput="if(this.value==='+ Добавить новый кабинет'){this.value='';this.placeholder='Введите название нового кабинета';}">
    <datalist id="cabinets">
      <option value="+ Добавить новый кабинет">
      {% for c in cabinets %}<option value="{{ c }}">{% endfor %}
    </datalist>
    <p class="hint">Выберите из списка или введите название нового кабинета вручную.</p>

    <label for="files">Файлы детальных отчётов (.xlsx)</label>
    <input type="file" id="files" name="files" accept=".xlsx" multiple required>

    <input type="submit" value="Загрузить">
  </form>
</body></html>
"""

RESULT_HTML = """
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>Результат загрузки</title>{{ style | safe }}</head>
<body>
  {{ nav | safe }}
  <h1>Результат загрузки</h1>
  {% if error %}
    <p class="error">Ошибка: {{ error }}</p>
  {% else %}
    <p class="ok">Загружено файлов: {{ summary.files }}, строк: {{ summary.rows }}</p>
    {% if summary.unmapped_columns %}
      <p class="warn">Встречены колонки не из column_mapping_wb.yaml:</p>
      <ul>{% for c in summary.unmapped_columns %}<li>{{ c }}</li>{% endfor %}</ul>
      <p class="warn">Данные сохранены в extra_columns. Обновите маппинг при необходимости.</p>
    {% endif %}
  {% endif %}
  {% if logs %}<pre>{{ logs|join('\n') }}</pre>{% endif %}
  <a href="./">← Загрузить ещё</a>
</body></html>
"""

SUMMARY_FORM_HTML = """
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>Сводный отчёт WB + сверка</title>{{ style | safe }}</head>
<body>
  {{ nav | safe }}
  <h1>Загрузка сводного отчёта + сверка</h1>
  <p class="hint">Загрузите «Еженедельный сводный отчёт» (xlsx). Данные сохранятся
  в wb_report_summary, после чего автоматически запустится сверка с wb_reports.</p>
  {% if error %}<p class="error">{{ error }}</p>{% endif %}
  <form action="upload-summary" method="post" enctype="multipart/form-data">
    <label for="cabinet">Кабинет</label>
    <input type="text" id="cabinet" name="cabinet" list="cabinets"
           placeholder="Выберите или введите новый..." autocomplete="off" required
           oninput="if(this.value==='+ Добавить новый кабинет'){this.value='';this.placeholder='Введите название нового кабинета';}">
    <datalist id="cabinets">
      <option value="+ Добавить новый кабинет">
      {% for c in cabinets %}<option value="{{ c }}">{% endfor %}
    </datalist>
    <p class="hint">Выберите из списка или введите название нового кабинета вручную.</p>

    <label for="file">Файл сводного отчёта (.xlsx)</label>
    <input type="file" id="file" name="file" accept=".xlsx" required>

    <input type="submit" value="Загрузить и сверить">
  </form>
</body></html>
"""

SUMMARY_RESULT_HTML = """
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>Результат сверки</title>{{ style | safe }}</head>
<body>
  {{ nav | safe }}
  <h1>Результат загрузки и сверки</h1>
  {% if error %}
    <p class="error">Ошибка: {{ error }}</p>
  {% else %}
    <p class="ok">Загружено строк в wb_report_summary: {{ ingest_rows }}</p>

    <h2>Итоги сверки</h2>
    <table class="status-table">
      <tr>
        <td><span class="badge badge-ok">✓ Совпало</span></td>
        <td><b>{{ counts.ok }}</b> проверок</td>
        <td class="hint">Формула сходится с допуском</td>
      </tr>
      <tr>
        <td><span class="badge badge-fail">✗ Расхождение</span></td>
        <td><b>{{ counts.mismatch }}</b> проверок</td>
        <td class="hint">Данные есть с обеих сторон, но суммы не совпадают — требует внимания</td>
      </tr>
      <tr>
        <td><span class="badge badge-warn">⚠ Нет сырых данных</span></td>
        <td><b>{{ missing_raw_reports|length }}</b> отчётов</td>
        <td class="hint">Сводный отчёт есть, но детальные .xlsx за эти периоды не загружены</td>
      </tr>
      <tr>
        <td><span class="badge badge-neutral">→ Нет в сводном</span></td>
        <td><b>{{ missing_summary_rns|length }}</b> отчётов</td>
        <td class="hint">Детальные данные загружены, но этих отчётов нет в сводном файле</td>
      </tr>
    </table>

    {% if counts.mismatch == 0 and counts.ok > 0 %}
      <p class="ok" style="margin-top:16px">✓ Все загруженные данные сошлись с формулами.</p>
    {% endif %}

    {% if mismatches %}
      <h2>Расхождения — требуют внимания</h2>
      <table>
        <tr><th>№ отчёта</th><th>Тип</th><th>Период</th><th>Поле</th>
            <th>Сводный</th><th>ClickHouse</th><th>Разница</th><th>Допуск</th></tr>
        {% for r in mismatches %}
        <tr class="fail">
          <td>{{ r.report_number }}</td>
          <td>{{ r.report_type or '—' }}</td>
          <td>{{ r.period_start }} — {{ r.period_end }}</td>
          <td>{{ r.field_name }}</td>
          <td>{{ "%.2f"|format(r.expected_value) if r.expected_value is not none else '—' }}</td>
          <td>{{ "%.2f"|format(r.actual_value) if r.actual_value is not none else '—' }}</td>
          <td>{{ "%.2f"|format(r.diff) if r.diff is not none else '—' }}</td>
          <td>{{ r.tolerance }}</td>
        </tr>
        {% endfor %}
      </table>
    {% endif %}

    {% if missing_raw_reports %}
      <h2>Нет сырых данных — {{ missing_raw_reports|length }} отчётов</h2>
      <p class="hint">Сводный отчёт содержит эти периоды, но детальные .xlsx файлы для них не загружены.
      Загрузите детальные отчёты через форму «Детальный отчёт» — пересчитайте сверку повторно.</p>
      <table>
        <tr><th>№ отчёта</th><th>Тип</th><th>Период</th></tr>
        {% for r in missing_raw_reports %}
        <tr class="warn-row">
          <td>{{ r.report_number }}</td>
          <td>{{ r.report_type or '—' }}</td>
          <td>{{ r.period_start }} — {{ r.period_end }}</td>
        </tr>
        {% endfor %}
      </table>
    {% endif %}

    {% if missing_summary_rns %}
      <h2>Нет в сводном — {{ missing_summary_rns|length }} отчётов</h2>
      <p class="hint">Детальные данные по этим отчётам загружены, но в сводном файле их нет.</p>
      <ul>{% for rn in missing_summary_rns %}<li>{{ rn }}</li>{% endfor %}</ul>
    {% endif %}

  {% endif %}
  {% if logs %}<pre>{{ logs|join('\n') }}</pre>{% endif %}
  <a href="summary">← Загрузить ещё</a>
</body></html>
"""


@app.route("/dashboard", methods=["GET"])
@requires_auth
def dashboard():
    return render_template("dashboard.html", cabinets=get_cabinets())


# ---------------------------------------------------------------------------
# Routes — детальный отчёт
# ---------------------------------------------------------------------------

@app.route("/", methods=["GET"])
@requires_auth
def index():
    return render_template("detail_form.html", error=None, cabinets=get_cabinets())


@app.route("/upload", methods=["POST"])
@requires_auth
def upload():
    cabinet = request.form.get("cabinet", "").strip()
    files = request.files.getlist("files")

    if not cabinet:
        return render_template(
            "detail_form.html", error="Укажите кабинет", cabinets=get_cabinets(),
        ), 400
    if not files or all(f.filename == "" for f in files):
        return render_template(
            "detail_form.html", error="Выберите хотя бы один файл", cabinets=get_cabinets(),
        ), 400

    saved_paths, skipped = [], []
    for f in files:
        filename = safe_filename(f.filename)
        if not filename.lower().endswith(".xlsx"):
            skipped.append(f.filename)
            continue
        dest = UPLOAD_DIR / filename
        f.save(dest)
        saved_paths.append(dest)

    if not saved_paths:
        return render_template(
            "detail_form.html", error="Ни одного .xlsx файла не найдено", cabinets=get_cabinets(),
        ), 400

    logs = []
    if skipped:
        logs.append(f"Пропущены не-xlsx файлы: {', '.join(skipped)}")

    try:
        summary = ingest_files(saved_paths, cabinet, log=logs.append)
    except Exception as e:
        return render_template(
            "detail_result.html", error=str(e), summary=None, logs=logs,
        ), 500
    finally:
        for p in saved_paths:
            p.unlink(missing_ok=True)

    return render_template("detail_result.html", error=None, summary=summary, logs=logs)


# ---------------------------------------------------------------------------
# Routes — сводный отчёт + сверка
# ---------------------------------------------------------------------------

@app.route("/summary", methods=["GET"])
@requires_auth
def summary_form():
    return render_template("summary_form.html", error=None, cabinets=get_cabinets())


@app.route("/upload-summary", methods=["POST"])
@requires_auth
def upload_summary():
    cabinet = request.form.get("cabinet", "").strip()
    f = request.files.get("file")

    if not cabinet:
        return render_template(
            "summary_form.html", error="Укажите кабинет", cabinets=get_cabinets(),
        ), 400
    if not f or f.filename == "":
        return render_template(
            "summary_form.html", error="Выберите файл", cabinets=get_cabinets(),
        ), 400

    filename = safe_filename(f.filename)
    if not filename.lower().endswith(".xlsx"):
        return render_template(
            "summary_form.html", error="Файл должен быть .xlsx", cabinets=get_cabinets(),
        ), 400

    dest = UPLOAD_DIR / filename
    f.save(dest)

    logs = []
    try:
        ingest_result = ingest_summary([dest], cabinet, log=logs.append)
        client = get_client()
        reconcile_rows = run_reconciliation(client, cabinet, log=logs.append)
    except Exception as e:
        return render_template_string(
            SUMMARY_RESULT_HTML, style=_BASE_STYLE, nav=_NAV,
            error=str(e), ingest_rows=0,
            counts={"ok": 0, "mismatch": 0, "missing_raw": 0, "missing_summary": 0},
            mismatches=[], missing_raw_reports=[], missing_summary_rns=[],
            logs=logs,
        ), 500
    finally:
        dest.unlink(missing_ok=True)

    # Преобразуем tuple-результат в dict для шаблона
    # ВАЖНО: порядок полей должен точно совпадать с тем, что возвращает run_reconciliation()
    FIELDS = [
        "cabinet", "report_number", "report_type", "period_start", "period_end",
        "field_name", "expected_value", "actual_value", "diff", "tolerance", "is_ok", "status",
    ]
    rows_as_dicts = [dict(zip(FIELDS, r)) for r in reconcile_rows]

    # Подсчёт по статусам (на уровне строк-проверок)
    counts = {"ok": 0, "mismatch": 0, "missing_raw": 0, "missing_summary": 0}
    for r in rows_as_dicts:
        s = r.get("status", "")
        if s in counts:
            counts[s] += 1

    # Реальные расхождения — только mismatch (формула не сходится)
    mismatches = [r for r in rows_as_dicts if r.get("status") == "mismatch"]

    # Отчёты без сырых данных — дедуплицируем по report_number
    seen_rns: set = set()
    missing_raw_reports = []
    for r in rows_as_dicts:
        if r.get("status") == "missing_raw" and r["report_number"] not in seen_rns:
            seen_rns.add(r["report_number"])
            missing_raw_reports.append(r)

    # Отчёты, которых нет в сводном
    missing_summary_rns = sorted({
        r["report_number"] for r in rows_as_dicts if r.get("status") == "missing_summary"
    })

    return render_template(
        "summary_result.html",
        error=None,
        ingest_rows=ingest_result["rows"],
        counts=counts,
        mismatches=mismatches,
        missing_raw_reports=missing_raw_reports,
        missing_summary_rns=missing_summary_rns,
        logs=logs,
        total=sum(counts.values()),
        failed=len(mismatches),
        failures=mismatches,
    )


if __name__ == "__main__":
    port = int(os.environ.get("WEBAPP_PORT", "5001"))
    app.run(host="127.0.0.1", port=port, debug=False)
