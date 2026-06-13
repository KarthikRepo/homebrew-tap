#!/usr/bin/env python3
"""
Claude Token Monitor — shared core (data, config, pricing, formatting, colors).
Used by both the menu bar controller and the floating widget.
"""

import json
import calendar
from pathlib import Path
from datetime import datetime, timezone, timedelta
from typing import Dict

# ── Persistence ───────────────────────────────────────────────────────────────
CONFIG_PATH = Path.home() / '.claude_monitor_config.json'

def load_config() -> dict:
    try:
        if CONFIG_PATH.exists():
            d = json.loads(CONFIG_PATH.read_text())
            d.setdefault('monthly_limit', 100.0)
            d.setdefault('widget_visible', True)
            d.setdefault('pos', None)
            return d
    except Exception:
        pass
    return {'monthly_limit': 100.0, 'widget_visible': True, 'pos': None}

def save_config(cfg: dict):
    try:
        CONFIG_PATH.write_text(json.dumps(cfg, indent=2))
    except Exception:
        pass


# ── Pricing: USD / 1M tokens (input, output, cache_read, cache_write) ─────────
# Cache write = 125% of input price; cache read = 10% of input price
_PRICES = {
    'opus':   (15.00, 75.00,  1.50, 18.75),
    'sonnet': ( 3.00, 15.00,  0.30,  3.75),
    'haiku':  ( 0.80,  4.00,  0.08,  1.00),
}

def model_price(model: str) -> tuple:
    m = (model or '').lower()
    if 'opus'  in m: return _PRICES['opus']
    if 'haiku' in m: return _PRICES['haiku']
    return _PRICES['sonnet']


# ── Data collection ───────────────────────────────────────────────────────────
def _empty() -> dict:
    return dict(input=0, output=0, cache=0, cost=0.0, sessions=set(), messages=0)

def _project_name(path: Path) -> str:
    """Extract a readable project name from the encoded ~/.claude/projects/<dir> path."""
    parts = [p for p in path.parent.name.split('-') if p]
    # Drop common macOS path prefixes
    skip = {'Volumes', 'Users', 'home', 'private', 'var', 'folders'}
    parts = [p for p in parts if p not in skip]
    return '-'.join(parts[-3:]) if parts else path.parent.name

def fetch_all_periods() -> Dict[str, dict]:
    """Single pass over ~/.claude/projects/**/*.jsonl → week/month/year buckets."""
    now = datetime.now(tz=timezone.utc)
    monday = (now - timedelta(days=now.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0)
    cutoffs = {
        'week':  monday,
        'month': now.replace(day=1,  hour=0, minute=0, second=0, microsecond=0),
        'year':  now.replace(month=1, day=1, hour=0, minute=0, second=0, microsecond=0),
    }
    buckets: Dict[str, dict] = {k: _empty() for k in cutoffs}

    base = Path.home() / '.claude' / 'projects'
    if not base.exists():
        for b in buckets.values():
            b['sessions'] = 0
            b['top_sessions'] = []
        return buckets

    # Per-session tracking for month (for top-5 tooltip)
    month_session_cost: Dict[str, float] = {}
    month_session_name: Dict[str, str]  = {}

    for f in base.glob('**/*.jsonl'):
        try:
            lines = f.read_text('utf-8').splitlines()
        except Exception:
            continue
        proj_name = _project_name(f)
        for raw in lines:
            raw = raw.strip()
            if not raw:
                continue
            try:
                rec = json.loads(raw)
            except Exception:
                continue

            # Collect conversation titles (ai-title preferred, custom-title fallback)
            if rec.get('type') in ('ai-title', 'custom-title'):
                sid = rec.get('sessionId')
                title = (rec.get('aiTitle') or rec.get('customTitle') or '').strip()
                if sid and title and title not in ('New session', 'Code Project', ''):
                    month_session_name[sid] = title

            if rec.get('type') != 'assistant':
                continue
            msg   = rec.get('message', {})
            usage = msg.get('usage')
            if not usage:
                continue
            ts_str = rec.get('timestamp', '')
            try:
                ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
            except Exception:
                continue
            i  = usage.get('input_tokens', 0)
            o  = usage.get('output_tokens', 0)
            cr = usage.get('cache_read_input_tokens', 0)
            cw = usage.get('cache_creation_input_tokens', 0)
            pi, po, pcr, pcw = model_price(msg.get('model', ''))
            cost = (i*pi + o*po + cr*pcr + cw*pcw) / 1_000_000
            sid  = rec.get('sessionId')
            for key, cutoff in cutoffs.items():
                if ts >= cutoff:
                    b = buckets[key]
                    b['input']    += i
                    b['output']   += o
                    b['cache']    += cr + cw
                    b['cost']     += cost
                    b['messages'] += 1
                    if sid:
                        b['sessions'].add(sid)
            # Track per-session cost for month period
            if sid and ts >= cutoffs['month']:
                month_session_cost[sid] = month_session_cost.get(sid, 0.0) + cost
                month_session_name.setdefault(sid, proj_name)

    for b in buckets.values():
        b['sessions'] = len(b['sessions'])

    top = sorted(month_session_cost.items(), key=lambda x: x[1], reverse=True)[:5]
    buckets['month']['top_sessions'] = [
        {'name': month_session_name.get(sid, sid[:8]), 'cost': c, 'sid': sid}
        for sid, c in top
    ]
    for key in ('week', 'year'):
        buckets[key]['top_sessions'] = []

    return buckets


# ── Pace-aware color gradient ─────────────────────────────────────────────────
_STOPS = [
    (0.00, 0x22, 0xc5, 0x5e),
    (0.60, 0x86, 0xef, 0xac),
    (0.85, 0xa3, 0xe6, 0x35),
    (1.00, 0xf5, 0xc5, 0x42),
    (1.30, 0xfb, 0x92, 0x3c),
    (1.80, 0xef, 0x44, 0x44),
]

def _lerp(stops, t: float) -> str:
    t = max(0.0, min(t, stops[-1][0]))
    for i in range(len(stops) - 1):
        p0, r0, g0, b0 = stops[i]
        p1, r1, g1, b1 = stops[i + 1]
        if t <= p1:
            f = (t - p0) / (p1 - p0) if p1 > p0 else 0.0
            return '#{:02x}{:02x}{:02x}'.format(
                int(r0 + f*(r1-r0)), int(g0 + f*(g1-g0)), int(b0 + f*(b1-b0)))
    _, r, g, b = stops[-1]
    return f'#{r:02x}{g:02x}{b:02x}'

def pace_color(pct_budget: float, pct_days: float) -> str:
    if pct_days < 1.5:
        return _lerp(_STOPS, pct_budget / 100.0)
    return _lerp(_STOPS, pct_budget / pct_days)

def pace_label(pct_budget: float, pct_days: float) -> str:
    if pct_days < 1.5: return 'month start'
    p = pct_budget / pct_days
    if p < 0.6:  return 'well under'
    if p < 0.85: return 'under pace'
    if p < 1.15: return 'on track'
    if p < 1.5:  return 'over pace'
    return 'over budget'


# ── Derived month-pace numbers (shared) ───────────────────────────────────────
def month_pace(spent: float, limit: float) -> dict:
    now = datetime.now()
    days_in_month = calendar.monthrange(now.year, now.month)[1]
    days_elapsed  = (now.day - 1) + now.hour / 24.0
    pct_days      = days_elapsed / days_in_month * 100.0
    pct_budget    = (spent / limit * 100.0) if limit > 0 else 0.0
    return dict(
        days_in_month=days_in_month,
        days_left=days_in_month - now.day,
        pct_days=pct_days,
        pct_budget=pct_budget,
        color=pace_color(pct_budget, pct_days),
        label=pace_label(pct_budget, pct_days),
        remaining=max(limit - spent, 0.0),
    )


# ── Formatting ────────────────────────────────────────────────────────────────
def fmt_tok(n: int) -> str:
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000:     return f"{n/1_000:.1f}K"
    return str(n)

def fmt_cost(c: float) -> str:
    if c >= 1000: return f"${c/1000:.1f}K"
    if c >= 100:  return f"${c:.0f}"
    if c >= 10:   return f"${c:.1f}"
    return f"${c:.2f}"

def next_reset_label() -> str:
    now = datetime.now()
    y, m = (now.year + 1, 1) if now.month == 12 else (now.year, now.month + 1)
    return datetime(y, m, 1).strftime('%b %-d')
