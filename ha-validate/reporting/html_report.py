import html
from datetime import datetime
from lib.models import Campaign, Status

STATUS_COLOR = {
    "PASS": "#16a34a", "FAIL": "#dc2626", "WARN": "#d97706",
    "SKIP": "#6b7280", "ERROR": "#991b1b",
}

READINESS_COLOR = {"READY": "#16a34a", "READY WITH WARNINGS": "#d97706", "NOT READY": "#dc2626"}


def _esc(s) -> str:
    return html.escape(str(s))


def generate(campaign: Campaign, out_path: str):
    summary = campaign.summary()
    cats = summary["category_status"]

    rows_html = []
    for r in campaign.results:
        color = STATUS_COLOR.get(r.status.value, "#333")
        sla_str = "-"
        if r.sla_target is not None:
            met = "OK" if r.sla_met else "MISS"
            sla_str = f"{r.sla_actual}{r.sla_unit} / target {r.sla_target}{r.sla_unit} ({met})"
        metrics_str = ", ".join(f"{k}={v}" for k, v in (r.metrics or {}).items())
        rows_html.append(f"""
        <tr>
          <td>{_esc(r.category)}</td>
          <td>{_esc(r.name)}</td>
          <td><span class="badge" style="background:{color}">{r.status.value}</span></td>
          <td>{r.duration_s}s</td>
          <td>{_esc(sla_str)}</td>
          <td class="small">{_esc(metrics_str)}</td>
          <td class="small">{_esc(r.details)}</td>
        </tr>""")

    cat_labels = list(cats.keys())
    cat_values = [1 if cats[c] == "PASS" else (0.5 if cats[c] == "WARN" else 0) for c in cat_labels]
    cat_colors = [STATUS_COLOR.get(cats[c], "#6b7280") for c in cat_labels]

    readiness = summary["readiness_label"]
    readiness_color = READINESS_COLOR.get(readiness, "#6b7280")

    html_doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>HA Validation Report</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.0/chart.umd.min.js"></script>
<style>
  body {{ font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif; margin: 0; background: #f8fafc; color: #1e293b; }}
  header {{ background: #0f172a; color: white; padding: 24px 32px; }}
  header h1 {{ margin: 0 0 4px 0; font-size: 22px; }}
  header .sub {{ color: #94a3b8; font-size: 13px; }}
  .container {{ padding: 24px 32px; }}
  .cards {{ display: flex; gap: 16px; flex-wrap: wrap; margin-bottom: 24px; }}
  .card {{ background: white; border-radius: 10px; padding: 16px 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); min-width: 160px; }}
  .card .label {{ font-size: 12px; color: #64748b; text-transform: uppercase; letter-spacing: .04em; }}
  .card .value {{ font-size: 28px; font-weight: 700; margin-top: 4px; }}
  .readiness {{ background: {readiness_color}; color: white; }}
  .readiness .value {{ font-size: 20px; }}
  table {{ width: 100%; border-collapse: collapse; background: white; border-radius: 10px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }}
  th, td {{ text-align: left; padding: 10px 12px; border-bottom: 1px solid #e2e8f0; font-size: 13px; vertical-align: top; }}
  th {{ background: #f1f5f9; font-size: 11px; text-transform: uppercase; letter-spacing: .03em; color: #475569; }}
  .badge {{ color: white; padding: 2px 10px; border-radius: 999px; font-size: 11px; font-weight: 600; }}
  .small {{ font-size: 12px; color: #475569; max-width: 320px; }}
  .chart-wrap {{ background: white; border-radius: 10px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); margin-bottom: 24px; max-width: 700px; }}
</style>
</head>
<body>
<header>
  <h1>PostgreSQL HA Validation Report</h1>
  <div class="sub">Generated {_esc(datetime.now().isoformat(timespec='seconds'))} &middot; Campaign duration {summary['duration_s']}s &middot; Scope: {_esc(campaign.config_summary.get('scope', ''))}</div>
</header>
<div class="container">
  <div class="cards">
    <div class="card readiness"><div class="label">HA Readiness</div><div class="value">{_esc(readiness)}</div></div>
    <div class="card"><div class="label">Readiness Score</div><div class="value">{summary['readiness_score']}%</div></div>
    <div class="card"><div class="label">Total Tests</div><div class="value">{summary['total_tests']}</div></div>
    <div class="card"><div class="label">Passed</div><div class="value" style="color:#16a34a">{summary['counts']['PASS']}</div></div>
    <div class="card"><div class="label">Failed</div><div class="value" style="color:#dc2626">{summary['counts']['FAIL'] + summary['counts']['ERROR']}</div></div>
    <div class="card"><div class="label">Warnings</div><div class="value" style="color:#d97706">{summary['counts']['WARN']}</div></div>
  </div>

  <div class="chart-wrap">
    <canvas id="catChart" height="180"></canvas>
  </div>

  <table>
    <thead><tr><th>Category</th><th>Test</th><th>Status</th><th>Duration</th><th>SLA</th><th>Metrics</th><th>Details</th></tr></thead>
    <tbody>
      {''.join(rows_html)}
    </tbody>
  </table>
</div>
<script>
  new Chart(document.getElementById('catChart'), {{
    type: 'bar',
    data: {{
      labels: {cat_labels},
      datasets: [{{ label: 'Category status (1=PASS, 0.5=WARN, 0=FAIL)', data: {cat_values}, backgroundColor: {cat_colors} }}]
    }},
    options: {{ scales: {{ y: {{ min: 0, max: 1 }} }}, plugins: {{ legend: {{ display: false }} }} }}
  }});
</script>
</body>
</html>"""
    with open(out_path, "w") as f:
        f.write(html_doc)
    return out_path
