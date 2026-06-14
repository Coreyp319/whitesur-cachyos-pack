#!/usr/bin/env python3
"""KRunner D-Bus runner: ask Claude, ask local Hermes, or web-search from KRunner.

Behaviour:
  * Type any query and pause: after DEBOUNCE_MS the rows "Ask Claude: <q>",
    "Ask Hermes: <q>" and "Search the web: <q>" auto-appear (low/weak relevance,
    so they sit at the bottom and never steal the default action).
  * Instant path (no waiting) via keyword prefix:
      c <text>  / claude <text> / ai <text>     -> Ask Claude
      h <text>  / hermes <text>                  -> Ask local Hermes (Ollama)
      s <text>  / ddg <text>    / search <text>  -> Web search

The debounce works because KRunner only re-queries on text change: every
keystroke supersedes the previous pending reply (answered empty), and only a
genuine pause lets the timer fire. No root required.
"""
import os
import subprocess
from urllib.parse import quote_plus

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

BUS_NAME = "dev.corey.krunner.claude"
OBJ_PATH = "/krunner"
IFACE = "org.kde.krunner1"

CLAUDE_BIN = ""   # templated by install.sh to `command -v claude` (empty = Ask-Claude hidden)
TERMINAL = "konsole"

# Local Hermes via Ollama. Both templated by install.sh: OLLAMA_BIN to the
# detected runner, HERMES_MODEL to the best pulled hermes* tag (empty = hidden).
OLLAMA_BIN = "/usr/bin/ollama"
HERMES_MODEL = "hermes4.3-36b"

CLAUDE_PREFIXES = ("c ", "claude ", "ai ")
HERMES_PREFIXES = ("h ", "hermes ")

# (prefixes, label, icon, url-template) — each is an instant prefix path.
ENGINES = (
    (("s ", "ddg ", "search "), "DuckDuckGo", "system-search",        "https://duckduckgo.com/?q={}"),
    (("gh ", "github "),        "GitHub",     "internet-web-browser", "https://github.com/search?q={}&type=repositories"),
    (("w ", "wiki "),           "Wikipedia",  "internet-web-browser", "https://en.wikipedia.org/w/index.php?search={}"),
    (("yt ", "youtube "),       "YouTube",    "youtube",              "https://www.youtube.com/results?search_query={}"),
)
DEFAULT_ENGINE = ENGINES[0]  # DuckDuckGo — used for the no-prefix auto-show

DEBOUNCE_MS = 3000   # auto-show appears this long after you stop typing
MIN_LEN = 2          # ignore very short queries

EXACT_MATCH = 100    # Plasma::QueryMatch::Type
SEP = "\x1f"


def _arg_for(query, prefixes):
    for p in prefixes:
        if query.startswith(p):
            return query[len(p):].strip()
    return None


class Runner(dbus.service.Object):
    def __init__(self):
        DBusGMainLoop(set_as_default=True)
        bus = dbus.SessionBus()
        bus_name = dbus.service.BusName(BUS_NAME, bus)
        super().__init__(bus_name, OBJ_PATH)
        self._activation_token = ""
        self._pending_reply = None
        self._pending_query = ""
        self._timeout_id = 0

    # --- match tuples -------------------------------------------------------
    def _claude_match(self, text, relevance):
        return (
            "claude" + SEP + text,
            "Ask Claude: " + text,
            "claude",
            EXACT_MATCH,
            relevance,
            {"subtext": dbus.String("Start a Claude Code session in konsole")},
        )

    def _hermes_match(self, text, relevance):
        return (
            "hermes" + SEP + text,
            "Ask Hermes: " + text,
            "applications-science",
            EXACT_MATCH,
            relevance,
            {"subtext": dbus.String("Chat with local Hermes (" + HERMES_MODEL + ") in konsole")},
        )

    def _open_match(self, engine, text, relevance):
        _prefixes, label, icon, url_tpl = engine
        return (
            "open" + SEP + url_tpl.format(quote_plus(text)),
            "Search " + label + ": " + text,
            icon,
            EXACT_MATCH,
            relevance,
            {"subtext": dbus.String(label + " in your browser")},
        )

    # --- debounce plumbing --------------------------------------------------
    def _settle_pending(self):
        """Answer any in-flight debounced call with an empty result and cancel its timer."""
        if self._timeout_id:
            GLib.source_remove(self._timeout_id)
            self._timeout_id = 0
        if self._pending_reply is not None:
            try:
                self._pending_reply([])
            except Exception:
                pass
            self._pending_reply = None

    def _fire(self):
        self._timeout_id = 0
        cb, q = self._pending_reply, self._pending_query
        self._pending_reply = None
        if cb is not None:
            cb(
                ([self._claude_match(q, 0.3)] if CLAUDE_BIN else [])
                + ([self._hermes_match(q, 0.3)] if OLLAMA_BIN and HERMES_MODEL else [])
                + [self._open_match(DEFAULT_ENGINE, q, 0.3)]
            )
        return False  # one-shot

    # --- krunner1 interface -------------------------------------------------
    @dbus.service.method(IFACE, in_signature="s", out_signature="a(sssida{sv})",
                         async_callbacks=("reply_cb", "error_cb"))
    def Match(self, query, reply_cb, error_cb):
        # A new query supersedes any pending debounced reply.
        self._settle_pending()

        text = _arg_for(query, CLAUDE_PREFIXES)
        if text and CLAUDE_BIN:
            reply_cb([self._claude_match(text, 1.0)])
            return
        text = _arg_for(query, HERMES_PREFIXES)
        if text and OLLAMA_BIN and HERMES_MODEL:
            reply_cb([self._hermes_match(text, 1.0)])
            return
        for engine in ENGINES:
            text = _arg_for(query, engine[0])
            if text:
                reply_cb([self._open_match(engine, text, 1.0)])
                return

        stripped = query.strip()
        if len(stripped) < MIN_LEN:
            reply_cb([])
            return

        # No prefix: debounce, then auto-show both options.
        self._pending_reply = reply_cb
        self._pending_query = stripped
        self._timeout_id = GLib.timeout_add(DEBOUNCE_MS, self._fire)

    @dbus.service.method(IFACE, out_signature="a(sss)")
    def Actions(self):
        return []

    @dbus.service.method(IFACE, in_signature="s")
    def SetActivationToken(self, token):
        self._activation_token = token or ""

    @dbus.service.method(IFACE, in_signature="ss")
    def Run(self, match_id, action_id):
        kind, _, payload = match_id.partition(SEP)
        env = None
        if self._activation_token:
            env = dict(os.environ)
            env["XDG_ACTIVATION_TOKEN"] = self._activation_token
            env["DESKTOP_STARTUP_ID"] = self._activation_token

        if kind == "claude":
            subprocess.Popen(
                [TERMINAL, "-e", "bash", "-lc", 'exec "$0" "$1"', CLAUDE_BIN, payload],
                start_new_session=True, env=env,
            )
        elif kind == "hermes":
            # Single-shot answer to the typed query, then hand off to an
            # interactive REPL on the same model for follow-ups.
            subprocess.Popen(
                [TERMINAL, "-e", "bash", "-lc",
                 '"$0" run "$1" "$2"; echo; exec "$0" run "$1"',
                 OLLAMA_BIN, HERMES_MODEL, payload],
                start_new_session=True, env=env,
            )
        elif kind == "open":
            subprocess.Popen(["xdg-open", payload], start_new_session=True, env=env)

    @dbus.service.method(IFACE)
    def Teardown(self):
        self._settle_pending()


if __name__ == "__main__":
    Runner()
    GLib.MainLoop().run()
