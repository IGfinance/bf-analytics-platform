import sys
from pathlib import Path

# src/ — не пакет, модули импортируются по имени (как в CLI-обёртках)
SRC = Path(__file__).resolve().parent.parent / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))
