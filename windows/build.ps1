$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Project = Join-Path $PSScriptRoot "QuotaMeter.Windows.csproj"
$Output = Join-Path $Root "windows-dist"

dotnet publish $Project `
  --configuration Release `
  --runtime win-x64 `
  --self-contained true `
  -p:PublishSingleFile=true `
  -p:IncludeNativeLibrariesForSelfExtract=true `
  --output $Output

Write-Host "Built: $Output"
