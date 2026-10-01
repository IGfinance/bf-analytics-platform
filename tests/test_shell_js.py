"""Логика webapp/static/shell.js на заглушке DOM (JavaScriptCore). Нет jsc (не macOS) — тест пропускается."""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
JSC_CANDIDATES = [
    "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc",
    shutil.which("jsc") or "",
]


def _jsc():
    return next((c for c in JSC_CANDIDATES if c and Path(c).exists()), None)


@pytest.mark.skipif(_jsc() is None, reason="нет движка jsc (JavaScriptCore)")
def test_shell_js_select_and_doors_logic():
    # Относительные пути из корня репозитория: jsc портит кириллицу в абсолютных аргументах.
    prelude = "var ARGS_DOMSTUB='tests/js/domstub.js'; var ARGS_SHELL='webapp/static/shell.js'"
    r = subprocess.run([_jsc(), "-e", prelude, "tests/js/test_shell.js"],
                       capture_output=True, text=True, timeout=60, cwd=ROOT)
    assert r.returncode == 0 and "проверок JS пройдено" in r.stdout, r.stdout + r.stderr
