#######################################################
# 03 - Prove the data survives a pod restart
#######################################################
# Works the same for either demo — swap the pod/manifest names as needed.
# Example below uses the STATIC demo (storage-demo / static/static-pod.yaml).

$env:KUBECONFIG = "D:\credsaks\config"

# Write a file into the mounted volume
kubectl exec -it storage-demo -- bash -c "echo AKBLAZE > /data/demo.txt; cat /data/demo.txt"

# Delete and recreate the pod (the PVC/PV/disk stay)
kubectl delete pod storage-demo
kubectl apply -f ../static/static-pod.yaml

# Wait for it to come back, then confirm the file is still there
kubectl wait --for=condition=Ready pod/storage-demo --timeout=120s
kubectl exec -it storage-demo -- cat /data/demo.txt   # -> AKBLAZE
