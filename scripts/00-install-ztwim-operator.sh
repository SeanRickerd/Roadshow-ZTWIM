#!/bin/bash
#
# ZTWIM Operator Installation Script for OpenShift
# Installs Zero Trust Workload Identity Manager operator and configures SPIRE components
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-zero-trust-workload-identity-manager}"
INSTALL_MODE="${1:-full}"

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BLUE}${BOLD}▶ $1${NC}"
    echo -e "${BLUE}  $(printf '─%.0s' {1..60})${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

check_prerequisites() {
    print_section "Checking Prerequisites"

    # Check cluster access
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift cluster"
        exit 1
    fi
    print_success "Logged into OpenShift cluster as $(oc whoami)"

    # Check cluster-admin
    if ! oc auth can-i create subscriptions --all-namespaces &>/dev/null; then
        print_error "cluster-admin privileges required"
        echo "Current user: $(oc whoami)"
        echo "Please login as cluster-admin or request elevated privileges"
        exit 1
    fi
    print_success "cluster-admin privileges verified"

    # Check if ZTWIM is already installed
    if oc get subscription openshift-zero-trust-workload-identity-manager -n "$OPERATOR_NAMESPACE" &>/dev/null; then
        print_info "ZTWIM operator subscription already exists"
        if [ "$INSTALL_MODE" != "force" ]; then
            echo ""
            read -p "ZTWIM may already be installed. Continue anyway? (yes/no) [no]: " response
            response=${response:-no}
            if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
                echo "Installation cancelled"
                exit 0
            fi
        fi
    fi
}

detect_cluster_config() {
    print_section "Detecting Cluster Configuration"

    # Get cluster domain for trust domain
    CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
    if [ -z "$CLUSTER_DOMAIN" ]; then
        print_error "Failed to detect cluster domain"
        exit 1
    fi
    print_success "Cluster domain: $CLUSTER_DOMAIN"

    # Set trust domain (use cluster domain)
    TRUST_DOMAIN="$CLUSTER_DOMAIN"
    print_success "Trust domain: $TRUST_DOMAIN"

    # Get cluster name
    CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' | cut -d'-' -f1)
    if [ -z "$CLUSTER_NAME" ]; then
        CLUSTER_NAME="cluster"
        print_info "Using default cluster name: $CLUSTER_NAME"
    else
        print_success "Cluster name: $CLUSTER_NAME"
    fi

    export CLUSTER_DOMAIN TRUST_DOMAIN CLUSTER_NAME
}

install_operator() {
    print_section "Installing ZTWIM Operator"

    # Create namespace
    if oc get namespace "$OPERATOR_NAMESPACE" &>/dev/null; then
        print_info "Namespace $OPERATOR_NAMESPACE already exists"
    else
        cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $OPERATOR_NAMESPACE
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
        print_success "Created namespace: $OPERATOR_NAMESPACE"
    fi

    # Create OperatorGroup
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: zero-trust-workload-identity-manager
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces:
  - $OPERATOR_NAMESPACE
EOF
    print_success "OperatorGroup created"

    # Create Subscription
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-zero-trust-workload-identity-manager
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-zero-trust-workload-identity-manager
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    print_success "Subscription created"

    print_info "Waiting for operator to install..."
    sleep 10

    # Wait for CSV to be successful
    timeout=180
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        CSV_NAME=$(oc get subscription openshift-zero-trust-workload-identity-manager -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        if [ -n "$CSV_NAME" ]; then
            CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                print_success "Operator installed successfully: $CSV_NAME"
                break
            fi
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ $elapsed -ge $timeout ]; then
        print_error "Timeout waiting for operator installation"
        exit 1
    fi
}

configure_spire() {
    print_section "Configuring SPIRE Components"

    # Create ZeroTrustWorkloadIdentityManager
    cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: $TRUST_DOMAIN
  clusterName: $CLUSTER_NAME
  bundleConfigMap: spire-bundle
EOF
    print_success "ZeroTrustWorkloadIdentityManager created"

    # Create SpireServer
    cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  caSubject:
    commonName: redhat.com
    country: US
    organization: Red Hat
  persistence:
    size: 5Gi
    accessMode: ReadWriteOnce
  datastore:
    databaseType: sqlite3
    connectionString: /run/spire/data/datastore.sqlite3
  jwtIssuer: https://spire-spiffe-oidc-discovery-provider.$CLUSTER_DOMAIN
EOF
    print_success "SpireServer created"

    # Create SpireAgent
    cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec:
  nodeAttestor:
    k8sPSATEnabled: "true"
  workloadAttestors:
    k8sEnabled: "true"
    workloadAttestorsVerification:
      type: auto
EOF
    print_success "SpireAgent created"

    # Create SpiffeCSIDriver
    cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec:
  agentSocketPath: /run/spire/agent-sockets
EOF
    print_success "SpiffeCSIDriver created"

    # Create SpireOIDCDiscoveryProvider
    cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
spec:
  jwtIssuer: https://spire-spiffe-oidc-discovery-provider.$CLUSTER_DOMAIN
  managedRoute: "true"
EOF
    print_success "SpireOIDCDiscoveryProvider created"
}

wait_for_ready() {
    print_section "Waiting for Components to be Ready"

    echo "Waiting for SPIRE server..."
    oc wait --for=condition=Ready pod -l app.kubernetes.io/name=spire-server -n "$OPERATOR_NAMESPACE" --timeout=300s
    print_success "SPIRE server is ready"

    echo "Waiting for SPIRE agents..."
    timeout=180
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        READY=$(oc get daemonset -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=spire-agent -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
        DESIRED=$(oc get daemonset -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=spire-agent -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        if [ "$READY" -gt 0 ] && [ "$READY" = "$DESIRED" ]; then
            print_success "SPIRE agents are ready ($READY/$DESIRED)"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "Waiting for CSI driver..."
    timeout=180
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        READY=$(oc get daemonset -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=spire-spiffe-csi-driver -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
        DESIRED=$(oc get daemonset -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=spire-spiffe-csi-driver -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        if [ "$READY" -gt 0 ] && [ "$READY" = "$DESIRED" ]; then
            print_success "CSI driver is ready ($READY/$DESIRED)"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
}

verify_installation() {
    print_section "Verifying Installation"

    # Check operator
    if oc get deployment -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=zero-trust-workload-identity-manager &>/dev/null; then
        print_success "ZTWIM operator deployed"
    else
        print_error "ZTWIM operator not found"
    fi

    # Check SPIRE server
    SERVER_COUNT=$(oc get pods -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=spire-server --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [ "$SERVER_COUNT" -gt 0 ]; then
        print_success "SPIRE server running ($SERVER_COUNT pod)"
    else
        print_error "SPIRE server not running"
    fi

    # Check SPIRE agents
    AGENT_COUNT=$(oc get pods -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=spire-agent --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [ "$AGENT_COUNT" -gt 0 ]; then
        print_success "SPIRE agents running ($AGENT_COUNT pods)"
    else
        print_error "SPIRE agents not running"
    fi

    # Check CSI driver
    CSI_COUNT=$(oc get pods -n "$OPERATOR_NAMESPACE" -l app.kubernetes.io/name=spire-spiffe-csi-driver --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [ "$CSI_COUNT" -gt 0 ]; then
        print_success "CSI driver running ($CSI_COUNT pods)"
    else
        print_error "CSI driver not running"
    fi

    # Check CSI driver registration
    if oc get csidriver csi.spiffe.io &>/dev/null; then
        print_success "CSI driver registered with Kubernetes"
    else
        print_error "CSI driver not registered"
    fi

    # Print configuration
    echo ""
    echo -e "${BOLD}Configuration saved:${NC}"
    echo "  Trust Domain: $TRUST_DOMAIN"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Apps Domain:  $CLUSTER_DOMAIN"
}

# Main execution
main() {
    print_header "ZTWIM Operator Installation for OpenShift"

    check_prerequisites
    detect_cluster_config

    echo ""
    echo -e "${BOLD}Configuration:${NC}"
    echo "  Operator Namespace: $OPERATOR_NAMESPACE"
    echo "  Trust Domain:       $TRUST_DOMAIN"
    echo "  Cluster Name:       $CLUSTER_NAME"
    echo ""

    install_operator
    configure_spire
    wait_for_ready
    verify_installation

    print_header "Installation Complete"

    echo -e "${GREEN}${BOLD}✓ ZTWIM installation successful!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Deploy PostgreSQL: oc apply -f deploy/postgresql-spiffe.yaml"
    echo "  2. Deploy client: oc apply -f deploy/postgresql-spiffe-client.yaml"
    echo ""
    echo "Quick verification:"
    echo "  oc get pods -n $OPERATOR_NAMESPACE"
    echo "  oc get csidriver csi.spiffe.io"
    echo ""
    echo "Configuration:"
    echo "  Trust Domain: $TRUST_DOMAIN"
    echo "  Cluster Name: $CLUSTER_NAME"
}

# Show usage
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<EOF
Usage: $0 [mode]

Modes:
  full    - Install ZTWIM operator and configure SPIRE (default)
  force   - Install even if operator exists

Environment Variables:
  OPERATOR_NAMESPACE  - Namespace for ZTWIM operator (default: openshift-zero-trust-workload-identity-manager)

Examples:
  $0                                      # Standard installation
  $0 force                                # Force reinstall
  OPERATOR_NAMESPACE=ztwim $0             # Use custom namespace

Prerequisites:
  • OpenShift 4.12+
  • cluster-admin privileges
  • oc CLI authenticated
  • Access to Red Hat Operator catalog

What this script does:
  1. Detects cluster domain automatically
  2. Installs ZTWIM operator from OperatorHub
  3. Creates and configures SPIRE components
  4. Verifies installation

For detailed documentation, see:
  docs/00-prerequisites.adoc
EOF
    exit 0
fi

main
