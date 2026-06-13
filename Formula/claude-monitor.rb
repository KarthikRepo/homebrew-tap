class ClaudeMonitor < Formula
  include Language::Python::Virtualenv

  desc "macOS menu-bar app to monitor Claude CLI token usage and cost"
  homepage "https://github.com/KarthikRepo/claude-monitor"
  license "MIT"
  version "1.3.0"

  # Tiny stable PyPI wheel used as a version anchor only — content is ignored.
  # Python sources are written from heredocs below (private tap, no public URL).
  url "https://files.pythonhosted.org/packages/d9/5a/e7c31adbe875f2abbb91bd84cf2dc52d792b5a01506781dbcf25c91daf11/six-1.16.0-py2.py3-none-any.whl",
      using: :nounzip
  sha256 "8abb2f1d86890a2dfb989f9a77cfcfd3e47c2a354b01111771326f8aa26e0254"

  depends_on "python@3.12"
  depends_on :macos

  resource "pyobjc-core" do
    url "https://files.pythonhosted.org/packages/24/be/4771f4fd786f0e1a2bd6d8931a72a5f3929b7bb1b28a1fe6ca8a08371c55/pyobjc_core-12.2-cp312-cp312-macosx_10_13_universal2.whl"
    sha256 "7677ed758a367bbbb5589d6f5276fb360a45c89168276c26162f61840b0fa03d"
  end

  resource "pyobjc-framework-Cocoa" do
    url "https://files.pythonhosted.org/packages/30/66/5a91f2eddfced4f26bc2df2bcebb7f5f10c5bf5666aff6fa00ded845af07/pyobjc_framework_cocoa-12.2-cp312-cp312-macosx_10_13_universal2.whl"
    sha256 "06cb92d97d1af9d1f459ae6cf1d1a7b824c12d3aff1b709885966acd6b7208c2"
  end

  resource "rumps" do
    url "https://files.pythonhosted.org/packages/b2/e2/2e6a47951290bd1a2831dcc50aec4b25d104c0cf00e8b7868cbd29cf3bfe/rumps-0.4.0.tar.gz"
    sha256 "17fb33c21b54b1e25db0d71d1d793dc19dc3c0b7d8c79dc6d833d0cffc8b1596"
  end

  def install
    python = Formula["python@3.12"].opt_bin/"python3.12"
    venv = virtualenv_create(libexec, python)

    %w[pyobjc-core pyobjc-framework-Cocoa].each do |r|
      cached = resource(r).cached_download
      wheel  = buildpath/cached.basename.to_s.sub(/\A[0-9a-f]+-+/, "")
      cp cached, wheel
      system python, "-m", "pip", "--python=#{libexec}/bin/python", "install", "--no-deps", "--no-index", wheel
    end
    venv.pip_install resource("rumps")

    dest = libexec/"share/claude_monitor"
    dest.mkpath

    (dest/"monitor_core.py").write <<'MONITOR_CORE_PY'
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
MONITOR_CORE_PY

    (dest/"menubar.py").write <<'MENUBAR_PY'
#!/usr/bin/env python3
"""
Claude Token Monitor — menu bar controller (entry point).

All settings live here. The floating widget is a pure read-only display.
"""

import os
import sys
import signal
import time
from pathlib import Path

# Must be the very first AppKit call — before rumps or widget are imported.
# Setting this here prevents the dock icon; rumps sets it too late on macOS 26.
from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
NSApplication.sharedApplication().setActivationPolicy_(NSApplicationActivationPolicyAccessory)

import rumps

from monitor_core import (
    load_config, save_config, fetch_all_periods, month_pace, fmt_cost, fmt_tok,
)
from widget import WidgetController

HERE     = os.path.dirname(os.path.abspath(__file__))
PID_FILE = Path.home() / '.claude_monitor.pid'


def _enforce_single_instance():
    """Kill any previous instance, then write our PID."""
    if PID_FILE.exists():
        try:
            old_pid = int(PID_FILE.read_text().strip())
            if old_pid != os.getpid():
                os.kill(old_pid, signal.SIGTERM)
                time.sleep(0.4)   # give it a moment to clean up
        except (ProcessLookupError, ValueError, OSError):
            pass
    PID_FILE.write_text(str(os.getpid()))


def _cleanup_pid():
    try:
        PID_FILE.unlink(missing_ok=True)
    except Exception:
        pass


_enforce_single_instance()
REFRESH_SEC = 15 * 60


def pace_emoji(label: str) -> str:
    return {'well under': '🟢', 'under pace': '🟢', 'on track': '🟡',
            'over pace': '🟠', 'over budget': '🔴', 'month start': '🟢'}.get(label, '🟢')


class MonitorApp(rumps.App):
    def __init__(self):
        super().__init__('Claude', title='◆ …', quit_button=None)

        # ── Menu structure ───────────────────────────────────────────────
        self.show_item = rumps.MenuItem('Hide Widget', callback=self.toggle_widget, key='h')

        self.menu = [
            self.show_item,
            rumps.MenuItem('Refresh Now', callback=self.manual_refresh, key='r'),
            None,
            rumps.MenuItem('Set Monthly Limit…', callback=self.set_limit),
            rumps.MenuItem('Set Refresh Interval…', callback=self.set_interval),
            None,
            rumps.MenuItem('About', callback=self.show_about),
            rumps.MenuItem('Quit Claude Monitor', callback=self.quit_app, key='q'),
        ]

        # Widget runs in-process — no subprocess, no dock icon
        self._widget = WidgetController.alloc().init()
        self._widget.setup()
        self._widget.view._hide_callback = self._on_widget_hidden

        cfg = load_config()
        if cfg.get('widget_visible', True):
            self._widget.show()
            self.show_item.title = 'Hide Widget'
        else:
            self.show_item.title = 'Show Widget'

        self.refresh()
        self._timer = rumps.Timer(self.refresh, REFRESH_SEC)
        self._timer.start()

    def _on_widget_hidden(self):
        self.show_item.title = 'Show Widget'

    # ── Widget control ────────────────────────────────────────────────────

    def _alive(self) -> bool:
        return self._widget.is_visible()

    def _launch_widget(self):
        self._widget.show()
        self.show_item.title = 'Hide Widget'

    def _kill_widget(self):
        self._widget.hide()
        self.show_item.title = 'Show Widget'

    # ── Callbacks ─────────────────────────────────────────────────────────

    def toggle_widget(self, _):
        if self._alive():
            self._kill_widget()
        else:
            self._launch_widget()

    def manual_refresh(self, _):
        if self._alive():
            self._widget.doRefresh()
        self.refresh()

    def set_limit(self, _):
        cfg = load_config()
        cur = int(cfg.get('monthly_limit', 100))
        w = rumps.Window(
            title='Monthly Budget Limit',
            message=f'Current limit: ${cur}\n\nEnter new monthly spend limit (USD):',
            default_text=str(cur),
            ok='Save', cancel='Cancel',
            dimensions=(120, 22),
        )
        r = w.run()
        if r.clicked:
            try:
                v = float(r.text.strip().lstrip('$'))
                if v > 0:
                    cfg['monthly_limit'] = v
                    save_config(cfg)
                    if self._alive():
                        self._widget.doRefresh()
                    self.refresh()
                else:
                    rumps.alert('Invalid', 'Limit must be greater than 0.')
            except ValueError:
                rumps.alert('Invalid', 'Please enter a number, e.g. 150')

    def set_interval(self, _):
        cfg = load_config()
        cur = int(cfg.get('refresh_minutes', 15))
        w = rumps.Window(
            title='Refresh Interval',
            message=f'Current: every {cur} minutes\n\nEnter new interval in minutes (1–60):',
            default_text=str(cur),
            ok='Save', cancel='Cancel',
            dimensions=(60, 22),
        )
        r = w.run()
        if r.clicked:
            try:
                v = int(r.text.strip())
                if 1 <= v <= 60:
                    cfg['refresh_minutes'] = v
                    save_config(cfg)
                    # restart timer
                    self._timer.stop()
                    self._timer = rumps.Timer(self.refresh, v * 60)
                    self._timer.start()
                    rumps.alert('Saved', f'Refresh interval set to {v} minutes.')
                else:
                    rumps.alert('Invalid', 'Please enter a number between 1 and 60.')
            except ValueError:
                rumps.alert('Invalid', 'Please enter a whole number.')

    def show_about(self, _):
        cfg  = load_config()
        data = fetch_all_periods()
        p    = month_pace(data['month']['cost'], cfg.get('monthly_limit', 100.0))
        lines = [
            f"Month:  {fmt_cost(data['month']['cost'])} / ${int(cfg['monthly_limit'])}  ({p['pct_budget']:.1f}%)  — {p['label']}",
            f"Week:   {fmt_cost(data['week']['cost'])}  ({fmt_tok(data['week']['output'])} out)",
            f"Year:   {fmt_cost(data['year']['cost'])}  ({data['year']['sessions']} sessions)",
            '',
            f"Resets {p['days_left']}d from now · {fmt_cost(p['remaining'])} remaining",
            '',
            'Reads ~/.claude/projects/**/*.jsonl',
            'Pricing: Opus $15/$75 · Sonnet $3/$15 · Haiku $0.80/$4 per 1M',
        ]
        rumps.alert(title='Claude Monitor', message='\n'.join(lines))

    def quit_app(self, _):
        self._widget.hide()
        rumps.quit_application()

    # ── Menu bar title refresh ────────────────────────────────────────────

    def refresh(self, _=None):
        try:
            data  = fetch_all_periods()
            cfg   = load_config()
            spent = data['month']['cost']
            p     = month_pace(spent, cfg.get('monthly_limit', 100.0))
            self.title = f"{pace_emoji(p['label'])} {fmt_cost(spent)}"
        except Exception:
            self.title = '◆ —'
        # keep show/hide label in sync (widget may have self-hidden via Esc)
        self.show_item.title = 'Hide Widget' if self._alive() else 'Show Widget'


if __name__ == '__main__':
    import atexit
    atexit.register(_cleanup_pid)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    MonitorApp().run()
MENUBAR_PY

    (dest/"widget.py").write <<'WIDGET_PY'
#!/usr/bin/env python3
"""
Claude Token Monitor — floating widget (pure AppKit/PyObjC, no tkinter).
All text drawn via drawRect_ — avoids NSTextField rendering issues on macOS 26.
"""
import sys
import os
import threading
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import objc
from AppKit import (
    NSApplication, NSApplicationActivationPolicyAccessory,
    NSPanel, NSColor, NSFont, NSMakeRect, NSMakePoint, NSPointInRect,
    NSView, NSBezierPath, NSFloatingWindowLevel,
    NSWindowStyleMaskBorderless, NSBackingStoreBuffered,
    NSTextAlignmentLeft, NSTextAlignmentRight, NSTextAlignmentCenter,
    NSTrackingArea, NSTrackingActiveAlways, NSTrackingMouseEnteredAndExited,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorIgnoresCycle,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSScreen, NSObject,
    NSFontAttributeName, NSForegroundColorAttributeName,
    NSParagraphStyleAttributeName, NSMutableParagraphStyle,
    NSLineBreakByTruncatingTail,
)
from Foundation import (
    NSAttributedString, NSOperationQueue,
    NSTimer, NSRunLoop, NSDefaultRunLoopMode,
    NSNotificationCenter,
)
from AppKit import NSWorkspace
from monitor_core import (
    load_config, save_config, fetch_all_periods, month_pace,
    fmt_tok, fmt_cost,
)
from datetime import datetime

W, H = 320.0, 252.0
REFRESH_SEC = 15 * 60
P = 14.0  # horizontal padding

# Close button hit area — top-right corner (AppKit Y from bottom)
_CLOSE_RECT = NSMakeRect(W - 28, H - 28, 20, 20)


# ── Colors ────────────────────────────────────────────────────────────────────
def _c(r, g, b, a=1.0):
    return NSColor.colorWithSRGBRed_green_blue_alpha_(r/255, g/255, b/255, a)

C_BG  = _c(12,  12,  26,  0.96)
C_SEP = _c(30,  30,  56)
C_DIM = _c(112, 112, 160)
C_TXT = _c(255, 255, 255)
C_BLU = _c(91,  200, 255)
C_WHT = _c(224, 220, 255)
C_YEL = _c(251, 191, 36)
C_RED = _c(255, 95,  87)
C_GRN = _c(34,  197, 94)
C_CLR = NSColor.clearColor()

def _hex_color(h):
    h = h.lstrip('#')
    return _c(int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))

def _sans(sz, bold=False):
    return NSFont.boldSystemFontOfSize_(sz) if bold else NSFont.systemFontOfSize_(sz)

def _mono(sz, bold=False):
    f = NSFont.fontWithName_size_('SF Mono', sz)
    if f is None:
        w = 0.4 if bold else -0.4
        f = NSFont.monospacedDigitSystemFontOfSize_weight_(sz, w)
    return f


# ── Text drawing helper ───────────────────────────────────────────────────────
def _txt(s, x, y, w, h, font, color, align=NSTextAlignmentLeft):
    ps = NSMutableParagraphStyle.alloc().init()
    ps.setAlignment_(align)
    ps.setLineBreakMode_(NSLineBreakByTruncatingTail)
    NSAttributedString.alloc().initWithString_attributes_(str(s), {
        NSFontAttributeName:            font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName:  ps,
    }).drawInRect_(NSMakeRect(x, y, w, h))


# ── Main widget view (draws everything) ──────────────────────────────────────
class WidgetView(NSView):
    """Single NSView that draws the entire widget in drawRect_."""

    def initWithFrame_(self, frame):
        self = objc.super(WidgetView, self).initWithFrame_(frame)
        if self is None:
            return None
        self._state = None
        self._top_sessions = []
        self._show_tooltip = False
        self._controller = None
        self._md_loc = None
        self._hide_callback = None   # set by MonitorApp to sync menu label
        return self

    def acceptsFirstMouse_(self, event):
        return True

    # ── Drawing ───────────────────────────────────────────────────────────────

    def drawRect_(self, rect):
        s = self._state
        col = (s['col'] if s else None) or C_GRN

        # Background with rounded corners
        C_BG.setFill()
        NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            self.bounds(), 14, 14).fill()

        # ── Separators ──
        C_SEP.setFill()
        NSBezierPath.fillRect_(NSMakeRect(0, 34, W, 1))
        NSBezierPath.fillRect_(NSMakeRect(0, 145, W, 1))

        # ── Footer (y=0..34) ──
        n = s['n_month'] if s else 0
        foot = f"{n} conversation{'s' if n != 1 else ''} this month ↑"
        _txt(foot, P, 9, 200, 20, _sans(11), C_DIM)
        if s:
            _txt(s['time'], W-P-64, 9, 64, 20, _sans(11), C_DIM, NSTextAlignmentRight)

        # ── Token table (y=35..145) ──
        CX = [P, 142, 204, 263]
        CW = [CX[1]-P-4, CX[2]-CX[1]-2, CX[3]-CX[2]-2, W-CX[3]-P]
        for i, txt in enumerate(('Input', 'Output', 'Cost')):
            _txt(txt, CX[i+1], 124, CW[i+1], 18,
                 _sans(11, bold=True), C_DIM, NSTextAlignmentRight)
        # Rows — AppKit Y is bottom-up: ri=0 at bottom (Year), ri=2 at top (Week)
        rows_data = [
            ('year',  'Year',  s['year']  if s else None, C_YEL),
            ('month', 'Month', s['month'] if s else None, col),
            ('week',  'Week',  s['week']  if s else None, C_YEL),
        ]
        for ri, (key, label, d, cost_col) in enumerate(rows_data):
            ry = 40 + ri * 27
            _txt(label, P, ry, 90, 24, _sans(13), C_DIM)
            if d:
                _txt(fmt_tok(d['input']),  CX[1], ry, CW[1], 24, _mono(13), C_BLU, NSTextAlignmentRight)
                _txt(fmt_tok(d['output']), CX[2], ry, CW[2], 24, _mono(13), C_WHT, NSTextAlignmentRight)
                _txt(fmt_cost(d['cost']),  CX[3], ry, CW[3], 24, _mono(13), cost_col, NSTextAlignmentRight)
            else:
                for ci in (1, 2, 3):
                    _txt('—', CX[ci], ry, CW[ci], 24, _mono(13), C_DIM, NSTextAlignmentRight)

        # ── Tooltip overlay (drawn AFTER table so it paints on top) ──
        if self._show_tooltip and self._top_sessions:
            self._draw_tooltip()

        # ── Budget section (y=146..252) ──
        C_SEP.setFill()
        NSBezierPath.fillRect_(NSMakeRect(P, 152, W-2*P, 6))
        pct_val = s['pct_budget'] if s else 0.0
        bar_w = (W-2*P) * min(pct_val/100.0, 1.0)
        if bar_w > 1:
            col.setFill()
            NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                NSMakeRect(P, 152, bar_w, 6), 3, 3).fill()

        spent_str = fmt_cost(s['spent']) if s else '$0'
        limit_str = f"/ ${int(s['limit'])}" if s else '/ $100'
        _txt(spent_str, P, 161, 118, 50, _mono(30, bold=True), col)
        _txt(limit_str, P+110, 171,  80, 30, _mono(15, bold=True), C_DIM)
        if s:
            _txt(s['exp_str'],    W-P-148, 183, 148, 20, _sans(11), C_DIM, NSTextAlignmentRight)
            _txt(s['remain_str'], W-P-148, 161, 148, 20, _sans(11), C_DIM, NSTextAlignmentRight)

        # Title row
        _txt('CLAUDE MONTHLY BUDGET', P, 220, 174, 20, _sans(10, bold=True), C_DIM)
        pct_str = f"{pct_val:.1f}%" if s else ''
        _txt(pct_str, P+176, 220, 52, 20, _mono(11, bold=True), col)
        _txt('●',     P+230, 220, 14, 20, _sans(11), col)

        # Close button ×
        _txt('×', W-28, H-27, 20, 20, _sans(14), C_DIM, NSTextAlignmentCenter)

    def _draw_tooltip(self):
        if not self._top_sessions:
            return
        rh = 26
        th = 28 + len(self._top_sessions) * rh + 6
        tw = W - 2*P
        tx, ty = P, 36

        # Solid opaque background so token table is fully covered
        _c(18, 18, 40, 1.0).setFill()
        NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(tx, ty, tw, th), 8, 8).fill()

        # Subtle border for definition against the widget background
        _c(55, 55, 100, 1.0).setStroke()
        path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(tx + 0.5, ty + 0.5, tw - 1, th - 1), 8, 8)
        path.setLineWidth_(1.0)
        path.stroke()

        _txt('Top conversations this month', tx+10, ty+th-24, tw-20, 20,
             _sans(11, bold=True), C_WHT)

        for i, sess in enumerate(self._top_sessions):
            ry = ty + th - 28 - (i + 1) * rh
            name = (sess['name'][:28] + '…') if len(sess['name']) > 28 else sess['name']
            _txt(f"{i+1}.  {name}", tx+10, ry, tw-80, 22, _sans(11), C_WHT)
            _txt(fmt_cost(sess['cost']), tx+tw-72, ry, 62, 22,
                 _mono(11, bold=True), C_YEL, NSTextAlignmentRight)

    # ── Mouse events ─────────────────────────────────────────────────────────

    def mouseEntered_(self, event):
        self._show_tooltip = True
        self.setNeedsDisplay_(True)

    def mouseExited_(self, event):
        self._show_tooltip = False
        self.setNeedsDisplay_(True)

    def mouseDown_(self, event):
        self._md_loc = event.locationInWindow()
        objc.super(WidgetView, self).mouseDown_(event)

    def mouseUp_(self, event):
        loc = event.locationInWindow()
        if self._md_loc is not None:
            dx = abs(loc.x - self._md_loc.x)
            dy = abs(loc.y - self._md_loc.y)
            if dx < 8 and dy < 8:
                pt = self.convertPoint_fromView_(loc, None)
                if NSPointInRect(pt, _CLOSE_RECT) and self._controller:
                    self._controller.hide()
        self._md_loc = None


# ── Widget controller ─────────────────────────────────────────────────────────
class WidgetController(NSObject):

    @objc.python_method
    def setup(self):
        """Create the window once. Call show() to make it visible."""
        cfg = load_config()
        sc  = NSScreen.mainScreen()
        if sc is None:
            vx, vy, vw, vh = 0.0, 0.0, 1440.0, 900.0
        else:
            vf = sc.visibleFrame()  # excludes menu bar and dock
            vx, vy = vf.origin.x, vf.origin.y
            vw, vh = vf.size.width, vf.size.height

        pos = cfg.get('pos')
        if not pos or len(pos) != 2:
            # Default: right side, upper-middle — avoids menu bar and notch area
            pos = [vx + vw - W - 16, vy + (vh - H) * 0.60]
        x, y = float(pos[0]), float(pos[1])
        # Clamp to visible area (handles stale coords from other monitors)
        x = max(vx, min(x, vx + vw - W))
        y = max(vy, min(y, vy + vh - H))

        self.win = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(x, y, W, H),
            NSWindowStyleMaskBorderless,
            NSBackingStoreBuffered,
            False,
        )
        self.win.setOpaque_(False)
        self.win.setBackgroundColor_(C_CLR)
        self.win.setLevel_(NSFloatingWindowLevel)
        self.win.setHidesOnDeactivate_(False)   # don't hide when another app gets focus
        self.win.setHasShadow_(True)
        self.win.setMovableByWindowBackground_(True)
        self.win.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorIgnoresCycle |
            NSWindowCollectionBehaviorFullScreenAuxiliary
        )
        self.win.setDelegate_(self)

        self.view = WidgetView.alloc().initWithFrame_(NSMakeRect(0, 0, W, H))
        self.view._controller = self
        self.win.setContentView_(self.view)

        ta = NSTrackingArea.alloc().initWithRect_options_owner_userInfo_(
            NSMakeRect(0, 0, W, 32),
            NSTrackingActiveAlways | NSTrackingMouseEnteredAndExited,
            self.view, None)
        self.view.addTrackingArea_(ta)
        self._timer = None

        # Re-raise the window whenever the active Space changes so it
        # never gets buried behind full-screen apps or other Spaces.
        NSWorkspace.sharedWorkspace().notificationCenter().addObserver_selector_name_object_(
            self, 'spaceDidChange:', 'NSWorkspaceActiveSpaceDidChangeNotification', None
        )

    def spaceDidChange_(self, notif):
        if self.is_visible():
            self.win.orderFrontRegardless()

    @objc.python_method
    def show(self):
        """Show the widget and start refreshing."""
        cfg = load_config()
        cfg['widget_visible'] = True
        save_config(cfg)
        # orderFrontRegardless bypasses app-active checks — required for
        # NSApplicationActivationPolicyAccessory apps that never become key.
        self.win.orderFrontRegardless()
        if not self._timer or not self._timer.isValid():
            self._timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                REFRESH_SEC, self, 'timerFired:', None, True)
            NSRunLoop.mainRunLoop().addTimer_forMode_(self._timer, NSDefaultRunLoopMode)
        self.doRefresh()

    @objc.python_method
    def hide(self):
        """Hide the widget and stop the timer."""
        o = self.win.frame().origin
        cfg = load_config()
        cfg['pos'] = [int(o.x), int(o.y)]
        cfg['widget_visible'] = False
        save_config(cfg)
        if self._timer:
            self._timer.invalidate()
            self._timer = None
        self.win.orderOut_(None)
        if self.view._hide_callback:
            self.view._hide_callback()

    @objc.python_method
    def is_visible(self):
        return hasattr(self, 'win') and self.win.isVisible()

    # ── NSWindowDelegate ──────────────────────────────────────────────────────

    def windowDidMove_(self, notif):
        o = self.win.frame().origin
        cfg = load_config()
        cfg['pos'] = [int(o.x), int(o.y)]
        save_config(cfg)

    def timerFired_(self, timer):
        self.doRefresh()

    def doRefresh(self):
        threading.Thread(target=self._bg_fetch, daemon=True).start()

    @objc.python_method
    def _bg_fetch(self):
        data = fetch_all_periods()
        NSOperationQueue.mainQueue().addOperationWithBlock_(lambda: self._apply(data))

    @objc.python_method
    def _apply(self, data):
        cfg   = load_config()
        limit = cfg.get('monthly_limit', 100.0)
        spent = data['month']['cost']
        p     = month_pace(spent, limit)
        col   = _hex_color(p['color'])
        expected = limit * p['pct_days'] / 100.0

        self.view._state = {
            'col':        col,
            'spent':      spent,
            'limit':      limit,
            'pct_budget': p['pct_budget'],
            'exp_str':    f"Exp by today: {fmt_cost(expected)}",
            'remain_str': f"{fmt_cost(p['remaining'])} left · {p['days_left']} days",
            'n_month':    data['month']['sessions'],
            'time':       datetime.now().strftime('%H:%M'),
            'week':       data['week'],
            'month':      data['month'],
            'year':       data['year'],
        }
        self.view._top_sessions = data['month'].get('top_sessions', [])
        self.view.setNeedsDisplay_(True)


# ── Entry point (standalone testing only) ────────────────────────────────────
if __name__ == '__main__':
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    ctrl = WidgetController.alloc().init()
    ctrl.setup()
    ctrl.show()
    app.run()
WIDGET_PY

    (bin/"claude-monitor").write <<~EOS
      #!/bin/bash
      if pgrep -f "claude_monitor/menubar.py" > /dev/null 2>&1; then
        echo "Claude Monitor is already running — look for ◆ in your menu bar."
        exit 0
      fi
      nohup "#{libexec}/bin/python3.12" "#{libexec}/share/claude_monitor/menubar.py" "$@" \
        > /tmp/claude_monitor.log 2>&1 &
      disown
      echo "Claude Monitor started — look for ◆ in your menu bar."
    EOS
  end

  def caveats
    <<~EOS
      Claude Monitor is a menu-bar app. Start it with:
        claude-monitor

      It will appear as ◆ in your menu bar.

      To start automatically at login:
        System Settings → General → Login Items → + → add claude-monitor
        (path: #{opt_bin}/claude-monitor)

      Usage data is read from: ~/.claude/projects/**/*.jsonl
    EOS
  end

  test do
    system Formula["python@3.12"].opt_bin/"python3.12", "-c",
           "import sys; sys.path.insert(0,'#{libexec}/share/claude_monitor'); import monitor_core"
  end
end
