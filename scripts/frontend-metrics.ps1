# Metriche applicative del frontend ricavate dai log JSON (probe di health check escluse)
$lines = kubectl logs deploy/frontend -n development --tail=1000 |
  Where-Object { $_ -like '*request complete*' -and $_ -notlike '*_healthz*' }
$entries = @($lines | ForEach-Object { $_ | ConvertFrom-Json })

"Richieste (esclusi health check): $($entries.Count)"

"`nPer stato HTTP:"
$entries | Group-Object { $_.'http.resp.status' } | Select-Object Name, Count | Format-Table -AutoSize

"Per percorso:"
$entries | Group-Object { $_.'http.req.path' } | Select-Object Name, Count | Format-Table -AutoSize

"Latenza (ms):"
$entries | Measure-Object -Property 'http.resp.took_ms' -Average -Maximum -Minimum |
  Select-Object Count, @{n='Average';e={[math]::Round($_.Average,1)}}, Minimum, Maximum | Format-Table -AutoSize

$lat = @($entries | ForEach-Object { [double]$_.'http.resp.took_ms' } | Sort-Object)
"Mediana (ms): $($lat[[int][math]::Floor($lat.Count / 2)])"
"95 percentile (ms): $($lat[[int][math]::Ceiling($lat.Count * 0.95) - 1])"

"`n5 richieste piu lente:"
$entries | Sort-Object { [double]$_.'http.resp.took_ms' } -Descending |
  Select-Object -First 5 timestamp, @{n='ms';e={$_.'http.resp.took_ms'}}, @{n='path';e={$_.'http.req.path'}} |
  Format-Table -AutoSize