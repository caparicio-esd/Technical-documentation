"""Helpers shared by the tutorial notebooks.

Only plumbing lives here: addresses, an HTTP call that prints what it does,
polling, kubectl, and a small file to pass ids between notebooks.
The dataspace requests themselves are written out in full in the notebooks.
"""

import base64
import hashlib
import hmac
import json
import pathlib
import subprocess
import time

import requests

# ---------------------------------------------------------------------------
# Where things are
# ---------------------------------------------------------------------------

BASE_URL = "http://localhost"   # ingress-nginx; it only routes requests whose Host is "localhost"
KUBE_CONTEXT = "kind-dse-cluster"
PARTICIPANTS = ["authority", "provider", "consumer"]

# ---------------------------------------------------------------------------
# Protocol constants
# ---------------------------------------------------------------------------

EDC = "https://w3id.org/edc/v0.0.1/ns/"   # EDC JSON-LD namespace
EDC_CONTEXT = {"@vocab": EDC}              # enough for assets, transfers, queries

# The Management API context adds the ODRL terms (Offer, permission, eq, ...).
# The DSE policy prefix is needed for constraints like dse-policy:Membership.
MANAGEMENT_CONTEXT = [
    "https://w3id.org/edc/connector/management/v0.0.1",
    {"dse-policy": "https://w3id.org/dse/policy/"},
]

DSP_PROTOCOL = "dataspace-protocol-http:2025-1"
VAULT_TOKEN = "root"


# ---------------------------------------------------------------------------
# Identifiers and API addresses
# ---------------------------------------------------------------------------

def did(participant):
    """did:web identifier, e.g. did:web:provider-identityhub%3A8383:api:did"""
    return f"did:web:{participant}-identityhub%3A8383:api:did"


def participant_context(participant):
    """Id used in identity hub and issuer URLs: the participant's DID in base64url."""
    return base64.urlsafe_b64encode(did(participant).encode()).decode()


def dsp_address(participant):
    """In-cluster DSP endpoint of a control plane. Connectors use it to talk to each other."""
    return f"http://{participant}-controlplane:8282/api/dsp/2025-1"


def management_api(participant):
    """Control plane Management API (v3), through the ingress."""
    return f"{BASE_URL}/{participant}/cp/management/v3"


def identity_api(participant):
    """Identity hub admin API, scoped to the participant's own context."""
    return f"{BASE_URL}/{participant}/ih/identity/v1alpha/participants/{participant_context(participant)}"


def issuer_admin_api():
    """Issuer service admin API, scoped to the authority's context."""
    return f"{BASE_URL}/authority/is/issueradmin/v1alpha/participants/{participant_context('authority')}"


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def call(method, url, body=None, headers=None, params=None, expect=None, quiet=False):
    """Send one request, print "METHOD path -> status" and return the response.

    expect: status codes considered correct; any other status raises an error.
    quiet:  do not print the request line (used when polling).
    """
    response = requests.request(method, url, json=body, headers=headers, params=params, timeout=60)
    if not quiet:
        print(f"{method:6} {url.replace(BASE_URL, '')}  ->  {response.status_code}")
    if expect is not None and response.status_code not in expect:
        raise RuntimeError(f"expected status {sorted(expect)}, got {response.status_code}: {response.text[:400]}")
    return response


def get(url, **options):
    return call("GET", url, **options)


def post(url, body, **options):
    return call("POST", url, body=body, **options)


def delete(url, **options):
    return call("DELETE", url, **options)


def show(data, max_chars=2000):
    """Pretty-print JSON (or plain text), cut at max_chars."""
    text = data if isinstance(data, str) else json.dumps(data, indent=2)
    if len(text) > max_chars:
        text = text[:max_chars] + "\n... (truncated)"
    print(text)


def as_list(value):
    """JSON-LD returns a single object when there is one element and a list otherwise."""
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def catalog_datasets(catalog):
    """Datasets of a DCAT catalog. Depending on how the JSON-LD was compacted the key is
    "dataset" or "dcat:dataset"; this reads either."""
    return as_list(catalog.get("dataset", catalog.get("dcat:dataset")))


def catalog_owner(catalog):
    """DID of the participant a catalog belongs to ("participantId" or "dspace:participantId")."""
    owner = catalog.get("participantId", catalog.get("dspace:participantId"))
    return owner.get("@id") if isinstance(owner, dict) else owner


# ---------------------------------------------------------------------------
# Waiting for asynchronous processes
# ---------------------------------------------------------------------------

def wait_for_state(read_state, final_states, timeout=90, interval=1):
    """Call read_state() until it returns one of final_states.

    Prints the sequence of states it went through, e.g. "REQUESTED -> FINALIZED".
    """
    states_seen = []
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = read_state()
        if not states_seen or states_seen[-1] != state:
            states_seen.append(state)
        if state in final_states:
            print("   states:", " -> ".join(states_seen))
            return state
        time.sleep(interval)
    raise TimeoutError(f"still in {states_seen[-1]} after {timeout}s (expected one of {final_states})")


def wait_until(description, condition, timeout=90, interval=1):
    """Call condition() until it returns True. description is only used in messages."""
    start = time.time()
    while time.time() - start < timeout:
        if condition():
            print(f"   {description}: yes, after {time.time() - start:.0f}s")
            return
        time.sleep(interval)
    raise TimeoutError(f"{description}: still not true after {timeout}s")


# ---------------------------------------------------------------------------
# Recap of flows already explained step by step in earlier notebooks
# ---------------------------------------------------------------------------

def negotiate(asset_id):
    """Same steps as notebook 04: take the offer from the provider's catalog, send a
    contract request and wait. Returns (negotiation_id, final_state, consumer_agreement_id)."""
    catalog_request = {
        "@context": EDC_CONTEXT,
        "@type": "CatalogRequest",
        "counterPartyAddress": dsp_address("provider"),
        "counterPartyId": did("provider"),
        "protocol": DSP_PROTOCOL,
        "querySpec": {"limit": 500},
    }
    catalog = post(f"{management_api('consumer')}/catalog/request", catalog_request, expect={200}, quiet=True).json()
    dataset = next(d for d in as_list(catalog.get("dataset")) if d["@id"] == asset_id)
    offer = as_list(dataset["hasPolicy"])[0]

    contract_request = {
        "@context": MANAGEMENT_CONTEXT,
        "@type": "ContractRequest",
        "counterPartyAddress": dsp_address("provider"),
        "protocol": DSP_PROTOCOL,
        "policy": {**offer, "assigner": did("provider"), "target": asset_id},
    }
    negotiation_id = post(f"{management_api('consumer')}/contractnegotiations", contract_request, expect={200}).json()["@id"]

    def negotiation_state():
        return get(f"{management_api('consumer')}/contractnegotiations/{negotiation_id}/state", quiet=True).json()["state"]

    state = wait_for_state(negotiation_state, {"FINALIZED", "TERMINATED"})
    negotiation = get(f"{management_api('consumer')}/contractnegotiations/{negotiation_id}", quiet=True).json()
    return negotiation_id, state, negotiation.get("contractAgreementId")


def start_pull_transfer(consumer_agreement_id):
    """Same steps as notebook 05: start an HttpData-PULL transfer and wait until STARTED.
    Returns the consumer's transfer process id."""
    transfer_request = {
        "@context": EDC_CONTEXT,
        "@type": "TransferRequest",
        "counterPartyAddress": dsp_address("provider"),
        "protocol": DSP_PROTOCOL,
        "connectorId": did("provider"),
        "contractId": consumer_agreement_id,
        "transferType": "HttpData-PULL",
    }
    transfer_id = post(f"{management_api('consumer')}/transferprocesses", transfer_request, expect={200}).json()["@id"]

    def transfer_state():
        return get(f"{management_api('consumer')}/transferprocesses/{transfer_id}/state", quiet=True).json()["state"]

    wait_for_state(transfer_state, {"STARTED", "TERMINATED"})
    return transfer_id


def read_data(consumer_agreement_id, **query_params):
    """Read data through the consumer's data gateway. Returns (status_code, body_text)."""
    response = requests.get(
        f"{BASE_URL}/consumer/dp/data",
        params=query_params,
        headers={"Authorization": consumer_agreement_id, "Contract-Id": consumer_agreement_id},
        timeout=30,
    )
    return response.status_code, response.text


# ---------------------------------------------------------------------------
# Kubernetes and Postgres
# ---------------------------------------------------------------------------

def kubectl(*args):
    """Run kubectl against the local kind cluster and return its output."""
    result = subprocess.run(["kubectl", "--context", KUBE_CONTEXT, *args], capture_output=True, text=True)
    return result.stdout + result.stderr


def psql(database, sql):
    """Run one SQL statement inside the postgresql-0 pod and return the raw output."""
    return kubectl("exec", "postgresql-0", "--", "psql", "-U", "postgres", "-d", database, "-Atc", sql).strip()


# ---------------------------------------------------------------------------
# JWT
# ---------------------------------------------------------------------------

def _base64url(raw_bytes):
    return base64.urlsafe_b64encode(raw_bytes).rstrip(b"=").decode()


def make_jwt(claims, secret="a-string-secret-at-least-256-bits-long"):
    """Build an HS256-signed JWT (header.payload.signature)."""
    header = _base64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = _base64url(json.dumps(claims).encode())
    signature = hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
    return f"{header}.{payload}.{_base64url(signature)}"


def _decode_jwt_part(part):
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


def decode_jwt_header(token):
    """Return the header of a JWT (algorithm, key id)."""
    return _decode_jwt_part(token.split(".")[0])


def decode_jwt_payload(token):
    """Return the claims of a JWT without checking its signature."""
    return _decode_jwt_part(token.split(".")[1])


# ---------------------------------------------------------------------------
# Passing ids from one notebook to the next
# ---------------------------------------------------------------------------

STATE_FILE = pathlib.Path(__file__).with_name("tutorial_state.json")


def remember(**values):
    """Save values (asset ids, agreement ids...) for the following notebooks."""
    state = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}
    state.update(values)
    STATE_FILE.write_text(json.dumps(state, indent=2))
    for name, value in values.items():
        print(f"   remembered {name} = {value}")


def recall(name, produced_by):
    """Read a value saved by an earlier notebook."""
    state = json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {}
    if name not in state:
        raise RuntimeError(f"'{name}' not found: run {produced_by} first")
    return state[name]
