#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Error handling
set -e
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap 'echo "${RED}\"${last_command}\" command failed with exit code $?.${NC}"' EXIT

# Logger function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%dT%H:%M:%S%z')]:${NC} $@"
}

warning() {
    echo -e "${YELLOW}[WARNING]:${NC} $@"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Docker is not installed. Please install Docker first.${NC}"
        exit 1
    fi

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}kubectl is not installed. Please install kubectl first.${NC}"
        exit 1
    fi

    # Check kind
    if ! command -v kind &> /dev/null; then
        warning "kind is not installed. Installing kind..."
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
    fi

    # Check helm
    if ! command -v helm &> /dev/null; then
        warning "helm is not installed. Installing helm..."
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
        chmod +x get_helm.sh
        ./get_helm.sh
        rm get_helm.sh
    fi
}

# Create temporary directories
create_directories() {
    log "Creating temporary directories..."
    mkdir -p /tmp/kind/{istio,worker}
    chmod -R 777 /tmp/kind
}

# Create kind cluster
create_cluster() {
    log "Creating kind cluster..."
    
    # Check if cluster already exists
    if kind get clusters | grep -q "^slayer-cluster$"; then
        warning "Cluster 'slayer-cluster' already exists. Deleting..."
        kind delete cluster --name slayer-cluster
    fi

    # Create kind cluster
    cat <<EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: collage-cluster
networking:
  apiServerAddress: "0.0.0.0"
  apiServerPort: 6443
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
        system-reserved: memory=512Mi,cpu=500m
  extraPortMappings:
  - containerPort: 15021
    hostPort: 15021
    protocol: TCP
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  - containerPort: 15014
    hostPort: 15014
    protocol: TCP
  - containerPort: 27017
    hostPort: 27017
    protocol: TCP
  extraMounts:
  - hostPath: /tmp/kind/istio
    containerPath: /var/lib/istio
- role: worker
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "node-role.kubernetes.io/worker=worker"
        system-reserved: memory=256Mi,cpu=250m
  extraMounts:
  - hostPath: /tmp/kind/worker
    containerPath: /var/lib/kubelet
EOF

    log "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
}

# Install Istio
install_istio() {
    log "Installing Istio..."
    
    # Download and install istioctl if not present
    if ! command -v istioctl &> /dev/null; then
        ISTIO_VERSION=$(curl -sL https://github.com/istio/istio/releases | \
            grep -o 'releases/[0-9]*.[0-9]*.[0-9]*/' | sort -V | tail -1 | \
            awk -F'/' '{print $2}')
        
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
        sudo mv istio-$ISTIO_VERSION/bin/istioctl /usr/local/bin/
        rm -rf istio-$ISTIO_VERSION
    fi

    # Install Istio with demo profile
    istioctl install --set profile=demo -y

    # Enable default namespace for automatic sidecar injection
    kubectl label namespace default istio-injection=enabled --overwrite

    # Install Istio addons
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/master/samples/addons/prometheus.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/master/samples/addons/kiali.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/master/samples/addons/grafana.yaml
    kubectl apply -f https://raw.githubusercontent.com/istio/istio/master/samples/addons/jaeger.yaml

    # Wait for Istio components to be ready
    kubectl wait --for=condition=Ready pods --all -n istio-system --timeout=300s
}

# Setup MongoDB
setup_mongodb() {
    log "Setting up MongoDB..."
    
    # Create MongoDB namespace
    kubectl create namespace mongodb --dry-run=client -o yaml | kubectl apply -f -

    # Add MongoDB Helm repository
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo update

    # Install MongoDB
    helm upgrade --install mongodb bitnami/mongodb \
        --namespace mongodb \
        --set auth.rootPassword=rootpassword \
        --set auth.username=mernuser \
        --set auth.password=mernpass \
        --set auth.database=merndb \
        --wait
}

# Setup monitoring
setup_monitoring() {
    log "Setting up monitoring..."
    
    # Create monitoring namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    # Add Prometheus Helm repository
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update

    # Install Prometheus Stack
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set grafana.enabled=true \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --wait
}

# Main setup function
main() {
    log "Starting MERN stack cluster setup..."
    
    # Run setup steps
    check_prerequisites
    create_directories
    create_cluster
    install_istio
    setup_mongodb
    setup_monitoring

    # Print completion message and useful commands
    cat <<EOF

${GREEN}=== Setup Complete! ===${NC}

Useful commands:

1. Check cluster status:
   ${YELLOW}kubectl get nodes
   kubectl get pods --all-namespaces${NC}

2. Access Kiali dashboard:
   ${YELLOW}istioctl dashboard kiali${NC}

3. Access Grafana:
   ${YELLOW}kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
   # Then visit http://localhost:3000 (admin/prom-operator)${NC}

4. MongoDB connection string:
   ${YELLOW}mongodb://mernuser:mernpass@mongodb.mongodb.svc.cluster.local:27017/merndb${NC}

5. Check Istio status:
   ${YELLOW}istioctl analyze${NC}

To deploy your MERN application:
1. Apply your Helm charts:
   ${YELLOW}helm upgrade --install mern-auth ./helm${NC}

2. Monitor the deployment:
   ${YELLOW}kubectl get pods -n default -w${NC}

EOF

    # Remove error trap
    trap - EXIT
}

# Run main function
main "$@"
