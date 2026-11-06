# Windows PowerShell 5.1+. Creates a new folder; does not drive onPC or edit a show.
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$PluginsDirectory)
$ErrorActionPreference = 'Stop'
if (-not $PluginsDirectory) {
    $roots = Join-Path $env:ProgramData 'MA Lighting Technologies\grandma'
    Write-Host 'Specify -PluginsDirectory with the existing plugins folder of your MA2 3.9 installation.'
    if (Test-Path -LiteralPath $roots) {
        Get-ChildItem -LiteralPath $roots -Directory -Filter 'gma2_V_3.9*' |
            ForEach-Object { Join-Path $_.FullName 'plugins' } |
            Where-Object { Test-Path -LiteralPath $_ }
    }
    exit 1
}
$destination = (Resolve-Path -LiteralPath $PluginsDirectory).Path
if ((Split-Path $destination -Leaf) -ne 'plugins' -or
    (Split-Path (Split-Path $destination -Parent) -Leaf) -notlike 'gma2_V_3.9*') {
    throw 'Choose an existing gma2_V_3.9...\plugins directory.'
}
$project = Split-Path $PSScriptRoot -Parent
$files = @('layout_assistant.lua', 'layout_assistant.xml')
foreach ($name in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $project "dist\$name") -PathType Leaf)) {
        throw "Missing distribution file: $name"
    }
}
$folder = Join-Path $destination ('LayoutAssistant_0_2_0_' + (Get-Date -Format yyyyMMdd_HHmmss) + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
if ($PSCmdlet.ShouldProcess($folder, 'Install new Layout Assistant files')) {
    New-Item -ItemType Directory -Path $folder -ErrorAction Stop | Out-Null
    foreach ($name in $files) {
        [System.IO.File]::Copy((Join-Path $project "dist\$name"), (Join-Path $folder $name), $false)
    }
    Write-Host "Files installed: $folder"
    Write-Host 'In onPC: Edit an EMPTY Plugin slot > Import > open this folder > layout_assistant.xml.'
    Write-Host 'Leave Execute on Load OFF. First run probe, then preview in a copy of your show.'
}
