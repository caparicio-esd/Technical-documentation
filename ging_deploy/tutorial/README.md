# Tutorial notebooks

Hands-on tour of the local MVD, one notebook per block of [FLOWS.md](../FLOWS.md), plus an explorer notebook. The same APIs are in the [Postman collection](../postman/README.md). Run them in order: each one saves the ids it creates (assets, agreements…) in `tutorial_state.json`, and the next ones read them from there.

Each notebook starts with the concepts it needs, then explains every call: what it does, why, and what comes back (with cells that pick the response apart).

| Notebook | Block | What you do | Concepts explained |
| --- | --- | --- | --- |
| `00_environment.ipynb` | — | Check the pods, the ingress host rule, the DID documents; pick a run id | dataspace, EDC runtimes, control/data plane, the four APIs, JSON-LD, did:web |
| `01_identity_onboarding.ipynb` | A | Define credential types, register participants, obtain and inspect credentials | Verifiable Credentials, issuer/holder/verifier, DCP, attestations, JWT anatomy, revocation status list |
| `02_publishing.ipynb` | B | Create four entries (asset + policy + contract definition) with different rules | asset, data address, ODRL, policy scopes, DSE policy functions, QuerySpec |
| `03_discovery.ipynb` | C | Direct DSP catalog, federated catalog (filter, sort), credential-filtered catalog | DSP, DCAT catalog anatomy, offers and offer ids, federated catalog |
| `04_negotiation.ipynb` | D | Negotiate step by step, a rejected negotiation and why, deleting it | DSP negotiation messages and states, agreement (shared vs local ids) |
| `05_transfer.ipynb` | E | Pull transfer, the EDR and its token, the data gateway, retire/reactivate, 20 s expiry | transfer process, pull vs push, EDR, policy monitor, retirement |
| `06_telemetry_billing.ipynb` | F | Telemetry events, monthly CSV report, error cases | telemetry pipeline, event broker, JWT roles |
| `07_inspection.ipynb` | G | Vault secrets, Postgres tables, state codes, logs | Vault KV v2 and aliases, EDC SQL stores, state machines as codes |
| `08_explorer.ipynb` | — | Playground: every read endpoint behind `query()` / `read()` helpers, with ready-made filters to change | QuerySpec, filterable fields, operators |

The notebooks are saved with the outputs of a verified run, so you can read what each call returns before running anything.

## Running

```bash
cd ging_deploy
source ./rc.sh && ./deploy-local-mvd.sh up    # the MVD must be up
cd tutorial && ./run.sh                       # creates venv/, installs requirements, opens JupyterLab
```

`dataspace.py` holds the shared plumbing: addresses, an HTTP call that prints `METHOD path -> status`, waiting for a state, kubectl/psql, JWT helpers, and `remember`/`recall` for the state file. Every dataspace request is written out in full in the notebooks.

Each pass creates its own assets (suffix = run id from notebook 00), so the series can be run again on the same deployment. After `deploy-local-mvd.sh down` + `up`, start again from 00.
