#requires -Version 7
# Verify HuggingFace resolve URLs for all models in all profiles (or a specific profile).
# Reports OK/REDIRECT/GATED/MISSING/ERROR per model. Exits non-zero if any MISSING or ERROR.
# Set $env:HF_TOKEN for gated repos.
#   scripts\verify-urls.ps1            # all profiles
#   scripts\verify-urls.ps1 -Profile 12gb
param([string]$Profile)
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_models.ps1"

$cfg      = Get-ModelsConfig
$profiles = if ($Profile) { @($Profile) } else { @($cfg.profiles.Keys | Sort-Object) }
$hdr      = @{}
if ($env:HF_TOKEN) { $hdr['Authorization'] = "Bearer $env:HF_TOKEN" }

$exitCode = 0
foreach ($pname in $profiles) {
  Write-Host "`nProfile '$pname'" -ForegroundColor Cyan
  $prof = $cfg.profiles[$pname]
  foreach ($role in @('planner','coder','chat','fim','embed')) {
    $m = $prof[$role]; if (-not $m) { continue }
    $url    = "https://huggingface.co/$($m.repo)/resolve/main/$($m.path)"
    $status = 'ERROR'
    try {
      $resp   = Invoke-WebRequest -Uri $url -Method HEAD -Headers $hdr `
                  -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction Stop
      $status = switch ([int]$resp.StatusCode) {
        200                             { 'OK'       }
        { $_ -ge 300 -and $_ -lt 400 } { 'REDIRECT' }   # 301/302/307/308 all mean CDN-accessible
        { $_ -in 401,403 }             { 'GATED'    }
        404                            { 'MISSING'  }
        default                        { "HTTP_$($resp.StatusCode)" }
      }
    } catch { $status = 'ERROR' }
    if ($status -in 'MISSING','ERROR' -or $status -match '^HTTP_[45]') { $exitCode = 1 }
    $color = switch ($status) {
      'OK'       { 'Green'    }
      'REDIRECT' { 'DarkGray' }
      'GATED'    { 'Yellow'   }
      'MISSING'  { 'Red'      }
      default    { 'Red'      }
    }
    Write-Host ("  {0,-8} {1,-12} {2}" -f $role, $status, $url) -ForegroundColor $color
  }
}
exit $exitCode
