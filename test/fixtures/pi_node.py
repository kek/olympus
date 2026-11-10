#!/usr/bin/env python3
"""Offline stand-in for a Node executable; never imports Pi or calls a provider."""
import json
import os
import sys

envelope = json.loads(sys.stdin.readline())
mode = envelope["config"]["provider"]
request = envelope["request"]

if mode == "hang":
    marker = envelope["config"]["agent_dir"]
    with open(marker, "w") as stream:
        stream.write(str(os.getpid()))
    sys.stdin.read()
    with open(marker + ".closed", "w") as stream:
        stream.write("closed")
elif mode == "oversize":
    print("x" * 10000)
elif mode == "malformed":
    print("not json")
elif mode == "failure":
    print('{"ok":true,"value":{}}')
    sys.exit(1)
elif mode == "missing":
    print('{"ok":false,"error":"model_not_found"}')
else:
    print(json.dumps({"ok": True, "value": {"artifact": {
        "action": request["action"],
        "identity": request["identity"],
        "model": envelope["config"]["model"]
    }}}))
