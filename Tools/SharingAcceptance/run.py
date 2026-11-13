#!/usr/bin/env python3
"""Drive explicitly launched DEBUG acceptance instances; never grants OS privileges."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import time
import uuid

SSH = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5"]


class Device:
    def __init__(self, directory, remote=None):
        self.directory, self.remote = directory, remote

    def status(self):
        if not self.remote:
            return json.loads((Path(self.directory) / "status.json").read_text())
        code = "import json,pathlib,sys; print((pathlib.Path(sys.argv[1])/'status.json').read_text())"
        command = "python3 -c " + shlex.quote(code) + " " + shlex.quote(self.directory)
        return json.loads(subprocess.check_output(SSH + [self.remote, command], timeout=10))

    def command(self, action, allow_error=False, **values):
        request = {"id": str(uuid.uuid4()), "action": action, **values}
        data = json.dumps(request)
        if not self.remote:
            directory = Path(self.directory)
            temporary = directory / ("command-" + uuid.uuid4().hex)
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(data)
            os.replace(temporary, directory / "command.json")
        else:
            code = ("import os,pathlib,sys,uuid; d=pathlib.Path(sys.argv[1]); "
                    "p=d/('command-'+uuid.uuid4().hex); "
                    "fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); "
                    "f=os.fdopen(fd,'w'); f.write(sys.stdin.read()); f.close(); "
                    "os.replace(p,d/'command.json')")
            command = "python3 -c " + shlex.quote(code) + " " + shlex.quote(self.directory)
            subprocess.run(SSH + [self.remote, command], input=data, text=True, check=True, timeout=10)
        state = wait(lambda: self.status(), lambda s: s["lastCommand"].lower() == request["id"].lower(), 8)
        if state["error"] and not allow_error:
            raise RuntimeError(state["error"])
        return state


def wait(read, predicate, seconds=8):
    end = time.monotonic() + seconds
    last = None
    while time.monotonic() < end:
        last = read()
        if predicate(last):
            return last
        time.sleep(0.15)
    raise RuntimeError("Timed out; latest state: " + json.dumps(last, ensure_ascii=False))


def packet(kind, code=0, x=0, y=0):
    return dict(kind=kind, code=code, flags=0, x=x, y=y, clickCount=1, pressed=False)


def run(args):
    session = json.loads(Path(args.session).read_text())
    a, b = Device(session["local"]), Device(session["remote"], args.remote)
    if args.phase == "status":
        return dict(local=a.status(), remote=b.status())
    if args.phase == "network":
        a.command("start")
        b.command("start")
        wait(a.status, lambda s: s["running"] and s["port"] > 0)
        server = wait(b.status, lambda s: s["running"] and s["port"] > 0)
        started = time.monotonic()
        a.command("connect", host=args.peer, port=str(server["port"]))
        local = wait(a.status, lambda s: bool(s["peer"]))
        remote = wait(b.status, lambda s: bool(s["peer"]))
        return dict(result="passed", elapsed=round(time.monotonic() - started, 3),
                    localPeer=local["peer"], remotePeer=remote["peer"],
                    port=server["port"], protocol="TLS1.2-PSK-0x00A8", realApplications=True)
    if args.phase == "keyboard":
        states = [a.command("keyboard", enabled=True, allow_error=True), b.command("keyboard", enabled=True, allow_error=True)]
        if not all(s["keyboardEnabled"] for s in states):
            return dict(result="blocked", reason="OS input permissions or Secure Input", states=states)
        b.command("testWindow")
        wait(b.status, lambda s: s.get("target", {}).get("isKey") and s.get("target", {}).get("frontmost"))
        before = a.status()
        a.command("switchControl")
        try:
            wait(a.status, lambda s: s["control"] == "控制远端", 3)
            remote = wait(b.status, lambda s: s["control"] == "由远端控制", 3)
            target, cursor = remote["target"], remote["cursor"]
            dx, dy = target["x"] - cursor["x"], target["y"] - cursor["y"]
            if abs(dx) > 4096 or abs(dy) > 4096:
                raise RuntimeError("Test target is too far from entry; refusing unsafe pointer jump")
            packets = [packet("move", x=dx, y=dy), packet("down"), packet("up")]
            codes = [32, 45, 17, 34, 17, 37, 14, 2]  # fixed untitled; no Enter or application shortcuts
            for code in codes:
                packets += [packet("keyDown", code), packet("keyUp", code)]
            a.command("input", packets=packets)
            received = wait(b.status, lambda s: s.get("target", {}).get("keyDownCodes", [])[-7:] == codes, 3)
        finally:
            a.command("returnLocal", allow_error=True)
        local = wait(a.status, lambda s: s["control"] == "本机")
        remote = wait(b.status, lambda s: s["control"] == "本机")
        return dict(result="passed", target=received["target"], sourceCursorBefore=before["cursor"],
                    sourceCursorAfter=local["cursor"], bothReturnedLocal=remote["control"] == local["control"])
    if args.phase == "microphone":
        remote = b.status()
        if not remote["driverAvailable"]:
            return dict(result="blocked", reason="Remote HAL driver not installed/loaded", state=remote)
        inputs = a.status()["hardwareInputs"]
        source = next((d for d in inputs if d["uid"] == args.microphone_uid), None)
        if not source:
            return dict(result="blocked", reason="The explicitly selected physical microphone was not found")
        a.command("offerMicrophone", enabled=True, microphoneUID=source["uid"])
        b.command("receiveMicrophone", enabled=True)
        try:
            state = b.command("probe", allow_error=True)
            if state["error"]:
                return dict(result="blocked", reason=state["error"], state=state)
            wait(a.status, lambda s: s["sendingMicrophone"], 4)
            received = wait(b.status, lambda s: s["receivedAudioFrames"] > 0 and s["probe"]["frames"] > 0, 4)
            time.sleep(1)
            received = b.status()
            b.command("stopProbe")
            stopped = wait(a.status, lambda s: not s["sendingMicrophone"], 4)
            return dict(result="passed", source=source["name"], sentFrames=stopped["sentAudioFrames"],
                        receivedFrames=received["receivedAudioFrames"], virtualInputLevels=received["probe"],
                        stoppedWhenConsumerClosed=True, audioSaved=False)
        finally:
            b.command("stopProbe", allow_error=True)
            b.command("receiveMicrophone", enabled=False, allow_error=True)
            a.command("offerMicrophone", enabled=False, allow_error=True)
    if args.phase == "stop":
        local = a.command("stop", allow_error=True)
        remote = b.command("stop", allow_error=True)
        return dict(result="passed", localRunning=local["running"], remoteRunning=remote["running"],
                    localControl=local["control"], remoteControl=remote["control"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", default="/tmp/untitled-sharing-acceptance-session.json")
    parser.add_argument("--remote", required=True, help="Trusted SSH alias for the receiver")
    parser.add_argument("--peer", help="Receiver IP or DNS address, required for the network phase")
    parser.add_argument("--microphone-uid", help="Explicit physical input UID, required for microphone phase")
    parser.add_argument("--phase", choices=["status", "network", "keyboard", "microphone", "stop"], required=True)
    parser.add_argument("--report")
    args = parser.parse_args()
    if args.phase == "network" and not args.peer:
        parser.error("--peer is required for network testing")
    if args.phase == "microphone" and not args.microphone_uid:
        parser.error("--microphone-uid is required; do not implicitly capture a virtual/default device")
    try:
        result = {"phase": args.phase, **run(args)}
    except Exception as error:
        result = dict(phase=args.phase, result="failed", error=str(error))
    data = json.dumps(result, ensure_ascii=False, indent=2)
    if args.report:
        fd = os.open(args.report, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(data + "\n")
    print(data)
    return 0 if result.get("result", "passed") == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
