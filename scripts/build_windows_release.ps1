$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

$VersionLine = (Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$VersionParts = $VersionLine.Split('+', 2)
$BuildName = $VersionParts[0]
$BuildNumber = if ($VersionParts.Count -gt 1) { $VersionParts[1] } else { '1' }

flutter pub get
flutter build windows --release --build-name=$BuildName --build-number=$BuildNumber

$BundleDir = Join-Path $RootDir 'build\windows\x64\runner\Release'
$DistDir = Join-Path $RootDir 'dist'
$ArchiveName = "PerfectC2PA-$BuildName-windows-x64.zip"
$ArchivePath = Join-Path $DistDir $ArchiveName
$ChecksumPath = Join-Path $DistDir "PerfectC2PA-$BuildName-windows-x64.sha256"

if (-not (Test-Path (Join-Path $BundleDir 'PerfectC2PA.exe'))) {
  throw "Windows release executable was not found in $BundleDir"
}

$C2paToolVersion = '0.27.6'
$C2paToolSha256 = 'bebc9468f8aeb87b91013dce374ed0bd224f97c9b88c6dd14fb620a08ca6a54c'
$C2paToolArchiveName = "c2patool-v$C2paToolVersion-x86_64-pc-windows-msvc.zip"
$C2paToolUrl = "https://github.com/contentauth/c2pa-rs/releases/download/c2patool-v$C2paToolVersion/$C2paToolArchiveName"
$C2paToolWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("perfect-c2pa-" + [guid]::NewGuid())
$C2paToolArchive = Join-Path $C2paToolWorkDir $C2paToolArchiveName
New-Item -ItemType Directory -Path $C2paToolWorkDir -Force | Out-Null

try {
  Invoke-WebRequest -Uri $C2paToolUrl -OutFile $C2paToolArchive
  $ActualSha256 = (Get-FileHash -Path $C2paToolArchive -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($ActualSha256 -ne $C2paToolSha256) {
    throw "c2patool checksum mismatch: $ActualSha256"
  }

  Expand-Archive -Path $C2paToolArchive -DestinationPath (Join-Path $C2paToolWorkDir 'extracted')
  $C2paToolSource = Join-Path $C2paToolWorkDir 'extracted\c2patool\c2patool.exe'
  $C2paToolTarget = Join-Path $BundleDir 'c2patool.exe'
  Copy-Item -Path $C2paToolSource -Destination $C2paToolTarget -Force

  $C2paSettingsPath = Join-Path $BundleDir 'c2pa.toml'
  & $C2paToolTarget --settings $C2paSettingsPath init trust
  if ($LASTEXITCODE -ne 0) {
    throw 'c2patool failed to install the official C2PA trust list'
  }

  Invoke-WebRequest -Uri 'https://verify.contentauthenticity.org/trust/anchors.pem' `
    -OutFile (Join-Path $BundleDir 'c2pa-trust-list-legacy.pem')
  Invoke-WebRequest -Uri 'https://verify.contentauthenticity.org/trust/allowed.sha256.txt' `
    -OutFile (Join-Path $BundleDir 'c2pa-trust-allowed.sha256.txt')
  Invoke-WebRequest -Uri 'https://verify.contentauthenticity.org/trust/store.cfg' `
    -OutFile (Join-Path $BundleDir 'c2pa-trust-store.cfg')
  Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/c2pa-org/conformance-public/refs/heads/main/trust-list/C2PA-TRUST-LIST.json' `
    -OutFile (Join-Path $BundleDir 'c2pa-trust-list.json')
}
finally {
  Remove-Item $C2paToolWorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
Remove-Item $ArchivePath, $ChecksumPath -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $BundleDir '*') -DestinationPath $ArchivePath -CompressionLevel Optimal

$Hash = (Get-FileHash -Path $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -Path $ChecksumPath -Value "$Hash *$ArchiveName" -Encoding ascii

Write-Host "Created $ArchivePath"
Write-Host "Created $ChecksumPath"
