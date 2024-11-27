echo 'export CODESPACES="FALSE"' >> ~/.bashrc
echo 'export CLUSTER_NAME=${CODESPACE_NAME%-*}' >> ~/.bashrc
source ~/.bashrc

echo -e "Environment: \nSUBSCRIPTION_ID: $SUBSCRIPTION_ID \nRESOURCE_GROUP: $RESOURCE_GROUP \nLOCATION: $LOCATION \nCLUSTER_NAME: $CLUSTER_NAME"

# Create k3d cluster and forwarded ports
k3d cluster delete
k3d cluster create \
-p '1883:1883@loadbalancer' \
-p '8883:8883@loadbalancer'
