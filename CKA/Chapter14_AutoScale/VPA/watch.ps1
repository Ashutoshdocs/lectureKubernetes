# ---------------------------------------------------------------------------
# Windows / PowerShell version of watch.sh
# Prints pod resource requests alongside the VPA target recommendation.
#
#   .\watch.ps1
# ---------------------------------------------------------------------------

Write-Host "== Pod resource requests =="
kubectl get pods -l app=vpa-demo `
  -o jsonpath='{range .items[*]}{.metadata.name}{" => "}{.spec.containers[0].resources.requests}{"\n"}{end}'

Write-Host ""
Write-Host "== VPA target recommendation =="
kubectl get vpa vpa-demo `
  -o jsonpath='{.status.recommendation.containerRecommendations[*].target}'
Write-Host ""
