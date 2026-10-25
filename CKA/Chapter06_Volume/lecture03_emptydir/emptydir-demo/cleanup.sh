#!/usr/bin/env bash
kubectl delete pod -l demo=emptydir --ignore-not-found --grace-period=0 --force
