#!/usr/bin/env python3
"""Fail CI if the public showcase contains obvious secret/private-runtime material."""
from pathlib import Path
import re, sys

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_PARTS = {
    "02_DATA", "04_OUTPUT", "08_ARCHIVE", "_LOCAL_SECRETS", ".git",
    "RESEARCH_SCREENSHOTS", "GAMEWEEKS"
}
FORBIDDEN_SUFFIXES = {".db", ".sqlite", ".sqlite3", ".pem", ".pfx", ".p12"}
PATTERNS = {
    "OpenAI/API key": re.compile(rb"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"),
    "Bearer token": re.compile(rb"(?i)\bBearer\s+[A-Za-z0-9._~-]{20,}"),
    "JWT": re.compile(rb"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
    "GitHub token": re.compile(rb"\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "personal Windows path": re.compile(rb"(?i)\b[A-Z]:\\Users\\[^\\\r\n]+"),
}

problems=[]
for p in ROOT.rglob("*"):
    if p.is_dir():
        continue
    rel=p.relative_to(ROOT)
    if any(part in FORBIDDEN_PARTS for part in rel.parts):
        problems.append(f"forbidden path: {rel}")
    if p.suffix.lower() in FORBIDDEN_SUFFIXES:
        problems.append(f"forbidden file type: {rel}")
    if p.name.lower() in {".env", ".env.local", ".env.production"}:
        problems.append(f"forbidden env file: {rel}")
    try:
        data=p.read_bytes()
    except Exception:
        continue
    for label, rx in PATTERNS.items():
        if rx.search(data):
            problems.append(f"{label}: {rel}")

if problems:
    print("PUBLIC SAFETY CHECK FAILED")
    for x in sorted(set(problems)):
        print("-",x)
    sys.exit(1)
print("PUBLIC SAFETY CHECK PASSED")
