#!/bin/bash
#
# Prerequisite Validation Script
# Verifies ZTWIM/SPIRE installation and readiness for PostgreSQL mTLS lab
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

FAILED=0
PASSED=0
WARNINGS=0

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
}

test_case() {
    local description=$1
    shift

    echo -n "  Testing: $description... "

    if "$@" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
        PASSED=$((PASSED+1))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        FAILED=$((FAILED+1))
        return 1
    fi
}

test_warning() {
    local description=$1
    shift

    echo -n "  Checking: $description... "

    if "$@" &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        PASSED=$((PASSED+1))
        return 0
    else
        echo -e "${YELLOW}WARNING${NC}"
        WARNINGS=$((WARNINGS+1))
        return 1
    fi
}

test_command() {
    "$@" &>/dev/null
}

print_header "ZTWIM/SPIRE Prerequisites Validation"

echo -e "${BOLD}OpenShift Security Roadshow - PostgreSQL mTLS Lab${NC}"
echo "This script validates that all prerequisites are met."
echo ""

# Test 1: Cluster Connectivity
print_section "1. Cluster Connectivity"

test_case "OpenShift cluster is accessible" test_command oc cluster-info
test_case "Current user has cluster access" test_command oc whoami

if oc auth can-i create customresourcedefinitions --all-namespaces &>/dev/null; then
    echo -e "  Checking: Cluster-admin privileges... ${GREEN}OK${NC}"
    PASSED=$((PASSED+1))
else
    echo -e "  Checking: Cluster-admin privileges... ${YELLOW}WARNING${NC}"
    echo -e "    ${YELLOW}Note: cluster-admin required for ZTWIM installation${NC}"
    WARNINGS=$((WARNINGS+1))
fi

test_case "Kubernetes API server responding" test_command kubectl cluster-info

echo ""

# Test 2: Required CLI Tools
print_section "2. Required CLI Tools"

test_case "oc CLI available" test_command which oc
test_case "kubectl CLI available" test_command which kubectl
test_case "jq available" test_command which jq

test_warning "helm available (optional)" test_command which helm

echo ""

# Test 3: SPIRE/ZTWIM Installation
print_section "3. SPIRE/ZTWIM Installation"

# Check for SPIRE namespace
if oc get namespace spire &>/dev/null; then
    echo -e "  Checking: SPIRE namespace exists... ${GREEN}OK${NC}"
    PASSED=$((PASSED+1))
    SPIRE_NAMESPACE="spire"
elif oc get namespace ztwim-system &>/dev/null; then
    echo -e "  Checking: ZTWIM namespace exists... ${GREEN}OK${NC}"
    PASSED=$((PASSED+1))
    SPIRE_NAMESPACE="ztwim-system"
else
    echo -e "  Checking: SPIRE/ZTWIM namespace exists... ${RED}FAIL${NC}"
    echo -e "    ${YELLOW}No SPIRE or ZTWIM namespace found${NC}"
    FAILED=$((FAILED+1))
    SPIRE_NAMESPACE="spire"  # default for remaining checks
fi

# Check for SPIRE server
if [ -n "${SPIRE_NAMESPACE:-}" ]; then
    if oc get deployment spire-server -n "$SPIRE_NAMESPACE" &>/dev/null || \
       oc get statefulset spire-server -n "$SPIRE_NAMESPACE" &>/dev/null; then
        echo -e "  Checking: SPIRE server deployed... ${GREEN}OK${NC}"
        PASSED=$((PASSED+1))

        # Check if running
        if oc get pods -n "$SPIRE_NAMESPACE" -l app=spire-server --field-selector=status.phase=Running | grep -q spire-server; then
            echo -e "  Checking: SPIRE server is running... ${GREEN}OK${NC}"
            PASSED=$((PASSED+1))
        else
            echo -e "  Checking: SPIRE server is running... ${RED}FAIL${NC}"
            FAILED=$((FAILED+1))
        fi
    else
        echo -e "  Checking: SPIRE server deployed... ${RED}FAIL${NC}"
        FAILED=$((FAILED+1))
    fi

    # Check for SPIRE agent
    if oc get daemonset spire-agent -n "$SPIRE_NAMESPACE" &>/dev/null; then
        echo -e "  Checking: SPIRE agent deployed... ${GREEN}OK${NC}"
        PASSED=$((PASSED+1))

        # Check if agents are running
        AGENT_COUNT=$(oc get pods -n "$SPIRE_NAMESPACE" -l app=spire-agent --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        if [ "$AGENT_COUNT" -gt 0 ]; then
            echo -e "  Checking: SPIRE agents running ($AGENT_COUNT pods)... ${GREEN}OK${NC}"
            PASSED=$((PASSED+1))
        else
            echo -e "  Checking: SPIRE agents running... ${RED}FAIL${NC}"
            FAILED=$((FAILED+1))
        fi
    else
        echo -e "  Checking: SPIRE agent deployed... ${RED}FAIL${NC}"
        FAILED=$((FAILED+1))
    fi
fi

echo ""

# Test 4: Required CRDs
print_section "4. Required CustomResourceDefinitions"

if oc get crd clusterspiffeids.spire.spiffe.io &>/dev/null; then
    echo -e "  Checking: ClusterSPIFFEID CRD exists... ${GREEN}OK${NC}"
    PASSED=$((PASSED+1))
else
    echo -e "  Checking: ClusterSPIFFEID CRD exists... ${RED}FAIL${NC}"
    echo -e "    ${YELLOW}This CRD is required for the lab${NC}"
    FAILED=$((FAILED+1))
fi

# Check for other SPIFFE-related CRDs (informational)
SPIFFE_CRDS=$(oc get crd 2>/dev/null | grep -i spiffe | wc -l || echo 0)
if [ "$SPIFFE_CRDS" -gt 0 ]; then
    echo -e "  Info: Found $SPIFFE_CRDS SPIFFE-related CRD(s)"
    oc get crd 2>/dev/null | grep -i spiffe | sed 's/^/    /' || true
fi

echo ""

# Test 5: SPIRE Server Configuration
print_section "5. SPIRE Server Configuration"

if [ -n "${SPIRE_NAMESPACE:-}" ] && oc get namespace "$SPIRE_NAMESPACE" &>/dev/null; then
    # Check for SPIRE server service
    if oc get svc spire-server -n "$SPIRE_NAMESPACE" &>/dev/null; then
        echo -e "  Checking: SPIRE server service exists... ${GREEN}OK${NC}"
        PASSED=$((PASSED+1))
    else
        echo -e "  Checking: SPIRE server service exists... ${YELLOW}WARNING${NC}"
        WARNINGS=$((WARNINGS+1))
    fi

    # Check trust domain configuration
    if oc get configmap spire-server -n "$SPIRE_NAMESPACE" &>/dev/null; then
        TRUST_DOMAIN=$(oc get configmap spire-server -n "$SPIRE_NAMESPACE" -o yaml 2>/dev/null | grep trust_domain | head -1 | awk '{print $3}' | tr -d '"' || echo "unknown")
        if [ "$TRUST_DOMAIN" != "unknown" ]; then
            echo -e "  Info: Trust domain configured as: ${BOLD}$TRUST_DOMAIN${NC}"
        else
            echo -e "  Checking: Trust domain configuration... ${YELLOW}WARNING${NC}"
            echo -e "    ${YELLOW}Could not determine trust domain${NC}"
            WARNINGS=$((WARNINGS+1))
        fi
    else
        echo -e "  Checking: SPIRE server ConfigMap... ${YELLOW}WARNING${NC}"
        WARNINGS=$((WARNINGS+1))
    fi
else
    echo -e "  ${YELLOW}Skipping - SPIRE namespace not found${NC}"
fi

echo ""

# Test 6: Image Accessibility
print_section "6. Container Image Accessibility"

# Test spiffe-helper image
echo -e "  Testing spiffe-helper image pull (may take 30s)..."
if timeout 30 oc run test-spiffe-helper-image \
    --image=ghcr.io/spiffe/spiffe-helper:0.6.0 \
    --restart=Never \
    --rm \
    -i \
    --command -- /bin/sh -c "echo success" &>/dev/null; then
    echo -e "    ${GREEN}spiffe-helper image accessible${NC}"
    PASSED=$((PASSED+1))
else
    echo -e "    ${YELLOW}spiffe-helper image not accessible${NC}"
    echo -e "    ${YELLOW}You may need to mirror this image to your internal registry${NC}"
    WARNINGS=$((WARNINGS+1))
    # Cleanup failed pod
    oc delete pod test-spiffe-helper-image --ignore-not-found=true &>/dev/null || true
fi

# Test PostgreSQL image
if timeout 30 oc run test-postgres-image \
    --image=registry.redhat.io/rhel9/postgresql-15:latest \
    --restart=Never \
    --rm \
    -i \
    --command -- /bin/sh -c "echo success" &>/dev/null; then
    echo -e "    ${GREEN}PostgreSQL image accessible${NC}"
    PASSED=$((PASSED+1))
else
    echo -e "    ${YELLOW}PostgreSQL image not accessible${NC}"
    echo -e "    ${YELLOW}You may need authentication to registry.redhat.io${NC}"
    WARNINGS=$((WARNINGS+1))
    # Cleanup failed pod
    oc delete pod test-postgres-image --ignore-not-found=true &>/dev/null || true
fi

echo ""

# Test 7: Cluster Resources
print_section "7. Cluster Resources"

# Check available resources
NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l)
if [ "$NODE_COUNT" -gt 0 ]; then
    echo -e "  Info: Cluster has $NODE_COUNT node(s)"
else
    echo -e "  Checking: Node availability... ${RED}FAIL${NC}"
    FAILED=$((FAILED+1))
fi

# Check for PV support (optional)
test_warning "PersistentVolume support available" bash -c 'test $(oc get pv 2>/dev/null | wc -l) -gt 0 || oc get storageclass --no-headers 2>/dev/null | wc -l | grep -q -v "^0$"'

echo ""

# Summary
print_section "Validation Summary"

echo ""
echo -e "${BOLD}Results:${NC}"
echo -e "  ${GREEN}Passed:   $PASSED${NC}"
echo -e "  ${YELLOW}Warnings: $WARNINGS${NC}"
echo -e "  ${RED}Failed:   $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}${BOLD}✓ All prerequisites met!${NC}"
    echo ""
    echo "You are ready to run the PostgreSQL mTLS lab."
    echo "Next steps:"
    echo "  1. Review the lab guide: docs/lab-201-01-postgresql-spiffe-mtls.adoc"
    echo "  2. Deploy PostgreSQL server: oc apply -f deploy/postgresql-spiffe.yaml"
    echo "  3. Deploy PostgreSQL client: oc apply -f deploy/postgresql-spiffe-client.yaml"
    exit 0
elif [ $FAILED -eq 0 ]; then
    echo -e "${YELLOW}${BOLD}⚠ Prerequisites met with warnings${NC}"
    echo ""
    echo "You can proceed with the lab, but review the warnings above."
    echo "Some optional features may not work as expected."
    echo ""
    echo "Next steps:"
    echo "  1. Review warnings above"
    echo "  2. Review the lab guide: docs/lab-201-01-postgresql-spiffe-mtls.adoc"
    echo "  3. Deploy PostgreSQL server: oc apply -f deploy/postgresql-spiffe.yaml"
    exit 0
else
    echo -e "${RED}${BOLD}✗ Prerequisites not met${NC}"
    echo ""
    echo "Critical requirements are missing. Please address the failures above."
    echo ""
    echo "Common fixes:"
    echo "  • SPIRE not installed: See docs/00-prerequisites.adoc for installation"
    echo "  • CRDs missing: Verify SPIRE installation completed successfully"
    echo "  • SPIRE server not running: Check logs with 'oc logs -n spire -l app=spire-server'"
    echo ""
    echo "For detailed installation instructions:"
    echo "  docs/00-prerequisites.adoc"
    exit 1
fi
