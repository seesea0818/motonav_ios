"""Execute production Swift session/tracker/policy on macOS with bounded fake I/O."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[2]
web = (root/'MotoNav/WebMotor.swift').read_text()
models = web[web.index('struct MotorPoint'):web.index('enum MotorRoutes')]
session = web[web.index('final class WebMotorSession'):web.index('final class MotorBrowser')]
# Expose only this entrypoint's visibility to test its post-stop guard; body is unchanged.
session = session.replace('private func replan(_ point:', 'func replan(_ point:')
core = '\n'.join((root/'MotoNav'/name).read_text() for name in [
    'RouteGeometry.swift', 'MotorRouteTracker.swift', 'MotorReroutePolicy.swift'])
# Preserve the old production matcher as the output-parity/performance control.
old = (root/'tests/reroute-recovery/LegacyMotorRouteTracker.swift').read_text()
stubs = (root/'tests/reroute-recovery/Stubs.swift').read_text()
tests = (root/'tests/reroute-recovery/main.swift').read_text()
folder = Path(tempfile.mkdtemp(prefix='motonav-reroute-'))
source = folder/'main.swift'
source.write_text('import Foundation\nimport CoreLocation\nimport Combine\n'+models+core+old+stubs+session+tests)
subprocess.run(['swiftc', '-O', '-swift-version', '5', str(source), '-o', str(folder/'test')], check=True)
subprocess.run([str(folder/'test')], check=True, timeout=90)
