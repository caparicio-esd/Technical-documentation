# Architecture and flow diagrams

Diagrams of the local MVD deployed by `deploy-local-mvd.sh`: who the actors are, how the pieces fit together, and what happens on the wire in every flow listed in [FLOWS.md](FLOWS.md). The flow numbers (A4, D1, E6…) match that document. The terms are defined in the [Glossary](#glossary) at the end.

All of this reflects what was observed in the running cluster (2026-10-09, `dataspace-ecosystem@e0c5200`, EDC 0.16, TLS off).

**Contents**

1. [High-level architecture](#1-high-level-architecture)
2. [Actors](#2-actors)
3. [Component interaction map](#3-component-interaction-map)
4. [Trust model](#4-trust-model)
5. [Bootstrap: what happens on `up`](#5-bootstrap-what-happens-on-up)
6. [Onboarding: credential types and participants](#6-onboarding-credential-types-and-participants)
7. [Credential issuance (DCP)](#7-credential-issuance-dcp)
8. [Credential presentation inside every DSP call](#8-credential-presentation-inside-every-dsp-call)
9. [Publishing](#9-publishing)
10. [Discovery](#10-discovery)
11. [Contract negotiation](#11-contract-negotiation)
12. [Transfer and data access](#12-transfer-and-data-access)
13. [Agreement lifecycle: expiry, retirement, reactivation](#13-agreement-lifecycle-expiry-retirement-reactivation)
14. [Telemetry and billing](#14-telemetry-and-billing)
15. [Visible vs. negotiable: the policy decision](#15-visible-vs-negotiable-the-policy-decision)
16. [Glossary](#glossary)

---

## 1. High-level architecture

### Level 1: the dataspace

```mermaid
graph LR
    YOU(["You<br/>curl · notebook · E2E"])
    NGINX["ingress-nginx<br/>127.0.0.1:80/443 · host localhost"]
    C["<b>Consumer</b><br/>controlplane · dataplane + gateway<br/>identityhub · telemetryagent · vault"]
    P["<b>Provider</b><br/>controlplane · dataplane · identityhub<br/>telemetryagent · vault · backend"]
    A["<b>Authority</b><br/>issuerservice · identityhub<br/>federated catalog + filter<br/>telemetry service · storage · CSV · vault"]
    I[("<b>Shared infra</b><br/>postgresql · eventhubs · azurite")]

    YOU --> NGINX
    NGINX --> C
    NGINX --> P
    NGINX --> A
    C <-->|"DSP: catalog · negotiation · transfer<br/>DCP: tokens + presentations"| P
    C -->|"data pull (EDR)"| P
    C -->|"get VCs · filtered catalog"| A
    P -->|"get VCs · status list"| A
    A -->|"crawl catalogs every 10 s"| P
    C -->|"telemetry"| I
    P -->|"telemetry"| I
    A -->|"billing · storage"| I
    YOU -. "port-forward :57521 · :52717" .-> I
```

### Level 2: inside one participant (provider and consumer are identical, plus the provider backend)

```mermaid
graph LR
    subgraph PART["participant p"]
        CP["p-controlplane<br/>8181 management · 8282 DSP · 8383 control"]
        DP["p-dataplane<br/>8181 public · 8282 data gateway · 8383 control"]
        IH["p-identityhub<br/>8181 identity · 8282 credentials · 8383 DID · 8484 STS"]
        TA["p-telemetryagent"]
        V[("p-vault<br/>secret/ kv-v2")]
        DB[("postgres: database of p")]
    end
    CP -->|"selects data plane"| DP
    CP -->|"STS token"| IH
    CP --> V
    DP --> V
    IH --> V
    CP --> DB
    DP -->|"writes consumption records"| DB
    IH --> DB
    TA -->|"reads consumption records"| DB
```

Section 3 has the full call map with ports.

The deployment has three layers:

| Layer | What lives there |
| --- | --- |
| **Trust / governance** (Authority) | Who belongs to the dataspace (issuer + credentials), what exists in it (federated catalog), and who used what (telemetry/billing) |
| **Sovereign participants** (Provider, Consumer) | One EDC connector each (control plane + data plane), one wallet (identity hub) and one Vault, all separate per participant |
| **Shared infra** | One Postgres server (one database per tenant), Azure emulators for telemetry and blob storage |

---

## 2. Actors

| Actor | Kind | Represented by | Does |
| --- | --- | --- | --- |
| **Dataspace operator** | Human | You, calling the issuer admin API | Defines credential types, registers participants, attests membership/domain/visibility |
| **Provider** (organisation) | Human + system | You via `/provider/cp/management`; `provider-*` pods | Publishes assets, policies and contract offers, serves data, can retire agreements |
| **Consumer** (organisation) | Human + system | You via `/consumer/cp/management` and `/consumer/dp/data`; `consumer-*` pods | Discovers, negotiates, transfers and consumes data |
| **Consumer application** | System | You, or any HTTP client | Reads data through the consumer data gateway with an agreement id |
| **Issuer** | System | `authority-issuerservice` | Evaluates attestations and signs Verifiable Credentials |
| **Wallet** | System | `<p>-identityhub` | Holds a participant's DID, keys (via Vault) and VCs; issues self-signed tokens (STS); presents VCs |
| **Federated catalog** | System | `authority-federatedcatalog` (+ filter) | Crawls every registered participant and serves a searchable, credential-filtered catalog |
| **Telemetry agent** | System | `<p>-telemetryagent` | Ships data-consumption records to the event broker |
| **Billing** | System | telemetry service / storage / CSV manager | Turns consumption records into monthly per-participant CSV reports |
| **Data backend** | External system | `provider-backend` | The real API behind an asset (normal, OAuth2-protected, failing) |
| **Secret store** | System | `<p>-vault` | Private keys, AES keys, STS client secrets, backend credentials |

---

## 3. Component interaction map

Every arrow is an in-cluster HTTP call between Kubernetes services in namespace `default`. Port and API context are shown on each arrow.

```mermaid
graph LR
    CCP[consumer-controlplane] -- ":8282 /api/dsp<br/>catalog · negotiation · transfer" --> PCP[provider-controlplane]
    PCP -- ":8282 /api/dsp callbacks" --> CCP
    CCP -- ":8484 /api/sts/token" --> CIH[consumer-identityhub]
    PCP -- ":8484 /api/sts/token" --> PIH[provider-identityhub]
    PCP -- ":8383 did.json · :8282 presentation query" --> CIH
    CCP -- ":8383 did.json · :8282 presentation query" --> PIH
    PCP -- ":9999 status list" --> IS[authority-issuerservice]
    CCP -- ":9999 status list" --> IS
    CIH -- ":8282 /api/issuance (DCP)" --> IS
    IS -- ":8282 /api/credentials (DCP delivery)" --> CIH
    PCP -- ":8383 /api/control (data plane selector)" --> PDP[provider-dataplane]
    CCP -- ":8383 /api/control" --> CDP[consumer-dataplane]
    CDP -- ":8181 /api/public (EDR token)" --> PDP
    PDP -- ":8080" --> BE[provider-backend]
    FC[authority-federatedcatalog] -- ":8282 DSP catalog request every 10 s" --> PCP
    FC -- ":8282" --> CCP
    CCP -- ":8383 /filter" --> FCF[authority-federatedcatalogfilter]
    FCF --> FC
    CTA[consumer-telemetryagent] -- ":8181 /api/credential sas-token" --> TS[authority-telemetryservice]
    CTA -- ":5672 AMQP" --> EH[(eventhubs)]
    PCP & PDP & PIH & CCP & CDP & CIH -- ":8200" --> V[("own vault")]
    PCP & CCP & IS & FC -- ":5432 jdbc" --> PG[(postgres)]
```

Port convention in every EDC runtime: `8080` health (`/api/check/liveness|readiness`), `8181` management/identity/public, `8282` protocol/credentials/data, `8383` control/did, `8484` STS/onboarding, `9999` status list (issuer only).

---

## 4. Trust model

```mermaid
graph TB
    subgraph Keys["Key material (generated by Terraform tls_private_key, ECDSA P-256)"]
        K1["vault: authority / authority-pub"]
        K2["vault: provider / provider-pub"]
        K3["vault: consumer / consumer-pub"]
    end

    ADID["did:web:authority-identityhub%3A8383:api:did<br/>services: IssuerService, FederatedCatalogService,<br/>TelemetryServiceCredential, CredentialService"]
    PDID["did:web:provider-identityhub%3A8383:api:did<br/>services: CredentialService, DSPMessaging"]
    CDID["did:web:consumer-identityhub%3A8383:api:did<br/>services: CredentialService, DSPMessaging"]

    K1 --> ADID
    K2 --> PDID
    K3 --> CDID

    ADID -- "signs (JWT VC)" --> VC1["MembershipCredential<br/>name, membershipType, since, companySegment"]
    ADID -- "signs" --> VC2["DomainCredential<br/>domain = route"]
    ADID -- "signs" --> VC3["VisibilityCredential<br/>visibility_scope = ALL"]

    VC1 & VC2 & VC3 -- "held in wallet of" --> PDID & CDID

    PDID -. "trusts as only issuer<br/>(edc.iam.trusted-issuer.authority.id)" .-> ADID
    CDID -. "trusts" .-> ADID
```

- Identity is a **did:web** DID per participant. The DID document is served by the participant's own identity hub at `http://<p>-identityhub:8383/api/did/did.json`, so it only resolves inside the cluster.
- Trust is **one level deep**: the authority is the only trusted issuer, and every policy decision is made on credentials it signed.
- The authority holds credentials too (its own Membership/Domain), because it is also crawled and queried.

---

## 5. Bootstrap: what happens on `up`

```mermaid
sequenceDiagram
    autonumber
    participant S as deploy-local-mvd.sh
    participant D as Docker / Gradle container
    participant K as kind node
    participant T as Terraform
    participant H as Helm (via Terraform)
    participant J as Init jobs
    participant R as EDC runtimes

    S->>K: kind create cluster (ingress-ready, 127.0.0.1:80/443)
    S->>K: apply ingress-nginx, wait for controller
    S->>D: ./gradlew clean shadowJar dockerize (JDK 17 container)
    D-->>S: 11 images {name}:latest
    S->>K: docker tag localhost/{name}, kind load docker-image (both names)
    S->>T: terraform init, destroy, apply (environment=local, tls_enabled=false)
    T->>K: secret postgresql, statefulset postgresql
    T->>J: {p}-db-init: CREATE USER, CREATE DATABASE (x3 + billing)
    T->>H: vault chart 0.28.1 per participant (standalone, storage inmem)
    H->>J: {p}-vault-init-job: operator init (1 key), unseal, kv-v2 at secret/, token "root"
    H->>J: {p}-vault-keygen-job: put {p}, {p}-pub, {p}-aes
    T->>H: control-plane, data-plane, identity-hub, telemetry-agent (provider, consumer)
    T->>H: identity-hub, issuer-service, federated-catalog(+filter), telemetry-* (authority)
    T->>K: eventhubs + azurite statefulsets, blob container jobs, provider-backend
    H->>R: pods start, schemas auto-created (EDC_SQL_SCHEMA_AUTOCREATE)
    R->>R: identity hubs seed participant context (super-user, key alias {p}), publish DID doc
    S->>K: wait until every pod Ready/Completed
    S->>K: port-forward postgresql-0:5432, eventhubs-0:5672
```

At this point nobody holds any credential yet. Until Block A runs, every policy will fail (no MembershipCredential).

---

## 6. Onboarding: credential types and participants

Flows **A1–A3**: the operator prepares the issuer.

```mermaid
sequenceDiagram
    autonumber
    actor Op as Operator
    participant IS as authority-issuerservice (issueradmin)
    participant DB as authoritydb

    Op->>IS: POST /attestations (membership: json-database, table membership_attestation)
    Op->>IS: POST /credentialdefinitions (MembershipCredential, mappings, JWT, 10y)
    Op->>IS: POST /attestations (domain: database, table domain_attestation)
    Op->>IS: POST /credentialdefinitions (DomainCredential, mapping domain)
    IS->>DB: store definitions
    loop for provider, consumer, authority
        Op->>IS: POST /holders {did, holderId, name}
        IS->>DB: holder row (also the crawl list for the federated catalog)
        Op->>IS: POST /attestation-membership {name, membershipType FullMember, companySegment}
        Op->>IS: POST /attestation-domain {domain route}
        IS-->>Op: 204
        Op->>IS: POST /attestation-domain {domain travel}
        IS-->>Op: 403 (issuer only authorised for "route")
    end
```

---

## 7. Credential issuance (DCP)

Flow **A4**: each participant asks its own wallet to fetch a credential from the issuer.

```mermaid
sequenceDiagram
    autonumber
    actor P as Participant admin
    participant IH as {p}-identityhub
    participant STS as {p} STS (:8484)
    participant IS as authority-issuerservice
    participant AIH as authority DID doc

    P->>IH: POST /identity/.../credentials/request {issuerDid, holderPid, [{format, type, id}]}
    IH-->>P: 201 (HolderCredentialRequest CREATED)
    IH->>AIH: resolve issuer DID, find IssuerService endpoint
    IH->>STS: self-issued token (iss = sub = holder DID, aud = issuer DID)
    IH->>IS: DCP CredentialRequestMessage (+ token) → REQUESTED
    IS->>IS: verify token against holder DID doc
    IS->>IS: run attestations (membership / domain rows) → claims
    IS->>IS: map claims to credentialSubject, sign JWT VC with key "authority", add status-list entry
    Note over IS: IssuanceProcess APPROVED
    IS->>IH: DCP CredentialMessage to holder CredentialService (:8282)
    Note over IS: IssuanceProcess DELIVERED
    IH->>IH: store VC, HolderCredentialRequest ISSUED
    P->>IH: GET /credentials → JWT VCs
```

State machines involved:

```mermaid
stateDiagram-v2
    direction LR
    state "HolderCredentialRequest (wallet)" as H {
        [*] --> CREATED
        CREATED --> REQUESTING
        REQUESTING --> REQUESTED
        REQUESTED --> ISSUED
        REQUESTED --> ERROR
    }
    state "IssuanceProcess (issuer)" as I {
        [*] --> APPROVED: attestations OK
        APPROVED --> DELIVERED: credential delivered (state 200)
        APPROVED --> APPROVED: delivery retry (up to 7)
        APPROVED --> ERRORED: retries exhausted (state 300)
    }
```

If the request descriptor uses `credentialType` instead of `type`, the issuer stays in the APPROVED→APPROVED retry loop until ERRORED, with an empty failure cause (see FLOWS.md, gotcha 1).

---

## 8. Credential presentation inside every DSP call

This runs underneath every catalog, negotiation and transfer request in Blocks C–E. It is how the provider learns *who* is asking and *which credentials* they hold.

```mermaid
sequenceDiagram
    autonumber
    participant CCP as consumer-controlplane
    participant CSTS as consumer STS (:8484)
    participant CIH as consumer-identityhub (:8282 / :8383)
    participant PCP as provider-controlplane
    participant IS as authority-issuerservice (:9999)

    CCP->>CSTS: client credentials (client_id = consumer DID, secret from vault) + scopes
    CSTS-->>CCP: self-issued ID token (contains access token for consumer's CredentialService)
    CCP->>PCP: DSP message (catalog / contract request / transfer) + Authorization: ID token
    PCP->>CIH: resolve did:web consumer → did.json (verification key, CredentialService URL)
    PCP->>PCP: verify ID token signature
    PCP->>CIH: DCP presentation query (scope: MembershipCredential, DomainCredential, ...)
    CIH-->>PCP: Verifiable Presentation (JWT VCs)
    PCP->>PCP: check VC issuer == trusted authority DID, signatures, expiry
    PCP->>IS: fetch status list credential → not revoked
    PCP->>PCP: evaluate ODRL policy against VC claims (section 15)
    PCP-->>CCP: DSP response (catalog / agreement / transfer start) or rejection
```

---

## 9. Publishing

Flows **B1–B7**, provider side only. Nothing leaves the provider yet.

```mermaid
sequenceDiagram
    autonumber
    actor Pr as Provider admin
    participant CP as provider-controlplane (management :8181)
    participant V as provider-vault
    participant DB as providerdb

    opt backend needs credentials (OAuth2, Azure)
        Pr->>CP: POST /v3/secrets {id, value}
        CP->>V: kv put secret/{id}
    end
    Pr->>CP: POST /v3/assets {properties (DCAT ...), dataAddress {type HttpData, baseUrl, oauth2:* ...}}
    Pr->>CP: POST /v3/policydefinitions {permission use + constraints (dse-policy:Membership, GenericClaim, RestrictedDiscoveryClaim, inForceDate)}
    Pr->>CP: POST /v3/contractdefinitions {accessPolicyId, contractPolicyId, assetsSelector}
    CP->>DB: assets, policies, contract definitions
    Note over CP: offers become visible in the next DSP catalog response<br/>and in the federated catalog after the next crawl (≤10 s)
```

An entry is the triple asset + policy definition + contract definition:

```mermaid
graph LR
    A["Asset<br/>id, properties, dataAddress"] -- "selected by<br/>assetsSelector" --> CD["Contract definition"]
    CD -- "accessPolicyId<br/>(who sees the offer)" --> P1["Policy definition"]
    CD -- "contractPolicyId<br/>(what the agreement says)" --> P2["Policy definition"]
```

---

## 10. Discovery

### 10.1 Federated catalog crawl and credential-filtered query (C2–C6)

```mermaid
sequenceDiagram
    autonumber
    participant FC as authority-federatedcatalog
    participant IS as issuer holders
    participant PCP as provider-controlplane
    participant CCP as consumer-controlplane
    participant FCF as authority-federatedcatalogfilter
    actor C as Consumer admin

    loop every 10 s (EDC_CATALOG_CACHE_EXECUTION_PERIOD_SECONDS)
        FC->>IS: list holders (participant-registry-node-directory)
        FC->>PCP: DSP catalog request (authority credentials)
        FC->>CCP: DSP catalog request
        FC->>FC: cache catalogs (federatedcatalog DB)
    end

    C->>CCP: POST /cp/management/v1alpha/catalog/query {QuerySpec}
    CCP->>CCP: resolve authority DID → FederatedCatalogService / filter URL
    CCP->>CCP: self-issued token, scope VerifiableCredential:read, aud = authority
    CCP->>FCF: POST /filter {token, did, querySpec}
    FCF->>FCF: fetch consumer VCs, evaluate RestrictedDiscoveryClaim per dataset
    FCF->>FC: query cache (filter / sort / limit / offset)
    FCF-->>CCP: catalogs with only the datasets the consumer may see
    CCP-->>C: one catalog per crawled participant
```

`POST /authority/catalog/v1alpha/catalog/query` (C2) skips the filter and queries the cache directly.

### 10.2 Direct DSP catalog (C1)

```mermaid
sequenceDiagram
    autonumber
    actor C as Consumer admin
    participant CCP as consumer-controlplane
    participant PCP as provider-controlplane
    C->>CCP: POST /v3/catalog/request {counterPartyAddress, counterPartyId, protocol}
    CCP->>PCP: DSP CatalogRequestMessage (+ DCP token, section 8)
    PCP->>PCP: evaluate access policies of every contract definition
    PCP-->>CCP: DCAT catalog: datasets + offers (hasPolicy) the consumer qualifies for
    CCP-->>C: catalog JSON-LD
```

---

## 11. Contract negotiation

Flows **D1–D5**.

```mermaid
sequenceDiagram
    autonumber
    actor C as Consumer admin
    participant CCP as consumer-controlplane
    participant PCP as provider-controlplane

    C->>CCP: POST /v3/contractnegotiations {offer + assigner + target, counterPartyAddress}
    CCP-->>C: negotiation id (REQUESTING)
    CCP->>PCP: DSP ContractRequestMessage (+ DCP, section 8)
    PCP->>PCP: evaluate contract policy (Membership, GenericClaim...)
    alt policy satisfied
        PCP->>CCP: ContractAgreementMessage (provider stores agreement id P)
        CCP->>PCP: ContractAgreementVerificationMessage
        PCP->>CCP: ContractNegotiationEventMessage FINALIZED
        Note over CCP,PCP: shared DSP agreementId A, local ids differ: consumer C, provider P
        C->>CCP: GET /v3/contractnegotiations/{id} → contractAgreementId = C
    else policy not satisfied / credential missing
        PCP->>CCP: ContractNegotiationTerminationMessage
        Note over CCP: TERMINATED (D2, D3, D4)
    end
    opt D5
        C->>CCP: DELETE /v3/contractnegotiations/{id} → 204, then 404
    end
```

```mermaid
stateDiagram-v2
    direction LR
    [*] --> REQUESTING
    REQUESTING --> REQUESTED
    REQUESTED --> AGREED: provider agrees
    AGREED --> VERIFYING
    VERIFYING --> VERIFIED
    VERIFIED --> FINALIZED
    REQUESTED --> TERMINATED: policy fails
    FINALIZED --> [*]
    TERMINATED --> [*]
```

Simplified view: the provider also passes through AGREEING and FINALIZING. States are stored as numeric codes in the database (`1200` = FINALIZED, `1400` = TERMINATED).

---

## 12. Transfer and data access

### 12.1 HTTP pull through the consumer data gateway (E1–E3, E7, E9)

```mermaid
sequenceDiagram
    autonumber
    actor C as Consumer admin
    actor App as Consumer app
    participant CCP as consumer-controlplane
    participant PCP as provider-controlplane
    participant PDP as provider-dataplane
    participant CDP as consumer-dataplane (data gateway :8282 /api/data)
    participant BE as provider-backend

    C->>CCP: POST /v3/transferprocesses {contractId C, transferType HttpData-PULL}
    CCP->>PCP: DSP TransferRequestMessage (+ DCP)
    PCP->>PCP: check agreement + policy still valid
    PCP->>PDP: start data flow (control API :8383)
    PDP-->>PCP: EDR (endpoint http://provider-dataplane:8181/api/public, token signed with key "provider")
    PCP->>CCP: TransferStartMessage + EDR
    CCP->>CCP: store EDR, transfer STARTED
    App->>CDP: GET /consumer/dp/data/{path}?q (Authorization: C, Contract-Id: C)
    CDP->>CDP: find latest EDR whose agreementId = C
    CDP->>PDP: same method/path/query/body + EDR token + Contract-Id
    PDP->>PDP: verify token (provider-pub), resolve source data address
    opt OAuth2 data address (E2)
        PDP->>BE: POST /api/oauth2/token (client secret from vault)
    end
    PDP->>BE: call baseUrl (+ proxied query params)
    BE-->>App: payload streamed back (or 500 propagated, E3)
    Note over PDP,CDP: both data planes record consumption (section 14)
```

### 12.2 Push to blob storage (E4)

```mermaid
sequenceDiagram
    autonumber
    actor C as Consumer admin
    participant CCP as consumer-controlplane
    participant PCP as provider-controlplane
    participant PDP as provider-dataplane
    participant AZ as azurite-blobstorage

    Note over PCP,CCP: secrets {account} and {account}-key1 stored in both vaults
    C->>CCP: POST /v3/transferprocesses {transferType AzureStorage-PUSH, dataDestination {AzureStorage, account, container, blobName, keyName}}
    CCP->>PCP: DSP TransferRequestMessage + destination
    PCP->>PDP: start flow
    PDP->>AZ: read source blob (container src)
    PDP->>AZ: write blob to destination container
    PDP-->>PCP: done
    PCP->>CCP: TransferCompletionMessage
    Note over CCP: COMPLETED
```

### 12.3 Transfer states

```mermaid
stateDiagram-v2
    direction LR
    [*] --> INITIAL
    INITIAL --> PROVISIONING
    PROVISIONING --> PROVISIONED
    PROVISIONED --> REQUESTING
    REQUESTING --> REQUESTED
    REQUESTED --> STARTED: pull: EDR received
    STARTED --> COMPLETED: push finished
    STARTED --> TERMINATED: agreement expired / retired / terminate call
    STARTED --> SUSPENDED
    SUSPENDED --> STARTED
    COMPLETED --> [*]
    TERMINATED --> [*]
```

---

## 13. Agreement lifecycle: expiry, retirement, reactivation

Flows **E5** and **E6**.

```mermaid
sequenceDiagram
    autonumber
    actor Pr as Provider admin
    participant PCP as provider-controlplane
    participant CCP as consumer-controlplane
    participant CDP as consumer data gateway
    actor App as Consumer app

    rect rgba(128,128,128,0.08)
    Note over PCP: E5 — policy inForceDate lteq contractAgreement+20s
    PCP->>PCP: policy monitor: agreement no longer in force
    PCP->>CCP: TransferTerminationMessage
    CCP->>CCP: transfer TERMINATED, EDR removed
    App->>CDP: GET data → 403
    end

    rect rgba(128,128,128,0.08)
    Note over Pr: E6 — retirement uses the PROVIDER's agreement id
    Pr->>PCP: POST /v3/transferprocesses/request {correlationId = consumer transfer id} → contractId P
    Pr->>PCP: POST /v3/contractagreements/retirements {edc:agreementId P, dse:reason}
    PCP->>CCP: TransferTerminationMessage
    App->>CDP: GET data → 403 "No EDR satisfying criterion"
    Pr->>PCP: DELETE /v3/contractagreements/retirements/P (reactivate)
    Note over CCP: old transfer stays TERMINATED
    CCP->>PCP: new TransferRequestMessage (same agreement C)
    App->>CDP: GET data → 200
    end
```

---

## 14. Telemetry and billing

Flows **F1–F7**.

```mermaid
sequenceDiagram
    autonumber
    participant DP as provider & consumer data planes
    participant TA as {p}-telemetryagent
    participant TS as authority-telemetryservice
    participant EH as eventhubs (eh1, 2 partitions, cg1)
    participant ING as ingestion (prod: Azure Function · here: E2E @AfterAll)
    participant TST as authority-telemetrystorage
    participant CSV as authority-telemetrycsvmanager
    participant AZ as azurite-report-storage
    actor U as Participant (billing)

    DP->>DP: DataConsumptionRecord {contractId, responseSize} per served request
    loop periodically
        TA->>TS: GET /v1alpha/sas-token (token signed by participant DID)
        TS->>TS: participant onboarded? sign SAS with event-hub-connection-string (authority vault)
        TS-->>TA: SAS token
        TA->>EH: publish records (AMQP)
    end
    ING->>EH: consume events
    ING->>TST: POST /telemetry-events {contractId, participantId, responseStatusCode, msgSize, timestamp}
    TST->>TST: billingdb
    U->>CSV: POST /billing-reports {participantName, month, year}
    CSV->>TST: read billingdb, cross-check both sides of each contract
    CSV->>AZ: store CSV
    U->>CSV: GET /billing-reports?month&year (Bearer JWT roles Participant.{name})
    CSV-->>U: text/csv (contract_id, counterparty_name, status, kB, events)
```

Locally, nothing plays the ingestion role (step 6) unless the E2E suite runs. The CSV manager checks the role claim but **not the JWT signature**.

---

## 15. Visible vs. negotiable: the policy decision

How the DSE policy functions decide, for one consumer and one dataset:

```mermaid
flowchart TD
    Q["Consumer asks for catalog / negotiation"] --> M{"Valid MembershipCredential<br/>from the authority?<br/>(dse-policy:Membership)"}
    M -- no --> X1["Invisible and not negotiable"]
    M -- yes --> R{"Dataset has<br/>RestrictedDiscoveryClaim?"}
    R -- no --> VIS["Visible in catalog"]
    R -- yes --> RV{"Claim matches?<br/>or VisibilityCredential scope ALL"}
    RV -- no --> X2["Hidden from catalog<br/>(C4)"]
    RV -- yes --> VIS
    VIS --> N["Contract request"]
    N --> G{"All GenericClaim /<br/>RestrictedDiscovery claims<br/>match actual VCs?"}
    G -- no --> T["TERMINATED<br/>(D2, D3, D4)"]
    G -- yes --> F{"inForceDate<br/>still valid?"}
    F -- no --> T2["Transfer TERMINATED (E5)"]
    F -- yes --> OK["FINALIZED → transfer allowed"]
```

D4 in one sentence: a VisibilityCredential lets you *see* a restricted asset, but you still need the matching DomainCredential to *contract* it.

---

## Glossary

| Term | Meaning in this environment |
| --- | --- |
| **Agreement (contract agreement)** | Result of a FINALIZED negotiation. Both sides share the DSP `agreementId`, but each stores the agreement under **its own local `@id`**. The data gateway expects the consumer's `@id`; retirement expects the provider's `@id` |
| **Asset** | A data offering registered in a control plane: properties (DCAT metadata) plus a data address saying where the data really is |
| **Attestation** | A source of facts the issuer checks before issuing a credential (membership table, domain table, visibility table) |
| **Attestation definition** | Issuer config saying where an attestation is read from (`json-database` or `database`, table, column) |
| **Authority** | The dataspace operator's set of services: issuer, authority identity hub, federated catalog, telemetry/billing |
| **Azurite** | Microsoft's local emulator for Azure Storage (blob/queue/table). Three instances here |
| **CaaS** | Connector-as-a-Service: one dedicated connector per participant, operated for them |
| **Catalog (DCAT)** | List of datasets with offers that a provider returns over DSP |
| **Contract definition** | Links assets (via `assetsSelector`) to an access policy and a contract policy |
| **Control plane** | EDC runtime that manages assets, policies, negotiations and transfer processes; speaks DSP |
| **Credential definition** | Issuer config for a credential type: attestations used, claim mappings, format (JWT), validity |
| **CredentialService** | DID-document service of a wallet where credentials are delivered (DCP storage) and presented (DCP presentation) |
| **Data address** | Where and how the provider data plane reads the data (`HttpData` + `baseUrl`, `AzureStorage` + container…) |
| **Data gateway** | DSE data-plane API on the consumer (`/consumer/dp/data`) that resolves the EDR for an agreement and proxies the request to the provider |
| **Data plane** | EDC runtime that moves the actual bytes (public API for pull, push to sinks) |
| **DataConsumptionRecord** | Per-request record (contract id, response size) written by data planes for billing |
| **DCP** | Decentralized Claims Protocol: how wallets request credentials from issuers and present them to verifiers |
| **DID / did:web** | Decentralized identifier. `did:web:host%3Aport:path` resolves to `http(s)://host:port/path/did.json` |
| **DID document** | JSON with a participant's public keys and service endpoints |
| **Domain** | DSE claim (`route`, `travel`) used for business-domain restrictions. This issuer may only attest `route` |
| **DSE** | Amadeus "Dataspace Ecosystem" extensions on top of EDC (policies, catalog filter, telemetry, retirement…) |
| **DSP** | Dataspace Protocol (version `2025-1` here): catalog, negotiation and transfer messages between connectors |
| **EDC** | Eclipse Dataspace Components: the Java framework every runtime here is built on (0.16) |
| **EDR** | Endpoint Data Reference: endpoint + short-lived token the consumer gets to pull data for one transfer |
| **Event Hubs emulator** | Microsoft's local emulator for Azure Event Hubs; the telemetry event broker here |
| **Federated catalog** | Authority service that crawls every registered participant every 10 s and caches their catalogs |
| **Federated catalog filter** | Authority service that only returns datasets the caller's credentials allow |
| **Holder** | A participant registered in the issuer; also the crawl list of the federated catalog |
| **holderPid** | Id the wallet chooses for a credential request; the issuer echoes it back on delivery |
| **Identity Hub (IH)** | Wallet runtime: DID document, key pairs (via Vault), credentials, STS |
| **inForceDate** | ODRL constraint limiting how long an agreement is valid (`contractAgreement+20s`) |
| **Issuance process** | Issuer-side record of one credential request: APPROVED → DELIVERED / ERRORED |
| **Issuer Service** | Authority runtime that evaluates attestations and signs VCs; also serves the revocation status list |
| **JSON-LD** | JSON with `@context`; every EDC management/DSP payload is JSON-LD, so namespaces matter |
| **kind** | Kubernetes-in-Docker: the local single-node cluster |
| **Management API** | Control-plane admin API (`/cp/management/v3`); no auth in this setup |
| **MembershipCredential** | VC proving dataspace membership (name, type, since, companySegment). Required by every policy |
| **MVD** | Minimum Viable Dataspace: the smallest complete dataspace (authority + provider + consumer) |
| **ODRL** | Open Digital Rights Language: policy model (permission, action `use`, constraints) |
| **Participant context** | Identity-hub tenant record per DID, seeded at boot with admin role and key alias |
| **Policy definition** | Stored ODRL policy referenced by contract definitions |
| **Policy monitor** | Control-plane loop that terminates transfers when an agreement stops being in force |
| **Presentation (VP)** | Set of VCs a wallet hands to a verifier, wrapped and signed by the holder |
| **RestrictedDiscoveryClaim** | DSE constraint that hides a dataset from the catalog unless the claim matches |
| **GenericClaim** | DSE constraint that checks any claim of any credential type with a JSON path |
| **Retirement** | DSE feature: the provider revokes an agreement without deleting it; reversible |
| **SAS token** | Azure Shared Access Signature; what telemetry agents use to publish to Event Hub |
| **Status list** | Revocation list served by the issuer (`:9999/api/statuslist`), checked when verifying VCs |
| **STS** | Secure Token Service inside each identity hub; issues the self-signed tokens used in DCP |
| **Telemetry agent** | Per-participant runtime that ships consumption records to the event broker |
| **Transfer process** | Control-plane record of one data transfer (pull or push) and its state |
| **Transfer type** | `HttpData-PULL`, `AzureStorage-PUSH`… |
| **Vault** | HashiCorp Vault, one per participant, KV v2 at `secret/`, root token `root`, in-memory storage |
| **VC** | Verifiable Credential: signed claims (JWT format here) about a holder |
| **VisibilityCredential** | DSE VC (`visibility_scope = ALL`) that widens catalog visibility without granting access |
