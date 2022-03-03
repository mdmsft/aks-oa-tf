```sh
az aks get-credentials --name aks-... --resource-group rg-... --context ...
kubelogin convert-kubeconfig -l azurecli
```
# Storage
```sh
az storage account keys list --resource-group rg-... --account-name st... --query '[0].value' -o tsv
kubectl create secret generic azure-secret --from-literal=azurestorageaccountname=... --from-literal=azurestorageaccountkey=...
```