"""Core result types shared across all tests and report generators."""
from __future__ import annotations
import time
import uuid
from dataclasses import dataclass, field, asdict
from enum import Enum
from typing import Any


class Status(str, Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    WARN = "WARN"
    SKIP = "SKIP"
    ERROR = "ERROR"


# Weight of each category in the overall HA-readiness score. Must sum to 100.
CATEGORY_WEIGHTS = {
    "connectivity": 8,
    "replication": 14,
    "planned_failover": 14,
    "unplanned_failover": 16,
    "failback": 14,
    "data_integrity": 16,
    "performance": 6,
    "security": 8,
    "disaster_recovery": 4,
}

# A FAIL in any of these categories caps overall readiness at NOT READY,
# regardless of score - these are the ones where "mostly fine" isn't fine.
CRITICAL_CATEGORIES = {"data_integrity", "unplanned_failover", "failback"}


@dataclass
class TestResult:
    id: str
    name: str
    category: str
    status: Status
    started_at: float
    ended_at: float
    details: str = ""
    metrics: dict[str, Any] = field(default_factory=dict)
    logs: list[str] = field(default_factory=list)
    sla_target: float | None = None
    sla_actual: float | None = None
    sla_unit: str = ""
    sla_met: bool | None = None

    @property
    def duration_s(self) -> float:
        return round(self.ended_at - self.started_at, 3)

    def to_dict(self) -> dict:
        d = asdict(self)
        d["status"] = self.status.value
        d["duration_s"] = self.duration_s
        return d


class TestRunContext:
    """Carries config + shared clients into every test module's run()."""

    def __init__(self, config: dict):
        self.config = config
        self.results: list[TestResult] = []
        self._ssh_cache: dict[str, Any] = {}

    def new_result(self, name: str, category: str) -> "ResultBuilder":
        return ResultBuilder(self, name, category)

    def record(self, result: TestResult):
        self.results.append(result)


class ResultBuilder:
    """Context-manager sugar: `with ctx.new_result(...) as r:` times itself
    and records PASS/ERROR automatically based on whether an exception was
    raised inside the block, without every test module repeating boilerplate."""

    def __init__(self, ctx: TestRunContext, name: str, category: str):
        self.ctx = ctx
        self.name = name
        self.category = category
        self.id = str(uuid.uuid4())[:8]
        self.status = Status.PASS
        self.details = ""
        self.metrics: dict[str, Any] = {}
        self.logs: list[str] = []
        self.sla_target = None
        self.sla_actual = None
        self.sla_unit = ""
        self.sla_met = None
        self._start = None

    def log(self, line: str):
        self.logs.append(line)

    def set_sla(self, target: float, actual: float, unit: str = "s", lower_is_better: bool = True):
        self.sla_target = target
        self.sla_actual = actual
        self.sla_unit = unit
        self.sla_met = (actual <= target) if lower_is_better else (actual >= target)
        if not self.sla_met and self.status == Status.PASS:
            self.status = Status.WARN

    def __enter__(self):
        self._start = time.time()
        return self

    def __exit__(self, exc_type, exc, tb):
        end = time.time()
        if exc_type is not None:
            self.status = Status.ERROR
            self.details = f"{self.details}\nException: {exc}".strip()
            self.logs.append(f"EXCEPTION: {exc_type.__name__}: {exc}")
        result = TestResult(
            id=self.id, name=self.name, category=self.category, status=self.status,
            started_at=self._start, ended_at=end, details=self.details,
            metrics=self.metrics, logs=self.logs, sla_target=self.sla_target,
            sla_actual=self.sla_actual, sla_unit=self.sla_unit, sla_met=self.sla_met,
        )
        self.ctx.record(result)
        return True  # swallow exception - it's recorded as ERROR, run continues


@dataclass
class Campaign:
    started_at: float
    ended_at: float
    results: list[TestResult]
    config_summary: dict

    def by_category(self) -> dict[str, list[TestResult]]:
        out: dict[str, list[TestResult]] = {}
        for r in self.results:
            out.setdefault(r.category, []).append(r)
        return out

    def category_status(self, cat: str) -> Status:
        rs = self.by_category().get(cat, [])
        if not rs:
            return Status.SKIP
        if any(r.status in (Status.FAIL, Status.ERROR) for r in rs):
            return Status.FAIL
        if any(r.status == Status.WARN for r in rs):
            return Status.WARN
        return Status.PASS

    def readiness_score(self) -> float:
        total_weight = 0
        earned = 0.0
        for cat, weight in CATEGORY_WEIGHTS.items():
            rs = self.by_category().get(cat)
            if not rs:
                continue  # category not run - excluded from scoring, not penalized
            total_weight += weight
            passed = sum(1 for r in rs if r.status == Status.PASS)
            warned = sum(1 for r in rs if r.status == Status.WARN)
            earned += weight * (passed + 0.5 * warned) / len(rs)
        return round(100 * earned / total_weight, 1) if total_weight else 0.0

    def readiness_label(self) -> str:
        for cat in CRITICAL_CATEGORIES:
            if self.category_status(cat) in (Status.FAIL,):
                return "NOT READY"
        score = self.readiness_score()
        if score >= 90:
            return "READY"
        if score >= 70:
            return "READY WITH WARNINGS"
        return "NOT READY"

    def summary(self) -> dict:
        counts = {s.value: 0 for s in Status}
        for r in self.results:
            counts[r.status.value] += 1
        return {
            "total_tests": len(self.results),
            "counts": counts,
            "readiness_score": self.readiness_score(),
            "readiness_label": self.readiness_label(),
            "duration_s": round(self.ended_at - self.started_at, 1),
            "category_status": {c: self.category_status(c).value for c in CATEGORY_WEIGHTS},
        }
