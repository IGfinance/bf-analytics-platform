#!/usr/bin/env python3
"""
Веб-форма для ручной загрузки отчётов WB в ClickHouse.

Маршруты:
  GET  /          — форма загрузки детального отчёта
  POST /upload    — обработка детального отчёта
  GET  /summary   — форма загрузки сводного отчёта
  POST /upload-summary — обработка сводного отчёта + сверка

Логин/пароль берутся из .env (WEBAPP_USER / WEBAPP_PASSWORD).
"""

import ntpath
import os
import posixpath
import sys
from functools import wraps
from pathlib import Path

from dotenv import load_dotenv
from flask import Flask, Response, render_template_string, request

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

UPLOAD_DIR = WEBAPP_DIR / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)


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


# ---------------------------------------------------------------------------
# Templates
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
  tr.fail { background: #fff0f0; }
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
<title>Загрузка детальных отчётов WB</title>{{ style }}</head>
<body>
  {{ nav }}
  <h1>Загрузка детальных отчётов WB</h1>
  {% if error %}<p class="error">{{ error }}</p>{% endif %}
  <form action="upload" method="post" enctype="multipart/form-data">
    <label for="cabinet">Кабинет</label>
    <input type="text" id="cabinet" name="cabinet" list="cabinets"
           placeholder="Например: AcmeShop" autocomplete="off" required>
    <datalist id="cabinets">
      {% for c in cabinets %}<option value="{{ c }}">{% endfor %}
    </datalist>
    <p class="hint">Название кабинета — как в отчётах WB.</p>

    <label for="files">Файлы детальных отчётов (.xlsx)</label>
    <input type="file" id="files" name="files" accept=".xlsx" multiple required>

    <input type="submit" value="Загрузить">
  </form>
</body></html>
"""

RESULT_HTML = """
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>Результат загрузки</title>{{ style }}</head>
<body>
  {{ nav }}
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
<title>Сводный отчёт WB + сверка</title>{{ style }}</head>
<body>
  {{ nav }}
  <h1>Загрузка сводного отчёта + сверка</h1>
  <p class="hint">Загрузите «Еженедельный сводный отчёт» (xlsx). Данные сохранятся
  в wb_report_summary, после чего автоматически запустится сверка с wb_reports.</p>
  {% if error %}<p class="error">{{ error }}</p>{% endif %}
  <form action="upload-summary" method="post" enctype="multipart/form-data">
    <label for="cabinet">Кабинет</label>
    <input type="text" id="cabinet" name="cabinet" list="cabinets"
           placeholder="Например: AcmeShop" autocomplete="off" required>
    <datalist id="cabinets">
      {% for c in cabinets %}<option value="{{ c }}">{% endfor %}
    </datalist>

    <label for="file">Файл сводного отчёта (.xlsx)</label>
    <input type="file" id="file" name="file" accept=".xlsx" required>

    <input type="submit" value="Загрузить и сверить">
  </form>
</body></html>
"""

SUMMARY_RESULT_HTML = """
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>Результат сверки</title>{{ style }}</head>
<body>
  {{ nav }}
  <h1>Результат загрузки и сверки</h1>
  {% if error %}
    <p class="error">Ошибка: {{ error }}</p>
  {% else %}
    <p class="ok">Загружено строк в wb_report_summary: {{ ingest_rows }}</p>
    <p>Проверок: <b>{{ total }}</b> &nbsp;|&nbsp;
       Расхождений: <b {% if failed > 0 %}class="error"{% else %}class="ok"{% endif %}>{{ failed }}</b>
    </p>

    {% if failed == 0 %}
      <p class="ok">Все поля в пределах допуска.</p>
    {% else %}
      <h2>Расхождения</h2>
      <table>
        <tr><th>№ отчёта</th><th>Тип</th><th>Период</th><th>Поле</th>
            <th>Сводный</th><th>ClickHouse</th><th>Разница</th><th>Допуск</th></tr>
        {% for r in failures %}
        <tr class="fail">
          <td>{{ r.report_number }}</td>
          <td>{{ r.report_type }}</td>
          <td>{{ r.period_start }} — {{ r.period_end }}</td>
          <td>{{ r.field_name }}</td>
          <td>{{ "%.2f"|format(r.expected_value) }}</td>
          <td>{{ "%.2f"|format(r.actual_value) }}</td>
          <td>{{ "%.2f"|format(r.diff) }}</td>
          <td>{{ r.tolerance }}</td>
        </tr>
        {% endfor %}
      </table>
    {% endif %}
  {% endif %}
  {% if logs %}<pre>{{ logs|join('\n') }}</pre>{% endif %}
  <a href="summary">← Загрузить ещё</a>
</body></html>
"""


# ---------------------------------------------------------------------------
# Routes — детальный отчёт
# ---------------------------------------------------------------------------

@app.route("/", methods=["GET"])
@requires_auth
def index():
    return render_template_string(
        FORM_HTML, style=_BASE_STYLE, nav=_NAV,
        error=None, cabinets=get_cabinets(),
    )


@app.route("/upload", methods=["POST"])
@requires_auth
def upload():
    cabinet = request.form.get("cabinet", "").strip()
    files = request.files.getlist("files")

    if not cabinet:
        return render_template_string(
            FORM_HTML, style=_BASE_STYLE, nav=_NAV,
            error="Укажите кабинет", cabinets=get_cabinets(),
        ), 400
    if not files or all(f.filename == "" for f in files):
        return render_template_string(
            FORM_HTML, style=_BASE_STYLE, nav=_NAV,
            error="Выберите хотя бы один файл", cabinets=get_cabinets(),
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
        return render_template_string(
            FORM_HTML, style=_BASE_STYLE, nav=_NAV,
            error="Ни одного .xlsx файла не найдено", cabinets=get_cabinets(),
        ), 400

    logs = []
    if skipped:
        logs.append(f"Пропущены не-xlsx файлы: {', '.join(skipped)}")

    try:
        summary = ingest_files(saved_paths, cabinet, log=logs.append)
    except Exception as e:
        return render_template_string(
            RESULT_HTML, style=_BASE_STYLE, nav=_NAV,
            error=str(e), summary=None, logs=logs,
        ), 500
    finally:
        for p in saved_paths:
            p.unlink(missing_ok=True)

    return render_template_string(
        RESULT_HTML, style=_BASE_STYLE, nav=_NAV,
        error=None, summary=summary, logs=logs,
    )


# ---------------------------------------------------------------------------
# Routes — сводный отчёт + сверка
# ---------------------------------------------------------------------------

@app.route("/summary", methods=["GET"])
@requires_auth
def summary_form():
    return render_template_string(
        SUMMARY_FORM_HTML, style=_BASE_STYLE, nav=_NAV,
        error=None, cabinets=get_cabinets(),
    )


@app.route("/upload-summary", methods=["POST"])
@requires_auth
def upload_summary():
    cabinet = request.form.get("cabinet", "").strip()
    f = request.files.get("file")

    if not cabinet:
        return render_template_string(
            SUMMARY_FORM_HTML, style=_BASE_STYLE, nav=_NAV,
            error="Укажите кабинет", cabinets=get_cabinets(),
        ), 400
    if not f or f.filename == "":
        return render_template_string(
            SUMMARY_FORM_HTML, style=_BASE_STYLE, nav=_NAV,
            error="Выберите файл", cabinets=get_cabinets(),
        ), 400

    filename = safe_filename(f.filename)
    if not filename.lower().endswith(".xlsx"):
        return render_template_string(
            SUMMARY_FORM_HTML, style=_BASE_STYLE, nav=_NAV,
            error="Файл должен быть .xlsx", cabinets=get_cabinets(),
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
            error=str(e), ingest_rows=0, total=0, failed=0,
            failures=[], logs=logs,
        ), 500
    finally:
        dest.unlink(missing_ok=True)

    # Преобразуем tuple-результат в dict для шаблона
    FIELDS = [
        "cabinet", "report_number", "report_type", "period_start", "period_end",
        "field_name", "expected_value", "actual_value", "diff", "tolerance", "is_ok",
    ]
    rows_as_dicts = [dict(zip(FIELDS, r)) for r in reconcile_rows]
    failures = [r for r in rows_as_dicts if not r["is_ok"]]

    return render_template_string(
        SUMMARY_RESULT_HTML, style=_BASE_STYLE, nav=_NAV,
        error=None,
        ingest_rows=ingest_result["rows"],
        total=len(rows_as_dicts),
        failed=len(failures),
        failures=failures,
        logs=logs,
    )


if __name__ == "__main__":
    port = int(os.environ.get("WEBAPP_PORT", "5001"))
    app.run(host="127.0.0.1", port=port, debug=False)
