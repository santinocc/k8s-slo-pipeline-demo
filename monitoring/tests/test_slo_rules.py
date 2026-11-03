"""Checks that the PrometheusRule implements exactly what slo/slo.yaml defines."""

from pathlib import Path
from typing import Any

import pytest
import yaml

ROOT = Path(__file__).parents[2]
SLO: dict[str, Any] = yaml.safe_load((ROOT / "slo" / "slo.yaml").read_text())
RULE: dict[str, Any] = yaml.safe_load((ROOT / "monitoring" / "slo-rules.yaml").read_text())
RULES = {r.get("record") or r["alert"]: r for g in RULE["spec"]["groups"] for r in g["rules"]}
BUDGET = f"(1 - {SLO['objective']})"


def _sli_windows() -> set[str]:
    windows = {SLO["window"]}
    for a in SLO["alerting"]:
        windows |= {a["long_window"], a["short_window"]}
    return windows


def _normalize(expr: str) -> str:
    return " ".join(expr.split())


@pytest.mark.parametrize("window", sorted(_sli_windows()))
def test_sli_recording_rule_matches_slo_queries(window: str) -> None:
    rule = RULES[f"slo:sli_error:ratio_rate{window}"]
    error = SLO["sli"]["error_query"].replace("{{window}}", window)
    total = SLO["sli"]["total_query"].replace("{{window}}", window)
    assert _normalize(rule["expr"]) == _normalize(f"({error} or vector(0)) / {total}")
    assert rule["labels"] == {"slo": SLO["name"]}


def test_error_budget_rule_uses_objective() -> None:
    rule = RULES["slo:error_budget_remaining:ratio"]
    assert BUDGET in rule["expr"]
    assert f"ratio_rate{SLO['window']}" in rule["expr"]


@pytest.mark.parametrize("spec", SLO["alerting"], ids=lambda a: a["alert"])
def test_burn_rate_alert_matches_slo(spec: dict[str, Any]) -> None:
    rule = RULES[spec["alert"]]
    threshold = f"({spec['burn_rate']} * {BUDGET})"
    selector = f'{{slo="{SLO["name"]}"}}'
    expected = (
        f"slo:sli_error:ratio_rate{spec['long_window']}{selector} > {threshold} and "
        f"slo:sli_error:ratio_rate{spec['short_window']}{selector} > {threshold}"
    )
    assert _normalize(rule["expr"]) == expected
    assert rule["for"] == spec["for"]
    assert rule["labels"]["severity"] == spec["severity"]


def test_every_alert_is_defined_in_slo() -> None:
    alerts = {name for name, r in RULES.items() if "alert" in r}
    assert alerts == {a["alert"] for a in SLO["alerting"]}
