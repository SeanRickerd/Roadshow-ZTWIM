# OpenShift Security Roadshow - Zero Trust Workload Identity Manager (ZTWIM)

This repository contains hands-on lab materials for learning zero-trust workload identity using SPIFFE/SPIRE on OpenShift.

## Overview

This roadshow module demonstrates how to eliminate password-based database authentication by implementing cryptographic workload identity with automated certificate lifecycle management. Participants will deploy PostgreSQL with SPIFFE-issued certificates and establish mutual TLS (mTLS) authentication between applications and databases.

**Key Features:**
- ✅ Fully portable across ephemeral OpenShift clusters
- ✅ Automatic cluster domain detection
- ✅ Both automated scripts and manual Console UI instructions
- ✅ Uses SPIFFE CSI Driver (no privileged SCC required)
- ✅ Tested on fresh clusters (~8 minute deployment)
- ✅ Production-ready with comprehensive troubleshooting

## What You'll Learn

- Replace static passwords with cryptographic workload identity
- Implement mutual TLS (mTLS) for database connections
- Automate certificate lifecycle with SPIFFE/SPIRE
- Verify certificate-based authentication
- Understand zero-trust security principles for workload-to-workload communication

## Prerequisites

### Required Infrastructure
- OpenShift 4.12+ cluster with cluster-admin access
- `oc` CLI tool configured and authenticated
- Internet connectivity (for pulling images and installing operators)

### Installing ZTWIM Operator

The Zero Trust Workload Identity Manager (ZTWIM) operator must be installed before deploying PostgreSQL with SPIFFE certificates.

**Option 1: Automated Installation (Recommended for CLI users)**
```bash
# Install ZTWIM operator with automatic cluster detection
./scripts/00-install-ztwim-operator.sh
```

This script will:
- Auto-detect your cluster domain (e.g., `apps.cluster-abc.example.com`)
- Install ZTWIM operator from Red Hat OperatorHub
- Configure SPIRE server, agents, and CSI driver
- Set trust domain based on detected cluster domain
- Verify all components are running

**Time to complete:** ~5 minutes

**Option 2: Manual Installation via OpenShift Console**

For step-by-step instructions using the OpenShift web console:

See the **Prerequisites** section in: **[docs/lab-201-01-postgresql-spiffe-mtls.adoc](docs/lab-201-01-postgresql-spiffe-mtls.adoc#prerequisites-install-zero-trust-workload-identity-manager)**

This includes:
- OperatorHub installation walkthrough
- Creating 5 SPIRE custom resources (ZeroTrustWorkloadIdentityManager, SpireServer, SpireAgent, SpiffeCSIDriver, SpireOIDCDiscoveryProvider)
- Cluster domain detection instructions
- Console UI navigation paths
- Screenshots placeholders for future updates

**Time to complete:** ~10-15 minutes (first-time manual setup)

### Verify ZTWIM Installation

After installation (automated or manual), verify all components are running:

```bash
# Check SPIRE server (should show 2/2 Running)
oc get pods -n openshift-zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-server

# Check SPIRE agents (should show 1 pod per node, all Running)
oc get pods -n openshift-zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-agent

# Check CSI driver (should show 1 pod per node, all Running)
oc get pods -n openshift-zero-trust-workload-identity-manager -l app.kubernetes.io/name=spire-spiffe-csi-driver

# Verify CSI driver is registered
oc get csidriver csi.spiffe.io

# Check ClusterSPIFFEID CRD exists
oc get crd clusterspiffeids.spire.spiffe.io
```

All checks should pass before proceeding with the lab.

## Repository Structure

```
.
├── README.md                                    # This file
├── DEPLOYMENT.md                                # Quick deployment guide with architecture diagrams
├── docs/
│   ├── 00-prerequisites.adoc                    # ZTWIM/SPIRE installation guide (legacy reference)
│   └── lab-201-01-postgresql-spiffe-mtls.adoc  # Complete lab guide (AsciiDoc format)
├── scripts/
│   ├── 00-install-ztwim-operator.sh             # Automated ZTWIM operator installation (NEW)
│   ├── 00-validate-prerequisites.sh             # Validate ZTWIM/SPIRE installation
│   ├── 01-install-spire.sh                      # Manual SPIRE installation (deprecated - use operator)
│   └── 02-install-spiffe-csi-driver.sh          # Manual CSI driver installation (deprecated - use operator)
└── deploy/
    ├── postgresql-spiffe.yaml                   # PostgreSQL server with SPIFFE integration
    └── postgresql-spiffe-client.yaml            # PostgreSQL client with SPIFFE integration
```

**Recommended Files:**
- **New users:** Start with `DEPLOYMENT.md` for quick overview
- **Lab participants:** Follow `docs/lab-201-01-postgresql-spiffe-mtls.adoc`
- **Automated deployment:** Use `scripts/00-install-ztwim-operator.sh`

## Quick Start

**Prerequisites:** ZTWIM operator must be installed (see [Prerequisites](#prerequisites) section above)

### 1. Deploy PostgreSQL Server
```bash
# Deploy PostgreSQL with SPIFFE integration
oc apply -f deploy/postgresql-spiffe.yaml

# Configure namespace for anyuid SCC (required for postgres UID 26)
oc label namespace postgresql-spiffe \
  security.openshift.io/scc.podSecurityLabelSync=false \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite

# Grant anyuid SCC to ServiceAccount
oc adm policy add-scc-to-user anyuid -z postgresql-spiffe -n postgresql-spiffe
```

This creates:
- Namespace: `postgresql-spiffe`
- ServiceAccount: `postgresql-spiffe`
- PostgreSQL deployment with spiffe-helper init container and sidecar
- Service exposing PostgreSQL on port 5432
- ClusterSPIFFEID resource configuring server identity
- ConfigMaps for PostgreSQL configuration and initialization

**Architecture:**
- **Init container**: `spiffe-helper-init` - Fetches initial certificates before PostgreSQL starts
- **Main container**: `postgresql-spiffe` - PostgreSQL database with SSL enabled
- **Sidecar container**: `spiffe-helper` - Continuously rotates certificates and reloads PostgreSQL

### 2. Deploy PostgreSQL Client
```bash
# Deploy client with SPIFFE integration
oc apply -f deploy/postgresql-spiffe-client.yaml

# Configure namespace for anyuid SCC
oc label namespace postgresql-spiffe-client \
  security.openshift.io/scc.podSecurityLabelSync=false \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite

# Grant anyuid SCC to ServiceAccount
oc adm policy add-scc-to-user anyuid -z postgresql-spiffe-client -n postgresql-spiffe-client
```

This creates:
- Namespace: `postgresql-spiffe-client`
- ServiceAccount: `postgresql-spiffe-client`
- Client pod with psql tools and spiffe-helper sidecar
- ClusterSPIFFEID resource configuring client identity (CN=`postgresql_spiffe` matches database user)

### 3. Wait for Pods to be Ready
```bash
# Wait for PostgreSQL server
oc wait --for=condition=Ready pod -l app=postgresql-spiffe -n postgresql-spiffe --timeout=120s

# Wait for client
oc wait --for=condition=Ready pod -l app=postgresql-spiffe-client -n postgresql-spiffe-client --timeout=120s
```

### 4. Test mTLS Connection

**One-line test:**
```bash
oc rsh -n postgresql-spiffe-client -c postgresql-spiffe-client deployment/postgresql-spiffe-client \
  psql "host=postgresql-spiffe.postgresql-spiffe.svc port=5432 user=postgresql_spiffe dbname=testdb sslmode=verify-full sslcert=/opt/postgresql-certs/svid.pem sslkey=/opt/postgresql-certs/svid.key sslrootcert=/opt/postgresql-certs/svid_bundle.pem" \
  -c "SELECT current_user, current_database();"
```

**Expected output:**
```
   current_user    | current_database
-------------------+------------------
 postgresql_spiffe | testdb
(1 row)
```

**Interactive session:**
```bash
# Open shell in client pod
oc rsh -n postgresql-spiffe-client -c postgresql-spiffe-client deployment/postgresql-spiffe-client

# Inside the pod, connect with full certificate authentication
psql "host=postgresql-spiffe.postgresql-spiffe.svc port=5432 user=postgresql_spiffe dbname=testdb sslmode=verify-full sslcert=/opt/postgresql-certs/svid.pem sslkey=/opt/postgresql-certs/svid.key sslrootcert=/opt/postgresql-certs/svid_bundle.pem"
```

Connection succeeds **without password authentication**!

### 5. Verify SPIFFE Identities

```bash
# Check client SPIFFE ID
oc rsh -n postgresql-spiffe-client -c postgresql-spiffe-client deployment/postgresql-spiffe-client \
  openssl x509 -in /opt/postgresql-certs/svid.pem -noout -text | grep "URI:spiffe"

# Check server SPIFFE ID
oc rsh -n postgresql-spiffe -c postgresql-spiffe deployment/postgresql-spiffe \
  openssl x509 -in /opt/postgresql-certs/svid.pem -noout -text | grep "URI:spiffe"
```

Each workload receives a unique SPIFFE ID based on its Kubernetes identity (namespace + service account).

## Lab Guide

For the complete hands-on lab experience with detailed explanations, security context, and verification steps, see:

**[docs/lab-201-01-postgresql-spiffe-mtls.adoc](docs/lab-201-01-postgresql-spiffe-mtls.adoc)**

The lab guide includes:
- Security rationale and threat modeling
- Step-by-step instructions with verification
- Certificate inspection and validation
- Attack scenario demonstrations
- CIS and MITRE ATT&CK framework mappings
- FAQs and troubleshooting

## Key Security Concepts

### Zero-Trust Workload Identity
Workloads prove their identity using cryptographic certificates issued by SPIFFE, not network location or static credentials.

### Mutual TLS (mTLS)
Both client and server verify each other's identity using X.509 certificates:
- **Client → Server**: Client verifies server's certificate matches expected identity
- **Server → Client**: Server verifies client's certificate and maps CN to database user

### Automatic Certificate Rotation
SPIFFE issues short-lived certificates (typically 1 hour) and automatically rotates them before expiration. No manual intervention or application downtime required.

### Identity Binding
PostgreSQL maps the certificate Common Name (CN) to the database username, enforcing identity at the TLS layer:
- Server certificate CN: `postgresql-spiffe.postgresql-spiffe.svc` (hostname)
- Client certificate CN: `postgresql_spiffe` (database username)

## Attack Scenarios Mitigated

| Attack Type | Traditional Auth | SPIFFE mTLS |
|-------------|------------------|-------------|
| **Credential Theft** | Stolen password = persistent access | Certificate expires in ~1 hour |
| **Lateral Movement** | Password works from any compromised pod | Requires valid SPIFFE attestation |
| **Man-in-the-Middle** | No server verification | Mutual certificate validation |
| **Brute Force** | Password can be guessed/sprayed | No password to attack |
| **Replay Attacks** | Static credentials replayable | Certificates cryptographically bound to workload |

## Cleanup

### Quick Cleanup (PostgreSQL only)
```bash
# Delete PostgreSQL deployments
oc delete project postgresql-spiffe postgresql-spiffe-client
```

### Selective Cleanup (Keep ZTWIM for other labs)
```bash
# Delete only PostgreSQL resources
oc delete -f deploy/postgresql-spiffe-client.yaml
oc delete -f deploy/postgresql-spiffe.yaml
```

### Complete Cleanup (Remove ZTWIM operator)
```bash
# Delete PostgreSQL deployments
oc delete project postgresql-spiffe postgresql-spiffe-client

# Delete SPIRE custom resources
oc delete spireoidcdiscoveryprovider cluster
oc delete spiffecsidriver cluster
oc delete spireagent cluster
oc delete spireserver cluster
oc delete zerotrustworkloadidentitymanager cluster

# Delete ZTWIM operator namespace
oc delete project openshift-zero-trust-workload-identity-manager
```

**Note:** Complete cleanup removes ZTWIM for all workloads. Only use if you're certain no other applications depend on it.

## Portability Features

This module is designed to work seamlessly on **ephemeral OpenShift clusters** used in lab and workshop environments:

✅ **Automatic Cluster Detection**
- Script auto-detects cluster domain (e.g., `apps.cluster-abc.example.com`)
- Trust domain configured dynamically based on detected domain
- No hardcoded cluster-specific values

✅ **CSI Driver Integration**
- Uses SPIFFE CSI Driver for workload API socket access
- No `hostPath` volumes required
- No `privileged` SCC needed (only `anyuid` for postgres UID)

✅ **Operator-Managed SPIRE**
- Red Hat ZTWIM operator handles SPIRE lifecycle
- Automatic updates and maintenance
- Production-ready with support

✅ **Tested on Fresh Clusters**
- Validated on ephemeral workshop clusters
- ~8 minute total deployment time
- All components verified working end-to-end

✅ **Comprehensive Documentation**
- Both CLI scripts and Console UI paths
- Detailed troubleshooting for common issues
- Ready for screenshot insertion

## Time to Deploy

- **Fresh cluster with automation**: ~8 minutes total
  - ZTWIM installation: ~5 minutes
  - PostgreSQL deployment: ~2 minutes
  - Client deployment + testing: ~1 minute

- **Fresh cluster with manual steps**: ~15-20 minutes total
  - ZTWIM manual installation: ~10-15 minutes
  - PostgreSQL deployment: ~5 minutes

- **Existing ZTWIM cluster**: ~3 minutes
  - PostgreSQL + client deployment: ~3 minutes

## Credits

Based on the [postgresql-spiffe-demo](https://github.com/SeanRickerd/postgresql-spiffe-demo) by Sean Rickerd.

Adapted for OpenShift Security Roadshow format following [openshift-security-roadshow](https://github.com/mfosterrox/openshift-security-roadshow) conventions.

**Tested on:**
- OpenShift 4.20 (ROSA)
- Zero Trust Workload Identity Manager Operator v1.0.0
- SPIRE 1.9.0 (managed by operator)

## Troubleshooting

Common issues and solutions are documented in the lab guide:

**[docs/lab-201-01-postgresql-spiffe-mtls.adoc - Troubleshooting Section](docs/lab-201-01-postgresql-spiffe-mtls.adoc#troubleshooting)**

Quick diagnostics:

```bash
# Check SPIRE components
oc get pods -n openshift-zero-trust-workload-identity-manager

# Check PostgreSQL pods
oc get pods -n postgresql-spiffe
oc get pods -n postgresql-spiffe-client

# View pod events
oc get events -n postgresql-spiffe --sort-by='.lastTimestamp' | tail -20

# Check certificate generation
oc rsh -n postgresql-spiffe -c postgresql-spiffe deployment/postgresql-spiffe \
  ls -la /opt/postgresql-certs/
```

For detailed troubleshooting including CSI volume issues, certificate problems, and permission errors, see the comprehensive troubleshooting guide in the lab documentation.

## Contributing

This repository is part of the OpenShift Security Roadshow series. For questions, issues, or contributions:
- Open an issue in this repository
- Submit a pull request with improvements
- Contact the maintainer

## License

This project is provided as-is for educational purposes.

## Additional Resources

### SPIFFE/SPIRE
- [SPIFFE Specification](https://github.com/spiffe/spiffe)
- [SPIRE Documentation](https://spiffe.io/docs/latest/spire/)
- [SPIFFE CSI Driver](https://github.com/spiffe/spiffe-csi)

### OpenShift
- [OpenShift Security Documentation](https://docs.openshift.com/container-platform/latest/security/index.html)
- [Red Hat Zero Trust Workload Identity Manager](https://access.redhat.com/documentation/en-us/red_hat_openshift_service_mesh/)
- [OpenShift Security Context Constraints](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)

### Zero Trust & Security Frameworks
- [Zero Trust Architecture (NIST SP 800-207)](https://csrc.nist.gov/publications/detail/sp/800-207/final)
- [CIS Kubernetes Benchmarks](https://www.cisecurity.org/benchmark/kubernetes)
- [MITRE ATT&CK Framework](https://attack.mitre.org/)

### PostgreSQL Security
- [PostgreSQL SSL Certificates](https://www.postgresql.org/docs/current/ssl-tcp.html)
- [PostgreSQL Client Authentication](https://www.postgresql.org/docs/current/client-authentication.html)
- [PostgreSQL Certificate Authentication](https://www.postgresql.org/docs/current/auth-cert.html)
