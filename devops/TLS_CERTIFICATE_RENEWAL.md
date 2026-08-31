# TLS Certificate Renewal Runbook

## Overview

Every public-facing RemitMortgage endpoint is served over TLS. An expired
certificate is a hard outage (browsers and API clients refuse the connection),
so certificate expiry is monitored automatically and this runbook covers the
response.

- **Monitor:** `scripts/check-tls-cert-expiry.sh`
- **Schedule:** `.github/workflows/tls-cert-expiry.yml` (daily at 06:00 UTC,
  plus `workflow_dispatch`)
- **Warning window:** 14 days (`TLS_WARN_DAYS`, overridable per run or via the
  `TLS_WARN_DAYS` repo variable)
- **Alert channel:** email to `ALERT_EMAIL_TO` on any endpoint that is
  `EXPIRING`, `EXPIRED`, or `UNREACHABLE`

## What is monitored

The effective endpoint list comes from the `TLS_MONITOR_DOMAINS` repo variable
when set, otherwise from `devops/tls-monitor-domains.txt`. Each entry is
`host[:port] [auto|manual]`; the optional last field forces the renewal
classification, which is otherwise inferred from the certificate issuer.

| Endpoint (example)            | Terminated at | Certificate      | Renewal    |
| ----------------------------- | ------------- | ---------------- | ---------- |
| `app.<domain>`, `www.<domain>`| CloudFront    | AWS ACM          | Automatic  |
| `api.<domain>`                | App Runner    | AWS-managed      | Automatic  |
| anything issued elsewhere     | varies        | manually issued  | Manual     |

## Reading an alert

The `tls-cert-expiry-report` artifact has one tab-separated row per endpoint:

```
host   port   renewal   days_left   state   not_after   issuer
```

- `state=OK` — outside the window, no action.
- `state=EXPIRING` / `EXPIRED` with `renewal=auto` — **the automation failed.**
  The certificate should already have been renewed. Go to
  [Auto-renewed certificates](#auto-renewed-certificates-lets-encrypt--aws-acm).
- `state=EXPIRING` / `EXPIRED` with `renewal=manual` — **a human must reissue
  it.** Go to [Manually managed certificates](#manually-managed-certificates).
- `state=UNREACHABLE` — the check could not complete a TLS handshake. Confirm
  the endpoint is actually up; a genuinely down endpoint is a separate
  incident, a reachable one may indicate a scan/firewall issue from the runner.

---

## Auto-renewed certificates (Let's Encrypt / AWS ACM)

These renew themselves. An alert means the renewal pipeline is broken and needs
a human to unblock it — **not** that you should wait for it to fix itself.

### AWS ACM (CloudFront `app`/`www`, App Runner `api`)

ACM auto-renews DNS-validated certificates ~60 days before expiry, but only
while the validation `CNAME` records still resolve.

1. Find the certificate and its status:
   ```bash
   aws acm list-certificates --region us-east-1
   aws acm describe-certificate --region us-east-1 \
     --certificate-arn <arn> \
     --query 'Certificate.{Status:Status,RenewalStatus:RenewalSummary.RenewalStatus,DomainValidation:DomainValidationOptions}'
   ```
   > CloudFront certificates **must** live in `us-east-1`. App Runner uses the
   > service's own region.
2. If `RenewalStatus` is `PENDING_VALIDATION`, a validation `CNAME` is missing
   from Route53. Re-add the `ResourceRecord` from `DomainValidationOptions` to
   the hosted zone (it is also emitted by Terraform — `terraform apply` in
   `devops/` reconciles it):
   ```bash
   aws route53 change-resource-record-sets --hosted-zone-id <zone> \
     --change-batch '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{
       "Name":"<validation name>","Type":"CNAME","TTL":300,
       "ResourceRecords":[{"Value":"<validation value>"}]}}]}'
   ```
   ACM completes renewal within a few hours once validation resolves.
3. If the certificate was replaced (new ARN), update `var.certificate_arn` in
   `devops/` and `terraform apply` so CloudFront points at the new one.
4. Re-run the monitor to confirm: **Actions → TLS Certificate Expiry
   Monitoring → Run workflow**.

### Let's Encrypt / certbot (any endpoint issued by "Let's Encrypt", "R10/R11", "E5/E6")

1. On the host, check the renewal timer and last attempt:
   ```bash
   systemctl status certbot.timer
   journalctl -u certbot --since '-3 days'
   certbot certificates
   ```
2. Do a dry run to surface the failure (rate limits, DNS/HTTP-01 challenge
   failure, port 80 blocked, plugin/hook error):
   ```bash
   certbot renew --dry-run
   ```
3. Fix the root cause, then force a real renewal and reload the terminator:
   ```bash
   certbot renew --force-renewal
   systemctl reload nginx   # or the relevant service
   ```
4. Re-run the monitor workflow to confirm `state=OK`.

---

## Manually managed certificates

For certificates not issued by an automated pipeline (partner-supplied,
EV/OV certificates, appliances). These need a person for every renewal.

1. **Generate a CSR** (2048-bit RSA minimum, or P-256 ECDSA), keeping the
   private key on the host that terminates TLS:
   ```bash
   openssl req -new -newkey rsa:2048 -nodes \
     -keyout <host>.key -out <host>.csr \
     -subj "/CN=<host>" \
     -addext "subjectAltName=DNS:<host>"
   ```
2. **Submit the CSR** to the CA and complete their validation. Start this as
   soon as the alert fires — OV/EV issuance can take days.
3. **Install** the issued certificate plus the full intermediate chain:
   - Direct host (nginx/Apache/HAProxy): copy the fullchain + key, then
     `nginx -t && systemctl reload nginx`.
   - Behind CloudFront/App Runner: import into ACM and repoint —
     ```bash
     aws acm import-certificate --region us-east-1 \
       --certificate fileb://<host>.crt \
       --certificate-chain fileb://chain.pem \
       --private-key fileb://<host>.key
     ```
     then set `var.certificate_arn` and `terraform apply` in `devops/`.
4. **Verify** the deployed chain and expiry:
   ```bash
   echo | openssl s_client -servername <host> -connect <host>:443 2>/dev/null \
     | openssl x509 -noout -dates -issuer
   ```
5. **Record** the new expiry so the next renewal is not a surprise, and
   re-run the monitor workflow.
6. If this endpoint should move to automated renewal, add it to ACM/certbot
   and change its line in `devops/tls-monitor-domains.txt` from `manual` to
   `auto` (or remove the override).

---

## Adding or removing a monitored endpoint

- **Preferred:** update the `TLS_MONITOR_DOMAINS` repo variable
  (Settings → Secrets and variables → Actions → Variables). Newline- or
  comma-separated, same `host[:port] [auto|manual]` grammar.
- **Fallback / documentation:** edit `devops/tls-monitor-domains.txt`. Changes
  there trigger the workflow's `pull_request` guard so the script still parses.

## Local check

```bash
TLS_MONITOR_DOMAINS="example.com, api.example.com manual" \
TLS_WARN_DAYS=21 \
./scripts/check-tls-cert-expiry.sh
```

Exit code `0` = all clear, `1` = at least one endpoint expiring/expired/
unreachable, `2` = misconfiguration (no domains, missing `openssl`).
