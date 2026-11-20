"""Shared byte guard for the direct runner and individual CTest processes."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys

def fingerprints():
    roots=[Path.home()/"Library/Application Support/TTPlayer",Path(os.environ.get("XDG_DATA_HOME",Path.home()/".local/share"))/"TTPlayer"]
    if os.environ.get("APPDATA"):roots.append(Path(os.environ["APPDATA"])/"TTPlayer")
    return {str(path):hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
            for root in roots for path in (root/"state.json",root/"resume.json")}

if __name__=="__main__":
    before=fingerprints()
    modes=["noresp","slow","stall","disconnect","icy","denied","retry"] if os.environ.get("TTPLAYER_QT_RADIOLIVE_PROBE") else [None]
    code=0
    for mode in modes:
        environment=dict(os.environ)
        if mode:environment.update(TTPLAYER_QT_RADIOLIVE_MODE=mode,TTPLAYER_QT_RADIOLIVE_STRESS="30")
        result=subprocess.run(sys.argv[1:],env=environment)
        if result.returncode:code=result.returncode
    changed=before!=fingerprints()
    if changed:print("USER_STATE_GUARD FAIL: state/resume bytes changed",file=sys.stderr)
    sys.exit(1 if changed else code)
