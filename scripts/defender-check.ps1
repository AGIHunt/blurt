# Release gate: does Microsoft Defender (with cloud protection, as on users' PCs) flag this installer?
# Run on a Windows test machine before publishing: powershell -File defender-check.ps1 C:\path\Blurt_X.Y.Z_x64-setup.exe
# Exit 0 = clean; 1 = flagged (the file is usually quarantined at once — that is the answer too); 2 = couldn't check.
#
# Why: an unsigned NSIS installer with a new hash can be flagged by Defender's cloud ML (2026-11-18: one CI build came
# out as Trojan:Win32/Bearfoos.A!ml, the next build of the same branch was clean; v1.0.25 was clean). A flagged release
# would be deleted on download for most Windows users. Signing (Authenticode) is the lasting fix; until then, check
# each release and, if flagged, submit it as a false positive (https://www.microsoft.com/wdsi/filesubmission) or rebuild.
param([Parameter(Mandatory = $true)][string]$Installer)
$ErrorActionPreference = "Continue"
$mp = "$env:ProgramFiles\Windows Defender\MpCmdRun.exe"
if (-not (Test-Path $mp)) { "Defender isn't on this machine"; exit 2 }
$st = Get-MpComputerStatus
"Defender {0}, signatures {1} ({2}), real-time {3}, cloud {4}" -f $st.AMProductVersion, $st.AntivirusSignatureVersion,
  $st.AntivirusSignatureLastUpdated, $st.RealTimeProtectionEnabled, ((Get-MpPreference).MAPSReporting -ne 0)
& $mp -SignatureUpdate | Out-Null
$hash = (Get-FileHash $Installer -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
$since = Get-Date
# a copy, so real-time protection sees a fresh write, then an on-demand scan with cloud lookups
$copy = Join-Path $env:TEMP ("defender-check-" + [IO.Path]::GetFileName($Installer))
Copy-Item $Installer $copy -Force
Start-Sleep 20
if (-not (Test-Path $copy)) { $flagged = $true }
else {
  $out = & $mp -Scan -ScanType 3 -File $copy -DisableRemediation 2>&1 | Out-String
  $flagged = $out -match "found \d+ threats" -and $out -notmatch "found no threats"
}
$hits = Get-MpThreatDetection | Where-Object { $_.InitialDetectionTime -ge $since.AddMinutes(-1) }
foreach ($h in $hits) {
  $t = Get-MpThreat -ThreatID $h.ThreatID -ErrorAction SilentlyContinue
  "detected: {0} in {1}" -f $t.ThreatName, ($h.Resources -join ", ")
}
Remove-Item $copy -Force -ErrorAction SilentlyContinue
"sha256 $hash"
if ($flagged -or $hits) { "FLAGGED"; exit 1 }
"clean"; exit 0
