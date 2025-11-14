#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e
echo "🚀 Starting kind cluster..."
kind create cluster --config kind/kind-cluster-config.yaml --name cluster  --wait 5m
echo "✅ Cluster is ready!"
kubectl cluster-info --context kind-cluster



# Validate required environment variables
echo "🔍 Validating environment variables..."
required_vars=(
    "CRIBL_STREAM_VERSION"
    "CRIBL_STREAM_WORKER_GROUP"
    "CRIBL_STREAM_TOKEN"
    "CRIBL_STREAM_LEADER_URL"
    "CRIBL_EDGE_VERSION"
    "CRIBL_EDGE_FLEET"
    "CRIBL_EDGE_LEADER_URL"
    "CRIBL_EDGE_TOKEN"
    "NGROK_AUTHTOKEN"
    "NGROK_API_KEY"
)

missing_vars=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -ne 0 ]; then
    echo "❌ Missing required environment variables:"
    printf '   %s\n' "${missing_vars[@]}"
    echo "Please set these variables before running the script."
    exit 1
fi

echo "✅ All required environment variables are set."

# Helper: wait for a deployment to exist, then for its rollout to complete
wait_for_deployment() {
  local namespace="$1"
  local deployment_name="$2"
  local timeout_seconds="${3:-600}"

  echo "Waiting for deployment '$deployment_name' to be created in namespace '$namespace'..."
  local start_ts
  start_ts=$(date +%s)
  while true; do
    if kubectl get deployment "$deployment_name" -n "$namespace" >/dev/null 2>&1; then
      break
    fi
    if [ $(( $(date +%s) - start_ts )) -ge "$timeout_seconds" ]; then
      echo "Timed out waiting for deployment '$deployment_name' to be created in namespace '$namespace'."
      exit 1
    fi
    sleep 5
  done

  echo "Waiting for deployment '$deployment_name' rollout to complete in namespace '$namespace'..."
  kubectl rollout status deployment/"$deployment_name" -n "$namespace" --timeout="${timeout_seconds}s"
}

# Helper: wait for a daemonset to exist, then for all pods to be ready
wait_for_daemonset() {
  local namespace="$1"
  local daemonset_name="$2"
  local timeout_seconds="${3:-600}"

  echo "Waiting for daemonset '$daemonset_name' to be created in namespace '$namespace'..."
  local start_ts
  start_ts=$(date +%s)
  while true; do
    if kubectl get daemonset "$daemonset_name" -n "$namespace" >/dev/null 2>&1; then
      break
    fi
    if [ $(( $(date +%s) - start_ts )) -ge "$timeout_seconds" ]; then
      echo "Timed out waiting for daemonset '$daemonset_name' to be created in namespace '$namespace'."
      exit 1
    fi
    sleep 5
  done

  echo "Waiting for daemonset '$daemonset_name' pods to be ready in namespace '$namespace'..."
  start_ts=$(date +%s)
  while true; do
    desired=$(kubectl get ds "$daemonset_name" -n "$namespace" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
    ready=$(kubectl get ds "$daemonset_name" -n "$namespace" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" -gt 0 ] && [ "$desired" -eq "$ready" ]; then
      echo "Daemonset '$daemonset_name' is ready: $ready/$desired"
      break
    fi
    if [ $(( $(date +%s) - start_ts )) -ge "$timeout_seconds" ]; then
      echo "Timed out waiting for daemonset '$daemonset_name' to be ready in namespace '$namespace'. Current: $ready/$desired"
      kubectl get ds "$daemonset_name" -n "$namespace" -o wide || true
      kubectl get pods -n "$namespace" -l "app.kubernetes.io/instance=$daemonset_name" -o wide || true
      exit 1
    fi
    sleep 5
  done
}

# Apply your manifests
echo "🔧 Applying manifests..."
kubectl apply --namespace otel-demo -f otel-demo/opentelemetry-demo.yaml
helm install --repo "https://criblio.github.io/helm-charts/" --version "^${CRIBL_EDGE_VERSION}" --create-namespace -n "cribl" \
--set "cribl.leader=tls://${CRIBL_EDGE_TOKEN}@${CRIBL_EDGE_LEADER_URL}?group=${CRIBL_EDGE_FLEET}" \
--set "env.CRIBL_K8S_TLS_REJECT_UNAUTHORIZED=0" \
--values cribl/edge/values.yaml \
"cribl-edge" edge
helm install --repo "https://criblio.github.io/helm-charts/" --version "^${CRIBL_STREAM_VERSION}" --create-namespace -n "cribl" \
--set "config.host=${CRIBL_STREAM_LEADER_URL}" \
--set "config.token=${CRIBL_STREAM_TOKEN}" \
--set "config.group=${CRIBL_STREAM_WORKER_GROUP}" \
--set "config.tlsLeader.enable=true"  \
--set "env.CRIBL_K8S_TLS_REJECT_UNAUTHORIZED=0" \
--set "env.CRIBL_MAX_WORKERS=4" \
--values cribl/stream/values.yaml \
"cribl-worker" logstream-workergroup  
kubectl create -f https://download.elastic.co/downloads/eck/2.16.0/crds.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/2.16.0/operator.yaml
#kubectl -n elastic-system logs -f statefulset.apps/elastic-operator

kubectl create ns elastic
kubectl apply -n elastic -f elastic/elastic.yaml
kubectl apply -n elastic -f elastic/add_dashboard.yml
kubectl apply --namespace otel-demo -f otel-demo/opentelemetry-demo.yaml
helm upgrade -i ngrok-operator ngrok/ngrok-operator \
  --namespace ngrok-ingress-controller \
  --create-namespace \
  --set credentials.apiKey=${NGROK_API_KEY} \
  --set credentials.authtoken=${NGROK_AUTHTOKEN}



# Wait for the deployments to be ready
echo "Waiting for 'kibana' deployment..."
wait_for_deployment elastic kibana-kb 900
echo "Waiting for 'cribl-edge' daemonset..."
wait_for_daemonset cribl cribl-edge 900

echo "Waiting for 'cribl-worker' deployment..."

wait_for_deployment cribl cribl-worker-logstream-workergroup 900
echo "Waiting for 'opentelemetry-demo' deployment..."
wait_for_deployment otel-demo opentelemetry-demo-kafka 900    

echo "Waiting for 'ngrok' deployment..."
wait_for_deployment ngrok-ingress-controller ngrok-operator-agent 900
#Apply the ngrok manifest
# Set default NGROK_HOST if not provided
export NGROK_HOST=${NGROK_HOST:-arturo-germicidal-rivka.ngrok-free.dev}
envsubst < ngrok/ngrok-manifest.yaml | kubectl apply -f -
echo "All deployments are ready!"


#port forward
echo "Starting port-forwarding..."

# Start port-forward in the background
kubectl port-forward -n elastic svc/kibana-kb-http -n elastic 5601:5601 --address 0.0.0.0 &
PORT_FORWARD_PID1=$!

echo "Port-forward started with PID $PORT_FORWARD_PID1."
kubectl port-forward -n otel-demo svc/opentelemetry-demo-frontendproxy 8080:8080 &
PORT_FORWARD_PID2=$!
echo "Port-forward started with PID $PORT_FORWARD_PID2."


# Capture the Process ID (PID) of the background command



echo "Access your app : Kibana: http://localhost:5601
App: http://localhost:8080/
Loadgen: http://localhost:8080/loadgen/
"
echo "🎉 Setup complete! Press [Enter] to stop port-forwarding and delete the cluster."
echo "---"

# Wait for the user to press Enter
read

# Clean up
# --- 5. Cleanup ---
echo "🛑 Stopping port-forward (PID: $PORT_FORWARD_PID1)..."
kill $PORT_FORWARD_PID1
wait $PORT_FORWARD_PID1 2>/dev/null || true # Wait for it to shut down
echo "🛑 Stopping port-forward (PID: $PORT_FORWARD_PID2)..."
kill $PORT_FORWARD_PID2
wait $PORT_FORWARD_PID2 2>/dev/null || true # Wait for it to shut down

echo "🔥 Deleting kind cluster..."
kind delete cluster --name cluster

echo "👋 Done!"
