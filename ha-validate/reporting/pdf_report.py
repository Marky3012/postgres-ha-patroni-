from reportlab.lib.pagesizes import letter
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak,
)
from lib.models import Campaign, Status

STATUS_COLOR = {
    "PASS": colors.HexColor("#16a34a"), "FAIL": colors.HexColor("#dc2626"),
    "WARN": colors.HexColor("#d97706"), "SKIP": colors.HexColor("#6b7280"),
    "ERROR": colors.HexColor("#991b1b"),
}
READINESS_COLOR = {
    "READY": colors.HexColor("#16a34a"),
    "READY WITH WARNINGS": colors.HexColor("#d97706"),
    "NOT READY": colors.HexColor("#dc2626"),
}


def generate(campaign: Campaign, out_path: str):
    summary = campaign.summary()
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle("TitleX", parent=styles["Title"], fontSize=20)
    h2 = styles["Heading2"]
    body = ParagraphStyle("BodySmall", parent=styles["Normal"], fontSize=9, leading=12)

    doc = SimpleDocTemplate(out_path, pagesize=letter, topMargin=0.6 * inch, bottomMargin=0.6 * inch)
    story = []

    story.append(Paragraph("PostgreSQL HA Validation Report", title_style))
    story.append(Paragraph(f"Scope: {campaign.config_summary.get('scope', '')}", styles["Normal"]))
    story.append(Paragraph(f"Campaign duration: {summary['duration_s']}s", styles["Normal"]))
    story.append(Spacer(1, 16))

    readiness = summary["readiness_label"]
    exec_data = [
        ["HA Readiness", readiness],
        ["Readiness Score", f"{summary['readiness_score']}%"],
        ["Total Tests", str(summary["total_tests"])],
        ["Passed", str(summary["counts"]["PASS"])],
        ["Failed", str(summary["counts"]["FAIL"] + summary["counts"]["ERROR"])],
        ["Warnings", str(summary["counts"]["WARN"])],
    ]
    exec_table = Table(exec_data, colWidths=[2.2 * inch, 2.2 * inch])
    exec_table.setStyle(TableStyle([
        ("FONTNAME", (0, 0), (-1, -1), "Helvetica"),
        ("FONTSIZE", (0, 0), (-1, -1), 10),
        ("BACKGROUND", (0, 0), (1, 0), READINESS_COLOR.get(readiness, colors.grey)),
        ("TEXTCOLOR", (0, 0), (1, 0), colors.white),
        ("FONTNAME", (0, 0), (1, 0), "Helvetica-Bold"),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#e2e8f0")),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f8fafc")]),
    ]))
    story.append(exec_table)
    story.append(Spacer(1, 20))

    story.append(Paragraph("Category Breakdown", h2))
    cat_data = [["Category", "Status", "Tests"]]
    by_cat = campaign.by_category()
    for cat, status in summary["category_status"].items():
        n = len(by_cat.get(cat, []))
        cat_data.append([cat.replace("_", " ").title(), status, str(n)])
    cat_table = Table(cat_data, colWidths=[2.6 * inch, 1.5 * inch, 1 * inch])
    style_cmds = [
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#0f172a")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTSIZE", (0, 0), (-1, -1), 9),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#e2e8f0")),
    ]
    for i, (cat, status) in enumerate(summary["category_status"].items(), start=1):
        style_cmds.append(("BACKGROUND", (1, i), (1, i), STATUS_COLOR.get(status, colors.grey)))
        style_cmds.append(("TEXTCOLOR", (1, i), (1, i), colors.white))
    cat_table.setStyle(TableStyle(style_cmds))
    story.append(cat_table)
    story.append(Spacer(1, 20))

    failures = [r for r in campaign.results if r.status in (Status.FAIL, Status.ERROR)]
    story.append(Paragraph(f"Failure Analysis ({len(failures)} issue{'s' if len(failures) != 1 else ''})", h2))
    if not failures:
        story.append(Paragraph("No failures recorded this campaign.", styles["Normal"]))
    else:
        for r in failures:
            story.append(Paragraph(f"<b>[{r.category}] {r.name}</b>", body))
            story.append(Paragraph((r.details or "").replace("\n", "<br/>") or "(no details captured)", body))
            story.append(Spacer(1, 6))
    story.append(Spacer(1, 20))

    story.append(Paragraph("SLA Compliance", h2))
    sla_rows = [["Test", "Target", "Actual", "Met?"]]
    for r in campaign.results:
        if r.sla_target is None:
            continue
        sla_rows.append([
            r.name[:50], f"{r.sla_target}{r.sla_unit}", f"{r.sla_actual}{r.sla_unit}",
            "YES" if r.sla_met else "NO",
        ])
    if len(sla_rows) > 1:
        sla_table = Table(sla_rows, colWidths=[3 * inch, 1.1 * inch, 1.1 * inch, 0.8 * inch])
        sla_style = [
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#0f172a")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
            ("FONTSIZE", (0, 0), (-1, -1), 8),
            ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#e2e8f0")),
        ]
        for i, row in enumerate(sla_rows[1:], start=1):
            met = row[3] == "YES"
            sla_style.append(("BACKGROUND", (3, i), (3, i), colors.HexColor("#dcfce7") if met else colors.HexColor("#fee2e2")))
        sla_table.setStyle(TableStyle(sla_style))
        story.append(sla_table)
    else:
        story.append(Paragraph("No SLA-tracked tests ran this campaign.", styles["Normal"]))

    story.append(PageBreak())

    story.append(Paragraph("Full Test Results", h2))
    full_rows = [["Category", "Test", "Status", "Duration", "Details"]]
    for r in campaign.results:
        full_rows.append([
            r.category, r.name[:35], r.status.value, f"{r.duration_s}s", (r.details or "")[:60],
        ])
    full_table = Table(full_rows, colWidths=[1.1 * inch, 1.9 * inch, 0.7 * inch, 0.7 * inch, 2 * inch])
    full_style = [
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#0f172a")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTSIZE", (0, 0), (-1, -1), 7),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#e2e8f0")),
    ]
    for i, r in enumerate(campaign.results, start=1):
        full_style.append(("TEXTCOLOR", (2, i), (2, i), STATUS_COLOR.get(r.status.value, colors.black)))
    full_table.setStyle(TableStyle(full_style))
    story.append(full_table)

    doc.build(story)
    return out_path
