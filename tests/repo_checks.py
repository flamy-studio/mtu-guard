"""Portable policy/static checks. Run: python3 tests/repo_checks.py"""
from pathlib import Path
import tomllib
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
files = ['Cargo.toml', 'Cargo.lock', '.cargo/config.toml', 'build.rs', 'app.manifest',
         'LICENSE', 'README.md', 'src/main.rs', 'src/win.rs', 'src/policy.rs',
         'scripts/install.ps1', 'scripts/uninstall.ps1', 'install.cmd', 'uninstall.cmd', 'status.cmd',
         'tools/manual-mtu.ps1', 'tools/manual-common.ps1', 'manual-mtu.cmd', 'manual-check.cmd',
         'docs/MANUAL_MTU.md', 'tests/manual-mtu.Tests.ps1']
for f in files:
    assert (root / f).exists(), f'Missing {f}'
manifest = tomllib.loads((root / 'Cargo.toml').read_text(encoding='utf-8'))
config = tomllib.loads((root / '.cargo/config.toml').read_text(encoding='utf-8'))
lock = tomllib.loads((root / 'Cargo.lock').read_text(encoding='utf-8'))
version = manifest['package']['version']
assert version == (root / 'VERSION').read_text(encoding='utf-8').strip() + '.0'
assert next(p for p in lock['package'] if p['name'] == manifest['package']['name'])['version'] == version
identity = ET.parse(root / 'app.manifest').getroot().find('{urn:schemas-microsoft-com:asm.v1}assemblyIdentity')
assert identity.attrib['version'] == version + '.0'
assert config['target']['x86_64-pc-windows-msvc']['rustflags'] == ['-C', 'target-feature=+crt-static']
source = (root / 'src/win.rs').read_text(encoding='utf-8')
assert 'NotifyIpInterfaceChange' in source
assert 'GetIpInterfaceEntry' in source
assert 'SetIpInterfaceEntry' in source
assert 'SitePrefixLength = 0' in source
assert 'CancelMibChangeNotify2' in source
assert 'GetIfTable2' in source
assert 'FreeMibTable' in source
assert 'TARGET_MTU' in source
assert 'ServiceState::Stopped' in source
assert 'ServiceState::Running' in source
policy = (root / 'src/policy.rs').read_text(encoding='utf-8')
assert '1280' in policy
assert '"AmneziaVPN"' in policy
print('PASS: source layout, synchronized versions, static CRT config and API contract markers')
