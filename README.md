# OpenShift Security Roadshow - Zero Trust Workload Identity Manager (ZTWIM)

This repository contains hands-on lab materials for learning zero-trust workload identity using SPIFFE/SPIRE on OpenShift.

## Overview

This roadshow module demonstrates how to eliminate password-based database authentication by implementing cryptographic workload identity with automated certificate lifecycle management. Participants will deploy PostgreSQL with SPIFFE-issued certificates and establish mutual TLS (mTLS) authentication between applications and databases.

## What You'll Learn

- Replace static passwords with cryptographic workload identity
- Implement mutual TLS (mTLS) for database connections
- Automate certificate lifecycle with SPIFFE/SPIRE
- Verify certificate-based authentication
- Understand zero-trust security principles for workload-to-workload communication

## Prerequisites

### Required Infrastructure
- OpenShift 4.12+ cluster with cluster-admin access
- Zero Trust Workload Identity Manager (ZTWIM) / SPIRE installed with CRDs
- `oc` CLI tool configured and authenticated

### Installing ZTWIM/SPIRE

**Option 1: Automated Installation (Recommended)**
```bash
# Validate current prerequisites
./scripts/00-validate-prerequisites.sh

# Install SPIRE if not present
./scripts/01-install-spire.sh
```

**Option 2: Manual Installation**

See detailed installation guide: **[docs/00-prerequisites.adoc](docs/00-prerequisites.adoc)**

This covers:
- Multiple installation methods (OperatorHub, direct SPIRE, Helm)
- Trust domain configuration
- Network policies
- Troubleshooting

### Verify ZTWIM/SPIRE Installation
```bash
# Check for required CRDs
oc get crd clusterspiffeids.spire.spiffe.io

# Verify SPIRE components are running
oc get pods -n spire -l app=spire-server
oc get pods -n spire -l app=spire-agent

# Or use the validation script
./scripts/00-validate-prerequisites.sh
```

All checks should pass before proceeding with the lab.

## Repository Structure

```
.
├── README.md                                    # This file
├── docs/
│   ├── 00-prerequisites.adoc                    # ZTWIM/SPIRE installation guide
│   └── lab-201-01-postgresql-spiffe-mtls.adoc  # Complete lab guide (AsciiDoc format)
├── scripts/
│   ├── 00-validate-prerequisites.sh             # Validate ZTWIM/SPIRE installation
│   └── 01-install-spire.sh                      # Automated SPIRE installation
└── deploy/
    ├── postgresql-spiffe.yaml                   # PostgreSQL server with SPIFFE integration
    └── postgresql-spiffe-client.yaml            # PostgreSQL client with SPIFFE integration
```

## Quick Start

### 1. Deploy PostgreSQL Server
```bash
oc apply -f deploy/postgresql-spiffe.yaml
```

This creates:
- Namespace: `postgresql-spiffe`
- PostgreSQL deployment with SPIFFE certificate sidecar
- Service exposing PostgreSQL on port 5432
- ClusterSPIFFEID resource configuring server identity

### 2. Deploy PostgreSQL Client
```bash
oc apply -f deploy/postgresql-spiffe-client.yaml
```

This creates:
- Namespace: `postgresql-spiffe-client`
- Client pod with psql tools and SPIFFE certificate sidecar
- ClusterSPIFFEID resource configuring client identity

### 3. Wait for Pods
```bash
oc wait --for=condition=Ready pod -l app=postgresql-spiffe -n postgresql-spiffe --timeout=120s
oc wait --for=condition=Ready pod -l app=postgresql-spiffe-client -n postgresql-spiffe-client --timeout=120s
```

### 4. Connect with mTLS
```bash
oc rsh -n postgresql-spiffe-client -c postgresql-spiffe-client deployment/postgresql-spiffe-client
```

Inside the pod:
```bash
psql "host=postgresql-spiffe.postgresql-spiffe.svc port=5432 user=postgresql_spiffe dbname=testdb sslmode=verify-full sslcert=/opt/postgresql-certs/svid.pem sslkey=/opt/postgresql-certs/svid.key sslrootcert=/opt/postgresql-certs/svid_bundle.pem"
```

Connection succeeds without password authentication!

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

```bash
oc delete project postgresql-spiffe postgresql-spiffe-client
```

## Credits

Based on the [postgresql-spiffe-demo](https://github.com/SeanRickerd/postgresql-spiffe-demo) by Sean Rickerd.

Adapted for OpenShift Security Roadshow format following [openshift-security-roadshow](https://github.com/mfosterrox/openshift-security-roadshow) conventions.

## Contributing

This repository is part of the OpenShift Security Roadshow series. For questions, issues, or contributions:
- Open an issue in this repository
- Submit a pull request with improvements
- Contact the maintainer

## License

This project is provided as-is for educational purposes.

## Additional Resources

- [SPIFFE Specification](https://github.com/spiffe/spiffe)
- [SPIRE Documentation](https://spiffe.io/docs/latest/spire/)
- [OpenShift Security Documentation](https://docs.openshift.com/container-platform/latest/security/index.html)
- [Zero Trust Architecture (NIST SP 800-207)](https://csrc.nist.gov/publications/detail/sp/800-207/final)
