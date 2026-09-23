# CloudWatch alarm -> Slack, running OFF the box on purpose: the box's own
# alert scripts (deploy/thinkers-death-alert.sh) cannot report the box
# itself going dark, which is exactly what the status-check alarms catch
# (2026-08-13: 13h of silence while the box was network-dead).
#
# Reuses the box's Slack credentials by reading the same SSM env parameter
# the instance bootstraps from (SLACK_BOT_TOKEN + SHELLM_ALERT_CHANNEL), so
# alerts land in the existing alert channel and there is no second secret
# to rotate.

import json
import os
import urllib.request

import boto3

_STATE_EMOJI = {
    "ALARM": ":rotating_light:",
    "OK": ":white_check_mark:",
    "INSUFFICIENT_DATA": ":grey_question:",
}


def _env_values(param_name):
    ssm = boto3.client("ssm")
    text = ssm.get_parameter(Name=param_name, WithDecryption=True)["Parameter"]["Value"]
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        values[key.strip()] = val.strip().strip("'\"")
    return values


def handler(event, _context):
    msg = json.loads(event["Records"][0]["Sns"]["Message"])
    state = msg.get("NewStateValue", "?")
    text = "{} *{}* is {}\n{}\n_{}_".format(
        _STATE_EMOJI.get(state, ":warning:"),
        msg.get("AlarmName", "unknown alarm"),
        state,
        msg.get("NewStateReason", ""),
        msg.get("StateChangeTime", ""),
    )

    env = _env_values(os.environ["ENV_PARAMETER"])
    # Prefer the alert-only app token (deploy/split-bridge-env.sh); the
    # bridge bot token is the pre-split fallback.
    token = env.get("HEADLONG_ALERT_TOKEN") or env.get("SLACK_BOT_TOKEN")
    channel = env.get("SHELLM_ALERT_CHANNEL")
    if not token or not channel:
        raise RuntimeError(
            "HEADLONG_ALERT_TOKEN (or SLACK_BOT_TOKEN) / SHELLM_ALERT_CHANNEL missing from env parameter"
        )

    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps({"channel": channel, "text": text}).encode(),
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json; charset=utf-8",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read())
    if not body.get("ok"):
        raise RuntimeError("Slack API error: " + json.dumps(body))
    return {"ok": True}
