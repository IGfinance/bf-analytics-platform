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
from flask import Flask, Response, render_template, request

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
        return render_template(
            "summary_result.html", error=str(e), ingest_rows=0, total=0, failed=0,
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

    return render_template(
        "summary_result.html",
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
