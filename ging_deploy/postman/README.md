# Postman collection

`deploytour-mvd.postman_collection.json` (Postman collection format v2.1) covers every API of the local MVD: 156 requests, verified end to end with newman against the running cluster (174 assertions, 0 failures).

## Import

1. Bring the MVD up: `cd ging_deploy && source ./rc.sh && ./deploy-local-mvd.sh up`.
2. In the Postman **desktop app**, go to a **regular workspace** (for example *My Workspace*), not a *Local* workspace: Local mode only reads YAML and refuses JSON files ("Upgrade files").
3. **Import** (top left) → drag `deploytour-mvd.postman_collection.json` → *Import*. The collection **DEPLOYTOUR local MVD** appears in the sidebar with six folders.
4. No environment is needed. Every value (base URL, DIDs, base64 participant contexts, DSP addresses) is a **collection variable** (click the collection → *Variables*). Ids captured while running are stored there too.

To load a newer version of the file: delete the collection in Postman and import again (importing twice creates two copies).

## Folders

| Folder | What it is |
| --- | --- |
| **1 · Walkthrough** | The full flow in order: A identity → B publishing → C discovery → D negotiation → E transfer → F billing. Each request saves what the next ones need (offers, negotiation id, agreement ids, transfer id, EDR token) |
| **2 · Reference · Management API** | Every read endpoint of the provider and consumer connectors, single objects by id, and write examples (create/update/delete, transfer suspend/resume/terminate) on throwaway objects |
| **3 · Reference · Catalogs** | DSP catalog, single dataset, federated catalog (with filter/sort), credential-filtered federated catalog |
| **4 · Reference · Identity hubs** | DID documents, participant contexts, credentials, key pairs, DIDs, credential request status, admin-wide lists |
| **5 · Reference · Issuer** | Holders, attestation definitions, credential definitions, issuance processes, issued credentials, DSE attestations, status list; writes on a fake holder |
| **6 · Reference · Data, telemetry, Vault** | Data gateway, public data plane, SAS token endpoint, billing error cases (including the accepted forged JWT), Vault KV reads, health |

Every request has a description: what it does, what it needs, what it returns.

## Running

- **Run the Walkthrough with the Runner**: right click **1 · Walkthrough** → *Run folder* → *Run*. The `… (poll)` requests repeat themselves with `postman.setNextRequest` until the asynchronous process reaches its final state; that only works in the Runner and newman. When clicking requests one by one, resend the poll request until it shows the final state.
- The reference folders use the ids captured by the walkthrough, so run it once first.
- `runId` (6 hex chars) is set on the first request and used to name everything the collection creates (`pm-data-<runId>`, `ref-asset-<runId>`…). Clear it to start a fresh set.
- A4 skips credential requests when the wallet already holds that credential type (pre-request script + `pm.execution.skipRequest()`).
- F builds the billing JWT (HS256) in a pre-request script with CryptoJS and picks a far-future month derived from `runId`, so the report does not exist yet.

From the command line:

```bash
npx newman run ging_deploy/postman/deploytour-mvd.postman_collection.json --delay-request 1000
```

The delay matters: firing requests back to back on an 8 GB Docker Desktop can saturate the kind node, and the EDC runtimes get restarted by their liveness probes (they have no resource limits).

## Things the collection makes visible

| Finding | Request |
| --- | --- |
| The data gateway rejects a GET that carries `Content-Type` (400) and needs `Contract-Id` (500 without it) | E1 Read data through the consumer gateway |
| The EDR token works directly against the provider's public data plane, without the `Bearer` prefix | E1 Read data directly from the provider |
| Retirement needs the **provider's** agreement id | E6 Provider transfer → E6 Retire |
| `GET /v3/secrets/<id>` returns the secret in clear text | Reference · Secret by id |
| Holders cannot be read by DID in the path (ambiguous URI encoding); use `holders/query` | Reference · Issuer |
| Terminating a FINALIZED negotiation returns 500 | Reference · Terminate negotiation |
| The CSV manager accepts a JWT with a forged signature | Reference · Billing report · forged signature |

## Not included

These exist in EDC 0.16 but were not exercised here, so they are left out rather than guessed: issuer credential revoke/suspend, identity hub participant creation/deletion, key pair add/rotate/revoke, DID publish/unpublish, Management API `v4alpha` (not exposed in this deployment).
