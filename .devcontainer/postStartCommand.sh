echo 'export CLUSTER_NAME=${CODESPACE_NAME%-*}' >> ~/.bashrc
echo 'eval "$(starship init bash)"' >> ~/.bashrc
source ~/.bashrc

echo -e "Environment: \nSUBSCRIPTION_ID: $SUBSCRIPTION_ID \nRESOURCE_GROUP: $RESOURCE_GROUP \nLOCATION: $LOCATION \nCLUSTER_NAME: $CLUSTER_NAME"


