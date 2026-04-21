#!/bin/bash
#
# SPIRE Installation Script for OpenShift
# Installs SPIRE server and agent for ZTWIM functionality
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

SPIRE_NAMESPACE="${SPIRE_NAMESPACE:-spire}"
TRUST_DOMAIN="${TRUST_DOMAIN:-cluster.local}"
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
    if ! oc auth can-i create customresourcedefinitions --all-namespaces &>/dev/null; then
        print_error "cluster-admin privileges required"
        echo "Current user: $(oc whoami)"
        echo "Please login as cluster-admin or request elevated privileges"
        exit 1
    fi
    print_success "cluster-admin privileges verified"

    # Check if SPIRE is already installed
    if oc get namespace "$SPIRE_NAMESPACE" &>/dev/null; then
        print_info "SPIRE namespace already exists"
        if [ "$INSTALL_MODE" != "force" ]; then
            echo ""
            read -p "SPIRE may already be installed. Continue anyway? (yes/no) [no]: " response
            response=${response:-no}
            if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
                echo "Installation cancelled"
                exit 0
            fi
        fi
    fi
}

create_namespace() {
    print_section "Creating SPIRE Namespace"

    if oc get namespace "$SPIRE_NAMESPACE" &>/dev/null; then
        print_info "Namespace $SPIRE_NAMESPACE already exists"
    else
        oc create namespace "$SPIRE_NAMESPACE"
        print_success "Created namespace: $SPIRE_NAMESPACE"
    fi

    # Label namespace
    oc label namespace "$SPIRE_NAMESPACE" \
        security.openshift.io/scc.podSecurityLabelSync=false \
        pod-security.kubernetes.io/enforce=privileged \
        pod-security.kubernetes.io/audit=privileged \
        pod-security.kubernetes.io/warn=privileged \
        --overwrite
    print_success "Namespace labeled for SPIRE workloads"
}

install_crds() {
    print_section "Installing SPIRE CRDs"

    cat <<EOF | oc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: clusterspiffeids.spire.spiffe.io
spec:
  group: spire.spiffe.io
  names:
    kind: ClusterSPIFFEID
    listKind: ClusterSPIFFEIDList
    plural: clusterspiffeids
    singular: clusterspiffeid
  scope: Cluster
  versions:
  - name: v1alpha1
    schema:
      openAPIV3Schema:
        description: ClusterSPIFFEID is the Schema for the clusterspiffeids API
        properties:
          apiVersion:
            description: 'APIVersion defines the versioned schema of this representation'
            type: string
          kind:
            description: 'Kind is a string value representing the REST resource'
            type: string
          metadata:
            type: object
          spec:
            description: ClusterSPIFFEIDSpec defines the desired state of ClusterSPIFFEID
            properties:
              className:
                description: ClassName for matching to specific workload registrar
                type: string
              dnsNameTemplates:
                description: DNS name templates for SVID
                items:
                  type: string
                type: array
              federatesWith:
                description: List of trust domains to federate with
                items:
                  type: string
                type: array
              namespaceSelector:
                description: Namespaces to match for identity assignment
                properties:
                  matchExpressions:
                    items:
                      properties:
                        key:
                          type: string
                        operator:
                          type: string
                        values:
                          items:
                            type: string
                          type: array
                      type: object
                    type: array
                  matchLabels:
                    additionalProperties:
                      type: string
                    type: object
                type: object
              podSelector:
                description: Pods to match for identity assignment
                properties:
                  matchExpressions:
                    items:
                      properties:
                        key:
                          type: string
                        operator:
                          type: string
                        values:
                          items:
                            type: string
                          type: array
                      type: object
                    type: array
                  matchLabels:
                    additionalProperties:
                      type: string
                    type: object
                type: object
              spiffeIDTemplate:
                description: Template for generating SPIFFE ID
                type: string
              ttl:
                description: TTL for issued SVIDs
                type: string
              workloadSelectorTemplates:
                description: Workload selector templates
                items:
                  type: string
                type: array
            required:
            - spiffeIDTemplate
            type: object
          status:
            description: ClusterSPIFFEIDStatus defines the observed state
            properties:
              stats:
                properties:
                  entriesMasked:
                    format: int32
                    type: integer
                  entriesRegistered:
                    format: int32
                    type: integer
                  namespaceMatches:
                    format: int32
                    type: integer
                  podMatches:
                    format: int32
                    type: integer
                type: object
            type: object
        type: object
    served: true
    storage: true
    subresources:
      status: {}
EOF

    print_success "ClusterSPIFFEID CRD installed"
}

deploy_spire_server() {
    print_section "Deploying SPIRE Server"

    # Create ServiceAccount
    oc create serviceaccount spire-server -n "$SPIRE_NAMESPACE" --dry-run=client -o yaml | oc apply -f -

    # Create ClusterRole for SPIRE server
    cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spire-server-cluster-role
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get"]
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["spire.spiffe.io"]
  resources: ["clusterspiffeids"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["spire.spiffe.io"]
  resources: ["clusterspiffeids/status"]
  verbs: ["patch", "update"]
EOF

    # Create ClusterRoleBinding
    oc create clusterrolebinding spire-server-cluster-role-binding \
        --clusterrole=spire-server-cluster-role \
        --serviceaccount="$SPIRE_NAMESPACE:spire-server" \
        --dry-run=client -o yaml | oc apply -f -

    # Create ConfigMap
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-server
  namespace: $SPIRE_NAMESPACE
data:
  server.conf: |
    server {
      bind_address = "0.0.0.0"
      bind_port = "8081"
      trust_domain = "$TRUST_DOMAIN"
      data_dir = "/run/spire/data"
      log_level = "INFO"
      ca_ttl = "24h"
      default_x509_svid_ttl = "1h"
    }

    plugins {
      DataStore "sql" {
        plugin_data {
          database_type = "sqlite3"
          connection_string = "/run/spire/data/datastore.sqlite3"
        }
      }

      KeyManager "disk" {
        plugin_data {
          keys_path = "/run/spire/data/keys.json"
        }
      }

      NodeAttestor "k8s_psat" {
        plugin_data {
          clusters = {
            "$TRUST_DOMAIN" = {
              service_account_allow_list = ["$SPIRE_NAMESPACE:spire-agent"]
            }
          }
        }
      }

      Notifier "k8sbundle" {
        plugin_data {
          namespace = "$SPIRE_NAMESPACE"
        }
      }
    }

    health_checks {
      listener_enabled = true
      bind_address = "0.0.0.0"
      bind_port = "8080"
      live_path = "/live"
      ready_path = "/ready"
    }
EOF

    # Create Service
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: spire-server
  namespace: $SPIRE_NAMESPACE
spec:
  type: ClusterIP
  ports:
  - name: api
    port: 8081
    targetPort: 8081
    protocol: TCP
  selector:
    app: spire-server
EOF

    # Create StatefulSet
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: spire-server
  namespace: $SPIRE_NAMESPACE
  labels:
    app: spire-server
spec:
  serviceName: spire-server
  replicas: 1
  selector:
    matchLabels:
      app: spire-server
  template:
    metadata:
      labels:
        app: spire-server
    spec:
      serviceAccountName: spire-server
      containers:
      - name: spire-server
        image: ghcr.io/spiffe/spire-server:1.9.0
        args:
        - -config
        - /run/spire/config/server.conf
        ports:
        - containerPort: 8081
          name: api
          protocol: TCP
        - containerPort: 8080
          name: healthz
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /live
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
        volumeMounts:
        - name: spire-config
          mountPath: /run/spire/config
          readOnly: true
        - name: spire-data
          mountPath: /run/spire/data
      volumes:
      - name: spire-config
        configMap:
          name: spire-server
      - name: spire-data
        emptyDir: {}
EOF

    print_success "SPIRE server deployed"
}

deploy_spire_agent() {
    print_section "Deploying SPIRE Agent"

    # Create ServiceAccount
    oc create serviceaccount spire-agent -n "$SPIRE_NAMESPACE" --dry-run=client -o yaml | oc apply -f -

    # Create ClusterRole for SPIRE agent
    cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: spire-agent-cluster-role
rules:
- apiGroups: [""]
  resources: ["pods", "nodes"]
  verbs: ["get"]
EOF

    # Create ClusterRoleBinding
    oc create clusterrolebinding spire-agent-cluster-role-binding \
        --clusterrole=spire-agent-cluster-role \
        --serviceaccount="$SPIRE_NAMESPACE:spire-agent" \
        --dry-run=client -o yaml | oc apply -f -

    # Grant privileged SCC to spire-agent
    oc adm policy add-scc-to-user privileged -z spire-agent -n "$SPIRE_NAMESPACE"

    # Create ConfigMap
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: spire-agent
  namespace: $SPIRE_NAMESPACE
data:
  agent.conf: |
    agent {
      data_dir = "/run/spire"
      log_level = "INFO"
      server_address = "spire-server.$SPIRE_NAMESPACE.svc"
      server_port = "8081"
      trust_domain = "$TRUST_DOMAIN"
    }

    plugins {
      NodeAttestor "k8s_psat" {
        plugin_data {
          cluster = "$TRUST_DOMAIN"
        }
      }

      KeyManager "disk" {
        plugin_data {
          directory = "/run/spire"
        }
      }

      WorkloadAttestor "k8s" {
        plugin_data {
          skip_kubelet_verification = true
        }
      }
    }

    health_checks {
      listener_enabled = true
      bind_address = "0.0.0.0"
      bind_port = "8080"
      live_path = "/live"
      ready_path = "/ready"
    }
EOF

    # Create DaemonSet
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: spire-agent
  namespace: $SPIRE_NAMESPACE
  labels:
    app: spire-agent
spec:
  selector:
    matchLabels:
      app: spire-agent
  template:
    metadata:
      labels:
        app: spire-agent
    spec:
      hostPID: true
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: spire-agent
      containers:
      - name: spire-agent
        image: ghcr.io/spiffe/spire-agent:1.9.0
        args:
        - -config
        - /run/spire/config/agent.conf
        securityContext:
          privileged: true
        volumeMounts:
        - name: spire-config
          mountPath: /run/spire/config
          readOnly: true
        - name: spire-agent-socket
          mountPath: /run/spire/sockets
        - name: spire-token
          mountPath: /var/run/secrets/tokens
        livenessProbe:
          httpGet:
            path: /live
            port: 8080
          initialDelaySeconds: 15
          periodSeconds: 60
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 30
      volumes:
      - name: spire-config
        configMap:
          name: spire-agent
      - name: spire-agent-socket
        hostPath:
          path: /run/spire/sockets
          type: DirectoryOrCreate
      - name: spire-token
        projected:
          sources:
          - serviceAccountToken:
              path: spire-agent
              expirationSeconds: 7200
              audience: spire-server
EOF

    print_success "SPIRE agent deployed"
}

wait_for_ready() {
    print_section "Waiting for SPIRE Components to be Ready"

    echo "Waiting for SPIRE server..."
    oc wait --for=condition=Ready pod -l app=spire-server -n "$SPIRE_NAMESPACE" --timeout=180s
    print_success "SPIRE server is ready"

    echo "Waiting for SPIRE agents..."
    oc rollout status daemonset/spire-agent -n "$SPIRE_NAMESPACE" --timeout=180s
    print_success "SPIRE agents are ready"
}

verify_installation() {
    print_section "Verifying Installation"

    # Check CRD
    if oc get crd clusterspiffeids.spire.spiffe.io &>/dev/null; then
        print_success "ClusterSPIFFEID CRD exists"
    else
        print_error "ClusterSPIFFEID CRD not found"
    fi

    # Check SPIRE server
    SERVER_COUNT=$(oc get pods -n "$SPIRE_NAMESPACE" -l app=spire-server --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [ "$SERVER_COUNT" -gt 0 ]; then
        print_success "SPIRE server running ($SERVER_COUNT pod)"
    else
        print_error "SPIRE server not running"
    fi

    # Check SPIRE agents
    AGENT_COUNT=$(oc get pods -n "$SPIRE_NAMESPACE" -l app=spire-agent --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [ "$AGENT_COUNT" -gt 0 ]; then
        print_success "SPIRE agents running ($AGENT_COUNT pods)"
    else
        print_error "SPIRE agents not running"
    fi

    # Check SPIRE server health
    if oc exec -n "$SPIRE_NAMESPACE" statefulset/spire-server -- \
        /opt/spire/bin/spire-server healthcheck &>/dev/null; then
        print_success "SPIRE server health check passed"
    else
        print_info "SPIRE server health check failed (may need more time)"
    fi
}

# Main execution
main() {
    print_header "SPIRE Installation for OpenShift"

    echo -e "${BOLD}Configuration:${NC}"
    echo "  Namespace:    $SPIRE_NAMESPACE"
    echo "  Trust Domain: $TRUST_DOMAIN"
    echo ""

    check_prerequisites
    create_namespace
    install_crds
    deploy_spire_server
    deploy_spire_agent
    wait_for_ready
    verify_installation

    print_header "Installation Complete"

    echo -e "${GREEN}${BOLD}✓ SPIRE installation successful!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Verify prerequisites: ./scripts/00-validate-prerequisites.sh"
    echo "  2. Review lab guide: docs/lab-201-01-postgresql-spiffe-mtls.adoc"
    echo "  3. Deploy PostgreSQL: oc apply -f deploy/postgresql-spiffe.yaml"
    echo ""
    echo "Quick verification:"
    echo "  oc get pods -n $SPIRE_NAMESPACE"
    echo "  oc get crd clusterspiffeids.spire.spiffe.io"
}

# Show usage
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<EOF
Usage: $0 [mode]

Modes:
  full    - Install SPIRE server and agent (default)
  force   - Install even if namespace exists

Environment Variables:
  SPIRE_NAMESPACE  - Namespace for SPIRE components (default: spire)
  TRUST_DOMAIN     - SPIRE trust domain (default: cluster.local)

Examples:
  $0                           # Standard installation
  $0 force                     # Force reinstall
  SPIRE_NAMESPACE=ztwim $0     # Use custom namespace
  TRUST_DOMAIN=example.org $0  # Use custom trust domain

Prerequisites:
  • OpenShift 4.12+
  • cluster-admin privileges
  • oc CLI authenticated

For detailed documentation, see:
  docs/00-prerequisites.adoc
EOF
    exit 0
fi

main
