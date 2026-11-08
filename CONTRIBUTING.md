# Contributing

Thanks for helping!

## Setup

```bash
pip install -e ".[dev]"
pytest
python -m pyflakes glassbed tests
python -m glassbed
```

## Reporting a printer model

Please open an issue with:

- the model name and firmware version (printer web page → Information)
- the output of `python -m glassbed --host <ip> status`
- the output of `curl http://<ip>/eSCL/ScannerCapabilities`
- what worked and what didn't

## Trying things without touching your settings

Set `GLASSBED_PROFILE=Glassbed-dev` (any name) to run the app with a separate settings profile.

## Code guidelines

- Protocol code (`escl.py`, `ipp.py`, `urf.py`, `render.py`) must not import Qt –
  it is shared by the GUI and the CLI.
- Never block the GUI thread: use `gui/worker.py:run_task`.
- User-facing strings go through `i18n.tr()`; add the translation to every table in
  `TRANSLATIONS` (`de`, `tr`, …). New language: add its code to `LANGUAGES` and a table.
