"""pytest bootstrap — ensure scripts/ is importable (unittest uses _common for the same)."""
import _common  # noqa: F401  (import side-effect: adds scripts/ to sys.path)
