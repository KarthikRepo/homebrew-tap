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
        CX = [P, 130, 195, 252]
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
        sessions = self._top_sessions[:3]  # cap at 3 rows to stay within token table area
        rh = 22
        th = 26 + len(sessions) * rh + 6
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

        _txt('Top conversations this month', tx+10, ty+th-22, tw-20, 18,
             _sans(11, bold=True), C_WHT)

        for i, sess in enumerate(sessions):
            ry = ty + th - 26 - (i + 1) * rh
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
