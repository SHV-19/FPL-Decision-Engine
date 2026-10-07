# Privacy and Public Source

The project operates with authenticated FPL state and sensitive local research material. Its private runtime must not be mirrored to a public GitHub repository.

Excluded categories: OIDC/access/refresh tokens, API keys, cookies, raw environment variables, account caches, authenticated responses, personal/participant profiles, manager/rival histories, mini-league private information, raw screenshots, research JSONL, GW histories, reports and backup ZIPs.

No absence-of-secret guarantee can be inferred solely from an automated redaction script. A clean curated source tree should be scanned before every commit, and any historical secret should be rotated.

The original local Windows project remains untouched. Current repository is private while reviewing the curated release. Do not switch visibility to public until complete source and history scans succeed.
