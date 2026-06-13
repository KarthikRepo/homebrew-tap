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
