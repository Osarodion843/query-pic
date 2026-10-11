# QueryPic release build (Windows PowerShell 5.1).
# Reusable: flutter build apk --release + signature + checksum.
# Prerequisites (one-time, human): release.jks + key.properties (passwords)
# in querypic/android/ (both git-ignored), Android SDK + Flutter on PATH.
# Usage: powershell -ExecutionPolicy Bypass -File tools\build_release.ps1
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$App = Join-Path $Root 'querypic'
$Apk = Join-Path $App 'build\app\outputs\flutter-apk\app-release.apk'
$Sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$Apksigner = Join-Path $Sdk 'build-tools\36.0.0\apksigner.bat'

Write-Host '== flutter build apk --release =='
& flutter build apk --release
if ($LASTEXITCODE -ne 0) { throw 'build failed' }

Write-Host '== apksigner verify =='
& $Apksigner verify --print-certs $Apk
if ($LASTEXITCODE -ne 0) { throw 'signature verification failed' }

Write-Host '== SHA-256 (file) =='
(Get-FileHash -LiteralPath $Apk -Algorithm SHA256).Hash
Write-Host "OK: $Apk"
