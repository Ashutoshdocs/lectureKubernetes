#!/bin/bash
# Remove all demo objects (data on nfs-vm and worker-1 is kept - Retain policy)
kubectl delete namespace access-modes --ignore-not-found --wait=true
kubectl delete pv rwo-local-pv rwo-nfs-pv rox-pv rwx-pv rwop-pv binding-demo-pv --ignore-not-found
kubectl delete storageclass local-static --ignore-not-found
echo "Demo objects removed."
