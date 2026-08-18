#!/usr/bin/env python3
"""Executable truth table for the KernelSU-owned SUS_MAP visibility helper."""
PER_USER_RANGE = 100000
FIRST_APPLICATION_UID = 10000
LAST_APPLICATION_UID = 19999
FIRST_ISOLATED_UID = 99000
LAST_ISOLATED_UID = 99999

def appid(uid: int) -> int:
    return uid % PER_USER_RANGE

def is_appuid(uid: int) -> bool:
    value = appid(uid)
    return FIRST_APPLICATION_UID <= value <= LAST_APPLICATION_UID

def is_isolated(uid: int) -> bool:
    value = appid(uid)
    return FIRST_ISOLATED_UID <= value <= LAST_ISOLATED_UID

def should_hide(uid: int, live_should_umount: bool) -> bool:
    if not is_appuid(uid) and not is_isolated(uid):
        return False
    if is_isolated(uid):
        return True
    return live_should_umount

cases = [
    ('primary app default umount', 10320, True, True),
    ('primary app explicit opt-out', 10320, False, False),
    ('primary app root-allowed', 10320, False, False),
    ('manager app policy denial', 10300, False, False),
    ('secondary-user app', 110320, True, True),
    ('secondary-user app opt-out', 110320, False, False),
    ('secondary-user root', 100000, True, False),
    ('secondary-user system', 101000, True, False),
    ('primary isolated default-off', 99000, False, True),
    ('secondary isolated default-off', 199000, False, True),
    ('root', 0, True, False),
    ('system', 1000, True, False),
    ('webview zygote', 1053, True, False),
]
for name, uid, policy, expected in cases:
    actual = should_hide(uid, policy)
    if actual != expected:
        raise SystemExit(f'{name}: uid={uid} policy={policy} got={actual} expected={expected}')
print(f'SUSMAP_POLICY_MATRIX_OK cases={len(cases)}')
