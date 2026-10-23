"""Install this project's API as a per-user macOS launch agent."""
import argparse
import os
import plistlib
import subprocess
import sys
from pathlib import Path

LABEL = 'com.rwkvprediction.market-api'
ROOT = Path(__file__).resolve().parents[1]


def install():
    if sys.platform != 'darwin':
        raise SystemExit('This installer requires macOS.')
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8787)
    args = parser.parse_args()
    logs = ROOT / 'backend/runtime'
    logs.mkdir(exist_ok=True)
    destination = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
    destination.parent.mkdir(parents=True, exist_ok=True)
    no_proxy = os.environ.get('NO_PROXY', os.environ.get('no_proxy', ''))
    no_proxy = ','.join(filter(None, [no_proxy, '127.0.0.1', 'localhost', 'push2his.eastmoney.com',
                                    'finance.sina.com.cn', 'vip.stock.finance.sina.com.cn',
                                    'www.joinquant.com', '.sse.com.cn', '.szse.cn', '.bse.cn']))
    definition = dict(Label=LABEL,
                      ProgramArguments=[sys.executable, str(ROOT / 'backend/server.py'), '--host', '0.0.0.0', '--port', str(args.port)],
                      WorkingDirectory=str(ROOT), RunAtLoad=True, KeepAlive=True, ThrottleInterval=10,
                      EnvironmentVariables=dict(PYTHONUNBUFFERED='1', PYTHONIOENCODING='utf-8', NO_PROXY=no_proxy),
                      StandardOutPath=str(logs / 'api.stdout.log'), StandardErrorPath=str(logs / 'api.stderr.log'))
    destination.write_bytes(plistlib.dumps(definition))
    domain = f'gui/{os.getuid()}'
    target = f'{domain}/{LABEL}'
    running = subprocess.run(['launchctl', 'print', target], capture_output=True)
    if running.returncode == 0:
        subprocess.run(['launchctl', 'bootout', target], check=True)
    subprocess.run(['launchctl', 'bootstrap', domain, str(destination)], check=True)
    print(f'Installed {destination}')
    print(f'Status: launchctl print {target}')
    print(f'Logs: {logs}')


if __name__ == '__main__':
    install()
