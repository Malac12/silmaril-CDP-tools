# Local MITM Overrides (mitmproxy)

This folder contains the local override addon and rule files used by the Silmaril proxy workflow.

## Windows Quick Start

1. Install `mitmproxy` in your Python environment.
2. Copy `rules.example.json` to `rules.json` and edit URL/file mappings.
3. Trust the mitmproxy CA certificate in your local trust store.
4. Start the proxy.
5. Launch Chrome through the proxy, or use the Silmaril helper commands that auto-start it for you.

## 1) Install mitmproxy

Example:

```powershell
python -m pip install --user mitmproxy
```

If `mitmdump.exe` is not on `PATH`, it is commonly installed under a user Scripts directory such as:

```text
C:\Users\<you>\AppData\Local\Packages\PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0\LocalCache\local-packages\Python313\Scripts
```

## 2) Prepare rules

Copy `rules.example.json` to `rules.json` and edit URL/file mappings.

## 3) Trust the mitmproxy certificate

mitmproxy generates its CA on first run in `~\.mitmproxy`.

Initialize the certificate files if needed:

```powershell
mitmdump --quit
```

On Windows, import the generated CA into the current user root store:

```powershell
Import-Certificate -FilePath "$env:USERPROFILE\.mitmproxy\mitmproxy-ca-cert.cer" -CertStoreLocation 'Cert:\CurrentUser\Root'
```

Without this step, HTTPS interception usually fails.

## 4) Start proxy manually

```powershell
$env:SILMARIL_MITM_RULES = "D:\silmaril cdp\tools\mitm\rules.json"
mitmdump -s "D:\silmaril cdp\tools\mitm\local_overrides.py" --listen-host 127.0.0.1 --listen-port 8080
```

If your machine fails upstream certificate-chain verification and requests return `502 Bad Gateway`, use:

```powershell
$env:SILMARIL_MITM_RULES = "D:\silmaril cdp\tools\mitm\rules.json"
mitmdump -s "D:\silmaril cdp\tools\mitm\local_overrides.py" --listen-host 127.0.0.1 --listen-port 8080 --set ssl_insecure=true
```

`ssl_insecure=true` is useful for local development when the machine cannot validate some upstream site certificates cleanly.

## 5) Launch Chrome through proxy

PowerShell example:

```powershell
Start-Process -FilePath "C:\Program Files\Google\Chrome\Application\chrome.exe" -ArgumentList @(
  "--proxy-server=http://127.0.0.1:8080"
  "--new-window"
)
```

For CDP automation, add your normal `--remote-debugging-port=9222` and profile arguments.

## 6) Preferred Silmaril workflows

For most usage, prefer the Silmaril commands instead of the manual steps above.

Safeguards:

- `proxy-override`, `proxy-switch`, and `openurl-proxy` require `--allow-mitm` unless `SILMARIL_ALLOW_MITM=1` is set for a trusted local session.
- Proxy helpers keep `--listen-host` loopback-only unless `--allow-nonlocal-bind` is explicitly provided.

Write or update a rule and auto-start the proxy:

```powershell
silmaril.cmd proxy-override --allow-mitm --match "https://www\\.example\\.com/assets/app\\.js$" --file "C:\Users\hangx\overrides\app.js" --yes
```

Open a URL through the proxy and auto-start it if needed:

```powershell
silmaril.cmd openurl-proxy "https://en.wikipedia.org/wiki/Pizza" --allow-mitm
```

Switch a rule between original and saved files:

```powershell
silmaril.cmd proxy-switch --match "https://en\.wikipedia\.org/wiki/Pizza(?:\?.*)?$" --original-file "D:\silmaril cdp\tools\mitm\overrides\pizza.raw.html" --saved-file "D:\silmaril cdp\tools\mitm\overrides\pizza.override.html" --use saved --allow-mitm --yes
```

## Notes

- Overrides are local to your machine and only apply while traffic flows through this proxy.
- Site deploys can invalidate overridden URLs.
- Prefer narrow regex rules for stability.
- Rule changes apply on the next matching request.
- `local_overrides.py` only replaces responses for configured matches; unmatched traffic is proxied through normally.
