"""
Optional Home Assistant webhook.

If HOME_ASSISTANT_WEBHOOK_URL is set in .env, every speed test cycle is POSTed to it as
JSON, alongside the normal Telegram/Discord delivery:

    {"source": "netmon", "state": "ok" | "degraded" | "down",
     "download": Mbit/s, "upload": Mbit/s, "ping": ms, "jitter": ms,
     "packet_loss": %, "devices": int, "server": str, "isp": str,
     "timestamp": ISO-8601}

A "down" post (the speed test itself failed) carries only "state".
This is best-effort: any failure is logged and never interrupts netmon.
"""
import logging
import os
from typing import Optional

import requests

import models

log = logging.getLogger("netmon")


def _url() -> str:
    # Read at call time: config.py loads .env after this module is imported.
    return os.getenv("HOME_ASSISTANT_WEBHOOK_URL", "").strip()


def post(
    state: str,
    metric: Optional["models.NetworkMetric"] = None,
    device_count: Optional[int] = None,
    timeout: float = 10.0,
) -> None:
    url = _url()
    if not url:
        return

    payload: dict = {"source": "netmon", "state": state}
    if metric is not None:
        payload.update({
            "download": round(metric.download / 10**6, 2),
            "upload": round(metric.upload / 10**6, 2),
            "ping": round(metric.ping, 2),
            "jitter": None if metric.jitter_ms is None else round(metric.jitter_ms, 2),
            "packet_loss": None if metric.packet_loss_pct is None else round(metric.packet_loss_pct, 2),
            "server": metric.server,
            "isp": metric.client,
            "timestamp": metric.timestamp.isoformat(),
        })
    if device_count is not None:
        payload["devices"] = device_count

    try:
        response = requests.post(url, json=payload, timeout=timeout)
        if response.status_code >= 400:
            log.warning(f"Home Assistant webhook returned HTTP {response.status_code}")
    except Exception as exc:
        log.warning(f"Home Assistant webhook failed: {exc}")
