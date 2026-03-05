# Local MITM Overrides (mitmproxy)

## 1) Install mitmproxy

Install `mitmproxy` in your Python environment.

## 2) Prepare rules

Copy `rules.example.json` to `rules.json` and edit URL/file mappings.

## 3) Start proxy

```powershell
$env:SILMARIL_MITM_RULES = "D:\silmairl cdp\tools\mitm\rules.json"
mitmdump -s "D:\silmairl cdp\tools\mitm\local_overrides.py" --listen-host 127.0.0.1 --listen-port 8080
```

## 4) Trust mitmproxy certificate

Install the mitmproxy CA certificate in your local trust store so HTTPS interception works.

## 5) Launch Chrome through proxy

```powershell
start chrome --proxy-server="http://127.0.0.1:8080"
```

For CDP automation, add your normal `--remote-debugging-port=9222` args.

## Notes

- Overrides are local to your machine/session.
- Site deploys can invalidate overridden URLs.
- Prefer narrow regex rules for stability.

