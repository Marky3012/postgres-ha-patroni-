import json
from lib.models import Campaign


def generate(campaign: Campaign, out_path: str):
    data = {
        "summary": campaign.summary(),
        "config_summary": campaign.config_summary,
        "started_at": campaign.started_at,
        "ended_at": campaign.ended_at,
        "results": [r.to_dict() for r in campaign.results],
    }
    with open(out_path, "w") as f:
        json.dump(data, f, indent=2, default=str)
    return out_path
