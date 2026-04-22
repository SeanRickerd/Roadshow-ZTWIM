# OpenShift Security Roadshow - ZTWIM Module Deployment Guide

## Quick Start for Fresh Cluster

This module is designed to work on **ephemeral OpenShift clusters**. Follow these steps to deploy on a brand new cluster:

### Prerequisites

- OpenShift 4.12 or later
- `oc` CLI authenticated with cluster-admin privileges
- Internet connectivity for operator installation

### Step 1: Install ZTWIM Operator (5 minutes)

```bash
cd Roadshow-ZTWIM
./scripts/00-install-ztwim-operator.sh
```

This script will:
- Auto-detect your cluster's domain
- Install the Zero Trust Workload Identity Manager operator
- Configure SPIRE server, agents, and CSI driver
- Verify all components are running

**Expected output:**
```
✓ SPIRE server running (1 pod)
✓ SPIRE agents running (N pods)
✓ CSI driver running (N pods)
✓ CSI driver registered with Kubernetes

Trust Domain: apps.<your-cluster-domain>
Cluster Name: <detected>
```

### Step 2: Deploy PostgreSQL with SPIFFE mTLS (2 minutes)

```bash
oc apply -f deploy/postgresql-spiffe.yaml
```

Wait for the deployment to be ready:
```bash
oc wait --for=condition=Ready pod -l app=postgresql-spiffe -n postgresql-spiffe --timeout=120s
```

### Step 3: Deploy PostgreSQL Client (1 minute)

```bash
oc apply -f deploy/postgresql-spiffe-client.yaml
```

Wait for the client to be ready:
```bash
oc wait --for=condition=Ready pod -l app=postgresql-spiffe-client -n postgresql-spiffe-client --timeout=120s
```

### Step 4: Test mTLS Connection

```bash
# Get client pod name
CLIENT_POD=$(oc get pods -n postgresql-spiffe-client -o jsonpath='{.items[0].metadata.name}')

# Test connection with mTLS
oc exec -n postgresql-spiffe-client $CLIENT_POD -c postgresql-spiffe-client -- \
  psql "postgresql://postgresql_spiffe@postgresql-spiffe.postgresql-spiffe.svc:5432/testdb?sslmode=verify-full&sslcert=/opt/postgresql-certs/svid.pem&sslkey=/opt/postgresql-certs/svid.key&sslrootcert=/opt/postgresql-certs/svid_bundle.pem" \
  -c "SELECT current_user, current_database();"
```

**Expected output:**
```
   current_user    | current_database 
-------------------+------------------
 postgresql_spiffe | testdb
(1 row)
```

### Step 5: Verify SPIFFE Identities

```bash
# Check client SPIFFE ID
oc exec -n postgresql-spiffe-client $CLIENT_POD -c postgresql-spiffe-client -- \
  openssl x509 -in /opt/postgresql-certs/svid.pem -noout -text | grep "URI:spiffe"

# Check server SPIFFE ID  
SERVER_POD=$(oc get pods -n postgresql-spiffe -o jsonpath='{.items[0].metadata.name}')
oc exec -n postgresql-spiffe $SERVER_POD -c postgresql-spiffe -- \
  openssl x509 -in /opt/postgresql-certs/svid.pem -noout -text | grep "URI:spiffe"
```

**Expected output:**
```
URI:spiffe://<your-domain>/ns/postgresql-spiffe-client/sa/postgresql-spiffe-client
URI:spiffe://<your-domain>/ns/postgresql-spiffe/sa/postgresql-spiffe
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      OpenShift Cluster                       │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │         ZTWIM Operator (cluster-scoped)              │  │
│  │  • SPIRE Server (identity issuer)                    │  │
│  │  • SPIRE Agent (DaemonSet on each node)              │  │
│  │  • SPIFFE CSI Driver (mounts workload API socket)    │  │
│  └──────────────────────────────────────────────────────┘  │
│                            │                                 │
│                            ▼                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │        postgresql-spiffe namespace                   │  │
│  │                                                       │  │
│  │  ┌────────────────────────────────────────────┐     │  │
│  │  │   PostgreSQL Server Pod                    │     │  │
│  │  │                                             │     │  │
│  │  │  • CSI volume → /spiffe-workload-api/      │     │  │
│  │  │  • spiffe-helper fetches X.509 certs       │     │  │
│  │  │  • PostgreSQL configured with ssl=on        │     │  │
│  │  │  • pg_hba.conf requires client cert         │     │  │
│  │  │                                             │     │  │
│  │  │  SPIFFE ID: spiffe://domain/ns/.../sa/...  │     │  │
│  │  └────────────────────────────────────────────┘     │  │
│  └──────────────────────────────────────────────────────┘  │
│                            │                                 │
│                            │ mTLS                            │
│                            ▼                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │     postgresql-spiffe-client namespace              │  │
│  │                                                       │  │
│  │  ┌────────────────────────────────────────────┐     │  │
│  │  │   Client Pod                                │     │  │
│  │  │                                             │     │  │
│  │  │  • CSI volume → /spiffe-workload-api/      │     │  │
│  │  │  • spiffe-helper fetches X.509 certs       │     │  │
│  │  │  • psql connects with client cert           │     │  │
│  │  │                                             │     │  │
│  │  │  SPIFFE ID: spiffe://domain/ns/.../sa/...  │     │  │
│  │  └────────────────────────────────────────────┘     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Security Features

### Zero Trust Workload Identity
- **Automatic identity assignment** based on Kubernetes workload attributes
- **Short-lived X.509 certificates** (1 hour TTL, auto-rotated)
- **No secrets, tokens, or passwords** stored in pods or ConfigMaps
- **SPIFFE standard** for portable identity across platforms

### Mutual TLS (mTLS)
- **Server authentication**: Client verifies server identity via certificate
- **Client authentication**: Server verifies client identity via certificate  
- **Encryption in transit**: All database traffic encrypted
- **Certificate-based authorization**: PostgreSQL pg_hba.conf enforces cert requirement

### Attack Surface Reduction
- **No password-based authentication** to compromise
- **No static credentials** to leak or steal
- **Identity theft requires** compromising SPIRE infrastructure (not just a pod)
- **Network encryption** prevents man-in-the-middle attacks

## Troubleshooting

### ZTWIM Operator Installation Issues

```bash
# Check operator status
oc get csv -n openshift-zero-trust-workload-identity-manager

# Check operator logs
oc logs -n openshift-zero-trust-workload-identity-manager \
  deployment/zero-trust-workload-identity-manager-operator --tail=50
```

### SPIRE Component Issues

```bash
# Check SPIRE server status
oc get pods -n openshift-zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-server

# Check SPIRE agent status
oc get pods -n openshift-zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent

# Check CSI driver status
oc get csidriver csi.spiffe.io
oc get pods -n openshift-zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-spiffe-csi-driver
```

### PostgreSQL Deployment Issues

```bash
# Check PostgreSQL pod status
oc get pods -n postgresql-spiffe
oc describe pod -n postgresql-spiffe <pod-name>

# Check spiffe-helper init container logs
oc logs -n postgresql-spiffe <pod-name> -c spiffe-helper-init

# Check PostgreSQL container logs
oc logs -n postgresql-spiffe <pod-name> -c postgresql-spiffe --tail=50

# Check if certificates are present
oc exec -n postgresql-spiffe <pod-name> -c postgresql-spiffe -- \
  ls -la /opt/postgresql-certs/
```

### Connection Issues

```bash
# Verify client can see certificates
oc exec -n postgresql-spiffe-client <client-pod> -c postgresql-spiffe-client -- \
  ls -la /opt/postgresql-certs/

# Test without mTLS (should fail)
oc exec -n postgresql-spiffe-client <client-pod> -c postgresql-spiffe-client -- \
  psql "postgresql://postgresql_spiffe@postgresql-spiffe.postgresql-spiffe.svc:5432/testdb" \
  -c "SELECT 1;"
# Expected: FATAL: connection requires a valid client certificate

# Test with mTLS (should succeed)
oc exec -n postgresql-spiffe-client <client-pod> -c postgresql-spiffe-client -- \
  psql "postgresql://postgresql_spiffe@postgresql-spiffe.postgresql-spiffe.svc:5432/testdb?sslmode=verify-full&sslcert=/opt/postgresql-certs/svid.pem&sslkey=/opt/postgresql-certs/svid.key&sslrootcert=/opt/postgresql-certs/svid_bundle.pem" \
  -c "SELECT 1;"
# Expected: Success
```

## Cleanup

To remove all components:

```bash
# Delete PostgreSQL deployments
oc delete -f deploy/postgresql-spiffe-client.yaml
oc delete -f deploy/postgresql-spiffe.yaml

# Delete ZTWIM operator resources
oc delete spireoidcdiscoveryprovider cluster
oc delete spiffecsidriver cluster
oc delete spireagent cluster
oc delete spireserver cluster
oc delete zerotrustworkloadidentitymanager cluster

# Uninstall operator (optional)
oc delete subscription openshift-zero-trust-workload-identity-manager \
  -n openshift-zero-trust-workload-identity-manager
oc delete csv $(oc get csv -n openshift-zero-trust-workload-identity-manager -o name) \
  -n openshift-zero-trust-workload-identity-manager
oc delete namespace openshift-zero-trust-workload-identity-manager
```

## What Makes This Portable

✅ **Automatic cluster detection** - Script detects cluster domain automatically  
✅ **CSI driver volumes** - No privileged SCC or hostPath required  
✅ **Operator-managed** - Red Hat operator handles SPIRE lifecycle  
✅ **No hardcoded values** - Trust domain configured dynamically  
✅ **Standard OpenShift** - Works on any OpenShift 4.12+ cluster  
✅ **Self-contained** - All dependencies included in operator

## Time to Deploy

- **Fresh cluster setup**: ~8 minutes total
  - Operator installation: ~5 minutes
  - PostgreSQL deployment: ~2 minutes
  - Client deployment: ~1 minute

- **Teardown and redeploy**: ~3 minutes
  - Cleanup: ~1 minute
  - Redeploy: ~2 minutes

## References

- [SPIFFE/SPIRE Documentation](https://spiffe.io/docs/)
- [OpenShift ZTWIM Operator](https://access.redhat.com/documentation/en-us/red_hat_openshift_service_mesh/)
- [PostgreSQL SSL Certificates](https://www.postgresql.org/docs/current/ssl-tcp.html)
- [SPIFFE CSI Driver](https://github.com/spiffe/spiffe-csi)
