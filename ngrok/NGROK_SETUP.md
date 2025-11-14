# Deploy ngrok agent

## Using helm, add the ngrok repo:
```
helm repo add ngrok https://charts.ngrok.com
```

## Create a Free Ngrok Account
Start by creating a free account on Ngrok. This will allow you to access the necessary tools to expose your local server.

## Set Up a Static Domain
Once your account is set up, go to Cloud Edge > Domains in your Ngrok dashboard. Click on the + Create Domain button to create a new free static domain. Make sure to copy your new domain name for the next steps.

## Set your environment variables with your ngrok credentials. 
Replace [AUTHTOKEN] and [API_KEY] with your Authtoken and API key.
* Auth token: https://dashboard.ngrok.com/get-started/your-authtoken
* API keys: https://dashboard.ngrok.com/api-keys
* NGROK endpoint URL: https://dashboard.ngrok.com/endpoints
```bash
export NGROK_AUTHTOKEN=[AUTHTOKEN]
export NGROK_API_KEY=[API_KEY]
export NGROK_HOST=abc.ngrok.com
```

## Install the ngrok Kubernetes Operator
```bash
helm install ngrok-operator ngrok/ngrok-operator \
  --namespace ngrok-operator \
  --create-namespace \
  --set credentials.apiKey=$NGROK_API_KEY \
  --set credentials.authtoken=$NGROK_AUTHTOKEN
```



## Apply the manifest file to your k8s cluster.
```
kubectl apply -f ngrok/ngrok-manifest.yaml
```

## To delete the ngrok tunnel
Once you are done, to remove the tunnel
```
kubectl delete -f ngrok/ngrok-manifest.yaml
```