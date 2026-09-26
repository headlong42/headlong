"""Run the Slack Socket Mode bridge for a shellm identity.

Usage: headlong-slack-bridge [ROOT]

ROOT is the directory the web server serves (contains .identities/);
defaults to the current directory. Configuration comes from the
environment — see config.py.
"""

import argparse
import logging
import sys
import threading
from pathlib import Path

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

from . import config, outbound
from .inbound import Inbound
from .state import ActiveThreads


def main() -> None:
    parser = argparse.ArgumentParser(prog="headlong-slack-bridge", description=__doc__)
    parser.add_argument("root", nargs="?", default=".", help="Serve root (contains .identities/)")
    parser.add_argument("--verbose", action="store_true", help="Debug logging")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    serve_root = Path(args.root).resolve()
    if not serve_root.is_dir():
        raise SystemExit(f"Not a directory: {serve_root}")
    cfg = config.load(serve_root)

    app = App(token=cfg.bot_token)
    auth = app.client.auth_test()
    bot_user_id = auth["user_id"]
    peers = ",".join(sorted(cfg.peer_bot_users)) or "none"
    print(
        f"headlong-slack-bridge: identity={cfg.identity} bot={auth['user']} "
        f"({bot_user_id}) web={cfg.web_url} peers={peers} "
        f"(max {cfg.peer_max_turns} in a row, {cfg.peer_hourly_cap}/h)",
        file=sys.stderr,
    )

    threads = ActiveThreads(cfg.state_dir / "active_threads.json")
    stop_event = threading.Event()
    outbound.start(cfg, app.client, threads, stop_event)
    inbound = Inbound(cfg, app, bot_user_id, threads)

    handler = SocketModeHandler(app, cfg.app_token)
    try:
        handler.start()  # blocks
    finally:
        stop_event.set()
        inbound.stop()


if __name__ == "__main__":
    main()
