@echo off
setlocal
set "CFTM_ENTRY=%~f0"
set "CFTM_TMP=%TEMP%\cftm-%RANDOM%-%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$bat=$env:CFTM_ENTRY; $raw=Get-Content -Raw -LiteralPath $bat; $marker='# POWERSHELL_' + 'SCRIPT_START'; $idx=$raw.IndexOf($marker); if($idx -lt 0){ Write-Error 'Embedded PowerShell script not found.'; exit 1 }; $script=$raw.Substring($idx + $marker.Length); Set-Content -LiteralPath $env:CFTM_TMP -Value $script -Encoding UTF8"
if errorlevel 1 exit /b %ERRORLEVEL%
powershell -NoProfile -ExecutionPolicy Bypass -File "%CFTM_TMP%" %*
set "CFTM_EXIT=%ERRORLEVEL%"
del "%CFTM_TMP%" >nul 2>&1
exit /b %CFTM_EXIT%
# POWERSHELL_SCRIPT_START
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CliArgs
)

$AppName = 'Cloudflare Tunnel Manager'
$AppVersion = '1.0.0'
$BaseDir = if ($env:CFTM_HOME) { $env:CFTM_HOME } else { Join-Path (Get-Location) 'cloudflared-data' }
$CloudflaredImage = if ($env:CLOUDFLARED_IMAGE) { $env:CLOUDFLARED_IMAGE } else { 'cloudflare/cloudflared:latest' }
$ContainerCfDir = '/home/nonroot/.cloudflared'
$StateFile = $null
$BackupDir = $null
$ComposeFile = $null
$NginxTemplateDir = $null

function Write-Info([string] $Message) { Write-Host "[INFO] $Message" -ForegroundColor Blue }
function Write-Ok([string] $Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn([string] $Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err([string] $Message) { Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Section([string] $Title) { Write-Host ''; Write-Host "== $Title ==" -ForegroundColor Cyan }

function Show-Usage {
    @"
$AppName $AppVersion

Usage:
  cloudflare-tunnel-manager.bat [--base-dir DIR] [--help]

Environment:
  CFTM_HOME             Default working directory for generated tunnel files.
  CLOUDFLARED_IMAGE    Docker image to use. Default: cloudflare/cloudflared:latest

Generated layout:
  cloudflared-data\
    docker-compose.yml
    tunnels.tsv
    <tunnel-slug>\
      cert.pem
      <tunnel-id>.json
      config.yaml
    backups\
    nginx-templates\

This Windows version requires PowerShell and Docker Desktop or another working Docker Engine.
"@
}

function Parse-Args([string[]] $Args) {
    for ($i = 0; $i -lt $Args.Count; $i++) {
        switch -Regex ($Args[$i]) {
            '^--base-dir$' {
                if ($i + 1 -ge $Args.Count) {
                    Write-Err '--base-dir requires a directory'
                    exit 2
                }
                $script:BaseDir = $Args[$i + 1]
                $i++
                continue
            }
            '^(--help|-h)$' { Show-Usage; exit 0 }
            '^(--version|-v)$' { Write-Host $AppVersion; exit 0 }
            default {
                Write-Err "Unknown argument: $($Args[$i])"
                Show-Usage
                exit 2
            }
        }
    }
}

function Init-Paths {
    New-Item -ItemType Directory -Force -Path $script:BaseDir | Out-Null
    $script:BaseDir = [System.IO.Path]::GetFullPath($script:BaseDir)
    $script:StateFile = Join-Path $script:BaseDir 'tunnels.tsv'
    $script:BackupDir = Join-Path $script:BaseDir 'backups'
    $script:ComposeFile = Join-Path $script:BaseDir 'docker-compose.yml'
    $script:NginxTemplateDir = Join-Path $script:BaseDir 'nginx-templates'
    New-Item -ItemType Directory -Force -Path $script:BackupDir, $script:NginxTemplateDir | Out-Null
    if (-not (Test-Path -LiteralPath $script:StateFile)) { New-Item -ItemType File -Path $script:StateFile | Out-Null }
}

function Confirm([string] $Prompt, [string] $Default = 'N') {
    $suffix = if ($Default -match '^Y$') { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
    return $answer -match '^[Yy]'
}

function Prompt-Required([string] $Prompt) {
    do {
        $value = (Read-Host $Prompt).Trim()
        if (-not $value) { Write-Warn 'Value is required.' }
    } while (-not $value)
    return $value
}

function Prompt-Default([string] $Prompt, [string] $Default) {
    $value = (Read-Host "$Prompt [$Default]").Trim()
    if ($value) { return $value }
    return $Default
}

function Slugify([string] $Value) {
    $slug = $Value.ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9_-]+', '-')
    $slug = [regex]::Replace($slug, '^-+|-+$', '')
    $slug = [regex]::Replace($slug, '-+', '-')
    return $slug
}

function Test-Slug([string] $Value) { return $Value -match '^[a-z0-9][a-z0-9_-]{0,62}$' }
function Test-Hostname([string] $Value) { return $Value.Length -le 253 -and $Value -match '^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$' }
function Test-Service([string] $Value) { return $Value -match '^(http|https|tcp|ssh|rdp)://\S+$' -or $Value -match '^http_status:[0-9]{3}$' -or $Value -eq 'hello_world' }

function Require-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Err 'Docker is not installed. Install Docker Desktop first.'
        return $false
    }
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Err 'Docker is installed but the Docker Engine is not reachable.'
        Write-Warn 'Start Docker Desktop, then run this script again.'
        return $false
    }
    return $true
}

function Get-ComposeCommand {
    & docker compose version *> $null
    if ($LASTEXITCODE -eq 0) { return @('docker', 'compose') }
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) { return @('docker-compose') }
    return $null
}

function Require-Compose {
    if (-not (Require-Docker)) { return $false }
    if (-not (Get-ComposeCommand)) {
        Write-Err 'Docker Compose is not available.'
        Write-Warn 'Install Docker Desktop with the Compose plugin.'
        return $false
    }
    return $true
}

function Invoke-Compose([string[]] $ComposeArgs) {
    $cmd = Get-ComposeCommand
    if (-not $cmd) { Write-Err 'Docker Compose is not available.'; return }
    if ($cmd.Count -eq 2) { & docker compose @ComposeArgs } else { & docker-compose @ComposeArgs }
}

function Invoke-Cloudflared([string] $TunnelDir, [string[]] $CloudflaredArgs, [switch] $NoTty) {
    if (-not (Require-Docker)) { $script:LASTEXITCODE = 1; return }
    New-Item -ItemType Directory -Force -Path $TunnelDir | Out-Null
    $dockerArgs = @('run', '--rm')
    if (-not $NoTty) {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $dockerArgs += '-i' } else { $dockerArgs += '-it' }
    }
    $dockerArgs += @('-v', "${TunnelDir}:${ContainerCfDir}", $CloudflaredImage)
    $dockerArgs += $CloudflaredArgs
    & docker @dockerArgs
}

function Get-TunnelDir([string] $Slug) { return Join-Path $BaseDir $Slug }
function Get-MetaFile([string] $Slug) { return Join-Path (Get-TunnelDir $Slug) '.tunnel-meta' }

function Get-MetaValue([string] $Slug, [string] $Key) {
    $file = Get-MetaFile $Slug
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $prefix = "$Key="
    $line = Get-Content -LiteralPath $file | Where-Object { $_.StartsWith($prefix) } | Select-Object -Last 1
    if ($line) { return $line.Substring($prefix.Length) }
    return $null
}

function Save-Meta([string] $Slug, [string] $Name, [string] $Id, [string] $CreatedAt) {
    $dir = Get-TunnelDir $Slug
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    @(
        "slug=$Slug",
        "name=$Name",
        "tunnel_id=$Id",
        "created_at=$CreatedAt"
    ) | Set-Content -LiteralPath (Get-MetaFile $Slug) -Encoding ASCII
}

function Get-CredentialFile([string] $Slug) {
    $dir = Get-TunnelDir $Slug
    $metaId = Get-MetaValue $Slug 'tunnel_id'
    if ($metaId) {
        $candidate = Join-Path $dir "$metaId.json"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1 -ExpandProperty FullName
}

function Get-TunnelIdFromCredential([string] $File) {
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $File | ConvertFrom-Json).TunnelID } catch { return $null }
}

function Get-TunnelId([string] $Slug) {
    $metaId = Get-MetaValue $Slug 'tunnel_id'
    if ($metaId) { return $metaId }
    $credential = Get-CredentialFile $Slug
    if ($credential) { return Get-TunnelIdFromCredential $credential }
    return $null
}

function Get-TunnelName([string] $Slug) {
    $name = Get-MetaValue $Slug 'name'
    if ($name) { return $name }
    return $Slug
}

function Refresh-Registry {
    $rows = @()
    Get-ChildItem -LiteralPath $BaseDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $slug = $_.Name
        if ($slug -notin @('backups', 'nginx-templates')) {
            $name = Get-TunnelName $slug
            $id = Get-TunnelId $slug
            $createdAt = Get-MetaValue $slug 'created_at'
            if (-not $createdAt) { $createdAt = 'unknown' }
            $rows += "$slug`t$name`t$id`t$createdAt"
        }
    }
    $rows | Set-Content -LiteralPath $StateFile -Encoding ASCII
}

function Get-RegisteredSlugs {
    Refresh-Registry
    if (-not (Test-Path -LiteralPath $StateFile)) { return @() }
    return @(Get-Content -LiteralPath $StateFile | Where-Object { $_ } | ForEach-Object { ($_ -split "`t")[0] })
}

function Select-Tunnel {
    $slugs = @(Get-RegisteredSlugs)
    if ($slugs.Count -eq 0) {
        Write-Warn "No local tunnels found in $BaseDir."
        return $null
    }
    Section 'Select Tunnel'
    for ($i = 0; $i -lt $slugs.Count; $i++) {
        $slug = $slugs[$i]
        $name = Get-TunnelName $slug
        $id = Get-TunnelId $slug
        if (-not $id) { $id = 'no-id-yet' }
        '{0,2}) {1,-24} {2,-24} {3}' -f ($i + 1), $slug, $name, $id | Write-Host
    }
    $choice = Read-Host 'Choose tunnel number'
    $number = 0
    if (-not [int]::TryParse($choice, [ref] $number) -or $number -lt 1 -or $number -gt $slugs.Count) {
        Write-Err 'Invalid tunnel selection.'
        return $null
    }
    return $slugs[$number - 1]
}

function Prompt-TunnelSlug([string] $Prompt) {
    while ($true) {
        $value = Prompt-Required $Prompt
        $suggested = Slugify $value
        $slug = Slugify (Prompt-Default 'Folder slug' $suggested)
        if (Test-Slug $slug) { return $slug }
        Write-Warn 'Use lowercase letters, numbers, dash, or underscore. Maximum 63 characters.'
    }
}

function Install-DockerHelp {
    Section 'Docker Setup'
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Write-Ok "Docker is already installed: $(& docker --version)"
        return
    }
    Write-Warn 'Automatic Docker installation is not supported by this .bat file.'
    Write-Info 'Install Docker Desktop for Windows, start it, then run this script again.'
    if (Confirm 'Open Docker Desktop installation page?' 'Y') {
        Start-Process 'https://docs.docker.com/desktop/setup/install/windows-install/'
    }
}

function Cloudflare-Login {
    Section 'Cloudflare Login'
    if (-not (Require-Docker)) { return }
    $name = Prompt-Required 'Account/workspace label (example: devth)'
    $slug = Slugify $name
    if (-not (Test-Slug $slug)) { Write-Err "Invalid workspace label after slug conversion: $slug"; return }
    $dir = Get-TunnelDir $slug
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-Info 'A Cloudflare login URL will be opened or printed by cloudflared.'
    Write-Info "After authorizing, cert.pem will be saved in: $dir"
    Invoke-Cloudflared $dir @('tunnel', 'login')
    if (Test-Path -LiteralPath (Join-Path $dir 'cert.pem')) { Write-Ok 'Login certificate saved.' } else { Write-Warn 'cert.pem was not found. Login may not have completed.' }
}

function Create-Tunnel {
    Section 'Create Tunnel'
    if (-not (Require-Docker)) { return }
    $name = Prompt-Required 'Tunnel name in Cloudflare (example: devth-tunnel)'
    $slug = Prompt-TunnelSlug 'Local folder label (example: devth)'
    $dir = Get-TunnelDir $slug
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (Get-CredentialFile $slug) {
        Write-Err "This folder already contains tunnel credentials: $dir"
        Write-Warn 'Use a different folder slug for each tunnel.'
        return
    }
    $certFile = Join-Path $dir 'cert.pem'
    if (-not (Test-Path -LiteralPath $certFile)) {
        Write-Warn "No Cloudflare cert.pem found for $slug."
        if (Confirm 'Run Cloudflare login for this tunnel folder now?' 'Y') { Invoke-Cloudflared $dir @('tunnel', 'login') }
    }
    if (-not (Test-Path -LiteralPath $certFile)) { Write-Err "Cannot create a tunnel without cert.pem in $dir."; return }
    Write-Info "Creating Cloudflare tunnel: $name"
    Invoke-Cloudflared $dir @('tunnel', 'create', $name)
    $credential = Get-CredentialFile $slug
    $id = if ($credential) { Get-TunnelIdFromCredential $credential } else { $null }
    Save-Meta $slug $name $id ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    Refresh-Registry
    $idText = if ($id) { " ($id)" } else { "" }
    Write-Ok "Tunnel created locally as $slug$idText."
    if (Confirm 'Generate config.yaml for this tunnel now?' 'Y') { Generate-ConfigForSlug $slug }
    if (Confirm 'Create DNS routes now?' 'Y') { Create-DnsRoutesForSlug $slug }
    if (Confirm 'Regenerate docker-compose.yml now?' 'Y') { Generate-Compose }
}

function List-Tunnels {
    Section 'Local Tunnels'
    Refresh-Registry
    $slugs = @(Get-RegisteredSlugs)
    if ($slugs.Count -eq 0) { Write-Warn "No local tunnels found in $BaseDir."; return }
    '{0,-22} {1,-24} {2,-38} {3,-18} {4,-12}' -f 'SLUG', 'NAME', 'TUNNEL ID', 'CONFIG', 'CONTAINER' | Write-Host
    '{0,-22} {1,-24} {2,-38} {3,-18} {4,-12}' -f '----', '----', '---------', '------', '---------' | Write-Host
    foreach ($slug in $slugs) {
        $configStatus = if (Test-Path -LiteralPath (Join-Path (Get-TunnelDir $slug) 'config.yaml')) { 'config.yaml' } else { 'missing' }
        $container = "cloudflared_$($slug -replace '-', '_')"
        $containerStatus = 'unknown'
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            & docker info *> $null
            if ($LASTEXITCODE -eq 0) {
                $status = & docker inspect -f '{{.State.Status}}' $container 2>$null
                $containerStatus = if ($LASTEXITCODE -eq 0 -and $status) { $status } else { 'not-created' }
            }
        }
        $id = Get-TunnelId $slug
        if (-not $id) { $id = 'no-id-yet' }
        '{0,-22} {1,-24} {2,-38} {3,-18} {4,-12}' -f $slug, (Get-TunnelName $slug), $id, $configStatus, $containerStatus | Write-Host
    }
    if (Confirm 'Run cloudflared tunnel list from Cloudflare?' 'N') {
        $slug = Select-Tunnel
        if ($slug) { Invoke-Cloudflared (Get-TunnelDir $slug) @('tunnel', 'list') }
    }
}

function Delete-Tunnel {
    Section 'Delete Tunnel'
    if (-not (Require-Docker)) { return }
    $slug = Select-Tunnel
    if (-not $slug) { return }
    $dir = Get-TunnelDir $slug
    $name = Get-TunnelName $slug
    $id = Get-TunnelId $slug
    $container = "cloudflared_$($slug -replace '-', '_')"
    $deleteIdText = if ($id) { " id=$id" } else { "" }
    Write-Warn "Selected local tunnel: $slug ($name)$deleteIdText"
    if (-not (Confirm 'Continue with delete workflow?' 'N')) { return }
    & docker stop $container *> $null
    & docker rm $container *> $null
    if (Confirm 'Delete the Cloudflare tunnel remotely too?' 'N') {
        Invoke-Cloudflared $dir @('tunnel', 'delete', $name)
        if ($LASTEXITCODE -ne 0 -and $id) { Invoke-Cloudflared $dir @('tunnel', 'delete', $id) }
    }
    if (Confirm 'Archive local folder instead of permanent delete?' 'Y') {
        $archive = Join-Path $BackupDir "$slug-deleted-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).zip"
        Compress-Archive -LiteralPath $dir -DestinationPath $archive -Force
        Remove-Item -LiteralPath $dir -Recurse -Force
        Write-Ok "Archived to $archive and removed local folder."
    } elseif (Confirm "Permanently remove $dir?" 'N') {
        Remove-Item -LiteralPath $dir -Recurse -Force
        Write-Ok "Removed $dir."
    }
    Refresh-Registry
    Generate-Compose
}

function Collect-IngressRules {
    $rules = @()
    $defaultService = Prompt-Default 'Default origin service for hostnames' 'http://host.docker.internal:80'
    if (-not (Test-Service $defaultService)) { Write-Err "Invalid service: $defaultService"; return $null }
    Write-Info 'Enter hostnames one by one. Leave blank when finished.'
    while ($true) {
        $hostname = (Read-Host 'Hostname (blank to finish)').Trim()
        if (-not $hostname) { break }
        if (-not (Test-Hostname $hostname)) { Write-Warn "Invalid hostname skipped: $hostname"; continue }
        $service = Prompt-Default "Service for $hostname" $defaultService
        if (-not (Test-Service $service)) { Write-Warn "Invalid service skipped for $hostname: $service"; continue }
        $rules += [pscustomobject]@{ Hostname = $hostname; Service = $service }
    }
    if ($rules.Count -eq 0) { Write-Err 'At least one ingress hostname is required.'; return $null }
    return $rules
}

function Generate-ConfigForSlug([string] $Slug) {
    $dir = Get-TunnelDir $Slug
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $credential = Get-CredentialFile $Slug
    $id = Get-TunnelId $Slug
    if (-not $credential -or -not $id) { Write-Err "No tunnel credential JSON found for $Slug. Create the tunnel first."; return }
    $rules = Collect-IngressRules
    if (-not $rules) { return }
    $config = Join-Path $dir 'config.yaml'
    if (Test-Path -LiteralPath $config) {
        Copy-Item -LiteralPath $config -Destination "$config.bak.$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))" -Force
    }
    $lines = @(
        "tunnel: $id",
        "credentials-file: $ContainerCfDir/$([IO.Path]::GetFileName($credential))",
        '',
        'ingress:'
    )
    foreach ($rule in $rules) {
        $lines += "  - hostname: $($rule.Hostname)"
        $lines += "    service: $($rule.Service)"
    }
    $lines += '  - service: http_status:404'
    $lines | Set-Content -LiteralPath $config -Encoding ASCII
    Write-Ok "Generated $config."
    if (Confirm 'Validate this config with cloudflared?' 'Y') { Invoke-Cloudflared $dir @('tunnel', '--config', "$ContainerCfDir/config.yaml", 'ingress', 'validate') -NoTty }
}

function Generate-Config {
    Section 'Generate config.yaml'
    $slug = Select-Tunnel
    if ($slug) { Generate-ConfigForSlug $slug }
}

function Create-DnsRoutesForSlug([string] $Slug) {
    $dir = Get-TunnelDir $Slug
    $name = Get-TunnelName $Slug
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'cert.pem'))) {
        Write-Warn "No cert.pem found in $dir."
        if (Confirm 'Run Cloudflare login for this tunnel folder now?' 'Y') { Invoke-Cloudflared $dir @('tunnel', 'login') }
    }
    $routeInput = Read-Host 'Hostnames for DNS routes (space or comma separated)'
    $hostnames = @($routeInput -split '[,\s]+' | Where-Object { $_ })
    if ($hostnames.Count -eq 0) { Write-Err 'No hostnames entered.'; return }
    foreach ($hostname in $hostnames) {
        if (-not (Test-Hostname $hostname)) { Write-Warn "Skipping invalid hostname: $hostname"; continue }
        Write-Info "Creating DNS route: $hostname -> $name"
        Invoke-Cloudflared $dir @('tunnel', 'route', 'dns', $name, $hostname)
    }
}

function Create-DnsRoutes {
    Section 'Create DNS Routes'
    if (-not (Require-Docker)) { return }
    $slug = Select-Tunnel
    if ($slug) { Create-DnsRoutesForSlug $slug }
}

function Generate-Compose {
    Section 'Generate docker-compose.yml'
    Refresh-Registry
    $lines = @("version: '3.8'", '', 'services:')
    $any = $false
    foreach ($slug in Get-RegisteredSlugs) {
        $dir = Get-TunnelDir $slug
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'config.yaml'))) { continue }
        $any = $true
        $safeSlug = $slug -replace '-', '_'
        $service = "cf_$safeSlug"
        $container = "cloudflared_$safeSlug"
        $name = Get-TunnelName $slug
        $id = Get-TunnelId $slug
        if (-not $id) { $id = 'unknown' }
        $lines += @(
            "  ${service}:",
            "    image: $CloudflaredImage",
            "    container_name: $container",
            '    restart: unless-stopped',
            '    volumes:',
            "      - ./${slug}:${ContainerCfDir}:ro",
            '    extra_hosts:',
            '      - "host.docker.internal:host-gateway"',
            "    command: tunnel --config ${ContainerCfDir}/config.yaml run",
            '    labels:',
            '      com.cloudflare.tunnel.manager: "true"',
            "      com.cloudflare.tunnel.slug: `"$slug`"",
            "      com.cloudflare.tunnel.name: `"$name`"",
            "      com.cloudflare.tunnel.id: `"$id`"",
            ''
        )
    }
    if (-not $any) {
        $lines += @('  # No tunnel services yet.', '  # Create a tunnel and config.yaml, then regenerate this file.')
        Write-Warn 'No configured tunnels found. Wrote placeholder compose file.'
    } else {
        Write-Ok "Generated $ComposeFile."
    }
    $lines | Set-Content -LiteralPath $ComposeFile -Encoding ASCII
}

function Select-ComposeService([bool] $IncludeAll = $true) {
    Refresh-Registry
    $services = @()
    foreach ($slug in Get-RegisteredSlugs) {
        if (Test-Path -LiteralPath (Join-Path (Get-TunnelDir $slug) 'config.yaml')) { $services += "cf_$($slug -replace '-', '_')" }
    }
    if ($services.Count -eq 0) { Write-Err 'No compose services found. Generate config.yaml and docker-compose.yml first.'; return $null }
    Section 'Select Service'
    if ($IncludeAll) { Write-Host ' 0) All services' }
    for ($i = 0; $i -lt $services.Count; $i++) { '{0,2}) {1}' -f ($i + 1), $services[$i] | Write-Host }
    $choice = Read-Host 'Choose service number'
    if ($IncludeAll -and $choice -eq '0') { return '__all__' }
    $number = 0
    if (-not [int]::TryParse($choice, [ref] $number) -or $number -lt 1 -or $number -gt $services.Count) { Write-Err 'Invalid service selection.'; return $null }
    return $services[$number - 1]
}

function Start-Tunnel {
    Section 'Start Tunnel'
    if (-not (Require-Compose)) { return }
    if (-not (Test-Path -LiteralPath $ComposeFile)) { Generate-Compose }
    $service = Select-ComposeService $true
    if (-not $service) { return }
    Push-Location $BaseDir
    try {
        if ($service -eq '__all__') { Invoke-Compose @('-f', $ComposeFile, 'up', '-d') } else { Invoke-Compose @('-f', $ComposeFile, 'up', '-d', $service) }
    } finally { Pop-Location }
}

function Stop-Tunnel {
    Section 'Stop Tunnel'
    if (-not (Require-Compose)) { return }
    $service = Select-ComposeService $true
    if (-not $service) { return }
    Push-Location $BaseDir
    try {
        if ($service -eq '__all__') { Invoke-Compose @('-f', $ComposeFile, 'stop') } else { Invoke-Compose @('-f', $ComposeFile, 'stop', $service) }
    } finally { Pop-Location }
}

function Restart-Tunnel {
    Section 'Restart Tunnel'
    if (-not (Require-Compose)) { return }
    $service = Select-ComposeService $true
    if (-not $service) { return }
    Push-Location $BaseDir
    try {
        if ($service -eq '__all__') { Invoke-Compose @('-f', $ComposeFile, 'restart') } else { Invoke-Compose @('-f', $ComposeFile, 'restart', $service) }
    } finally { Pop-Location }
}

function View-Logs {
    Section 'View Logs'
    if (-not (Require-Compose)) { return }
    $service = Select-ComposeService $true
    if (-not $service) { return }
    $logArgs = @('-f', $ComposeFile, 'logs', '--tail=200')
    if (Confirm 'Follow logs live?' 'Y') { $logArgs += '-f' }
    if ($service -ne '__all__') { $logArgs += $service }
    Push-Location $BaseDir
    try { Invoke-Compose $logArgs } finally { Pop-Location }
}

function Validate-All {
    Section 'Validation'
    $failures = 0
    if (Require-Docker) { Write-Ok 'Docker is available.' } else { $failures++ }
    $compose = Get-ComposeCommand
    if ($compose) { Write-Ok "Docker Compose is available: $($compose -join ' ')" } else { Write-Warn 'Docker Compose is not available.'; $failures++ }
    Refresh-Registry
    foreach ($slug in Get-RegisteredSlugs) {
        $dir = Get-TunnelDir $slug
        if (Test-Path -LiteralPath (Join-Path $dir 'config.yaml')) {
            Write-Info "Validating config for $slug"
            Invoke-Cloudflared $dir @('tunnel', '--config', "$ContainerCfDir/config.yaml", 'ingress', 'validate') -NoTty
            if ($LASTEXITCODE -ne 0) { $failures++ }
        } else {
            Write-Warn "Missing config.yaml for $slug"
            $failures++
        }
    }
    if ((Test-Path -LiteralPath $ComposeFile) -and $compose) {
        Push-Location $BaseDir
        try { Invoke-Compose @('-f', $ComposeFile, 'config') *> $null; if ($LASTEXITCODE -ne 0) { $failures++ } } finally { Pop-Location }
    }
    if ($failures -eq 0) { Write-Ok 'Validation completed without failures.' } else { Write-Warn "Validation completed with $failures issue(s)." }
}

function Health-Dashboard {
    Section 'Health Dashboard'
    Write-Host "Base directory: $BaseDir"
    Write-Host "Cloudflared image: $CloudflaredImage"
    Write-Host "Timestamp: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    Write-Host ''
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        & docker --version
        & docker info *> $null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Docker daemon is reachable.' } else { Write-Warn 'Docker daemon is not reachable.' }
    } else { Write-Warn 'Docker is not installed.' }
    $compose = Get-ComposeCommand
    if ($compose) { Write-Ok "Compose command: $($compose -join ' ')" } else { Write-Warn 'Compose command not found.' }
    Section 'Disk Usage'
    Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($BaseDir).Substring(0,1)) | Format-Table Name, Used, Free -AutoSize
    Section 'Tunnel Containers'
    Refresh-Registry
    foreach ($slug in Get-RegisteredSlugs) {
        $container = "cloudflared_$($slug -replace '-', '_')"
        $status = 'unknown'
        $restarts = 'unknown'
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            & docker info *> $null
            if ($LASTEXITCODE -eq 0) {
                $statusValue = & docker inspect -f '{{.State.Status}}' $container 2>$null
                $restartValue = & docker inspect -f '{{.RestartCount}}' $container 2>$null
                $status = if ($statusValue) { $statusValue } else { 'not-created' }
                $restarts = if ($restartValue) { $restartValue } else { 'n/a' }
            }
        }
        Write-Host "$container status=$status restarts=$restarts"
    }
    Section 'Recent Compose Status'
    if ((Test-Path -LiteralPath $ComposeFile) -and $compose) {
        Push-Location $BaseDir
        try { Invoke-Compose @('-f', $ComposeFile, 'ps') } finally { Pop-Location }
    } else { Write-Warn 'Compose status unavailable.' }
}

function Backup-Data {
    Section 'Backup'
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $includeCredentials = Confirm 'Include credential JSON files and cert.pem in backup? Store the archive securely.' 'Y'
    $archive = Join-Path $BackupDir "cloudflared-backup-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).zip"
    $stage = Join-Path $env:TEMP "cftm-backup-$([guid]::NewGuid().ToString())"
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        $baseFull = (Get-Item -LiteralPath $BaseDir).FullName.TrimEnd('\')
        $backupFull = (Get-Item -LiteralPath $BackupDir).FullName.TrimEnd('\')
        Get-ChildItem -LiteralPath $BaseDir -File -Recurse -Force | Where-Object {
            -not $_.FullName.StartsWith($backupFull, [StringComparison]::OrdinalIgnoreCase) -and ($includeCredentials -or ($_.Name -ne 'cert.pem' -and $_.Extension -ne '.json'))
        } | ForEach-Object {
            $relative = $_.FullName.Substring($baseFull.Length).TrimStart('\')
            $target = Join-Path $stage $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -Force
        Write-Ok "Backup created: $archive"
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Restore-Data {
    Section 'Restore'
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $archives = @(Get-ChildItem -LiteralPath $BackupDir -Filter '*.zip' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($archives.Count -eq 0) {
        Write-Warn "No backup archives found in $BackupDir."
        $archivePath = (Read-Host 'Enter full path to backup archive, or blank to cancel').Trim()
        if (-not $archivePath) { return }
    } else {
        for ($i = 0; $i -lt $archives.Count; $i++) { '{0,2}) {1}' -f ($i + 1), $archives[$i].Name | Write-Host }
        $choice = Read-Host 'Choose backup number'
        $number = 0
        if (-not [int]::TryParse($choice, [ref] $number) -or $number -lt 1 -or $number -gt $archives.Count) { Write-Err 'Invalid backup selection.'; return }
        $archivePath = $archives[$number - 1].FullName
    }
    if (-not (Test-Path -LiteralPath $archivePath)) { Write-Err "Backup archive not found: $archivePath"; return }
    Write-Warn "Restore will extract files into $BaseDir."
    if (-not (Confirm 'Continue restore?' 'N')) { return }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $BaseDir -Force
    Refresh-Registry
    Write-Ok 'Restore completed.'
}

function Backup-RestoreMenu {
    Section 'Backup / Restore'
    Write-Host '1) Create backup'
    Write-Host '2) Restore backup'
    Write-Host '0) Back'
    switch (Read-Host 'Choose an option') {
        '1' { Backup-Data }
        '2' { Restore-Data }
        '0' { return }
        default { Write-Err 'Invalid option.' }
    }
}

function Nginx-TemplateGenerator {
    Section 'Nginx Template Generator'
    New-Item -ItemType Directory -Force -Path $NginxTemplateDir | Out-Null
    $hostname = Prompt-Required 'Server name / hostname'
    if (-not (Test-Hostname $hostname)) { Write-Err "Invalid hostname: $hostname"; return }
    $upstream = Prompt-Default 'Upstream service URL' 'http://127.0.0.1:3000'
    if ($upstream -notmatch '^https?://\S+$') { Write-Err 'Nginx upstream must be http:// or https://'; return }
    $websocket = Confirm 'Include WebSocket headers?' 'Y'
    $output = Join-Path $NginxTemplateDir "$hostname.conf"
    $lines = @(
        'server {',
        '    listen 80;',
        "    server_name $hostname;",
        '',
        '    client_max_body_size 1024m;',
        '',
        '    location / {',
        "        proxy_pass $upstream;",
        '        proxy_set_header Host $host;',
        '        proxy_set_header X-Real-IP $remote_addr;',
        '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;',
        '        proxy_set_header X-Forwarded-Proto $scheme;',
        '        proxy_read_timeout 3600;',
        '        proxy_send_timeout 3600;'
    )
    if ($websocket) {
        $lines += @(
            '        proxy_http_version 1.1;',
            '        proxy_set_header Upgrade $http_upgrade;',
            '        proxy_set_header Connection "upgrade";'
        )
    }
    $lines += @('    }', '}')
    $lines | Set-Content -LiteralPath $output -Encoding ASCII
    Write-Ok "Generated $output"
    Write-Info 'Copy this template to your Windows or Linux Nginx server configuration as needed.'
}

function Show-MainMenu {
    Clear-Host
    Write-Host "$AppName v$AppVersion" -ForegroundColor Magenta
    Write-Host "Working directory: $BaseDir"
    Write-Host ''
    Write-Host ' 1) Docker setup help'
    Write-Host ' 2) Cloudflare Login'
    Write-Host ' 3) Create Tunnel'
    Write-Host ' 4) List Tunnels'
    Write-Host ' 5) Delete Tunnel'
    Write-Host ' 6) Create DNS Routes'
    Write-Host ' 7) Generate config.yaml'
    Write-Host ' 8) Generate docker-compose.yml'
    Write-Host ' 9) Start Tunnel'
    Write-Host '10) Stop Tunnel'
    Write-Host '11) Restart Tunnel'
    Write-Host '12) View Logs'
    Write-Host '13) Health Dashboard'
    Write-Host '14) Backup / Restore'
    Write-Host '15) Nginx Template Generator'
    Write-Host '16) Validation'
    Write-Host ' 0) Exit'
    Write-Host ''
}

function Pause-Menu { [void](Read-Host 'Press Enter to continue') }

function Main-Loop {
    while ($true) {
        Show-MainMenu
        switch (Read-Host 'Choose an option') {
            '1' { Install-DockerHelp; Pause-Menu }
            '2' { Cloudflare-Login; Pause-Menu }
            '3' { Create-Tunnel; Pause-Menu }
            '4' { List-Tunnels; Pause-Menu }
            '5' { Delete-Tunnel; Pause-Menu }
            '6' { Create-DnsRoutes; Pause-Menu }
            '7' { Generate-Config; Pause-Menu }
            '8' { Generate-Compose; Pause-Menu }
            '9' { Start-Tunnel; Pause-Menu }
            '10' { Stop-Tunnel; Pause-Menu }
            '11' { Restart-Tunnel; Pause-Menu }
            '12' { View-Logs; Pause-Menu }
            '13' { Health-Dashboard; Pause-Menu }
            '14' { Backup-RestoreMenu; Pause-Menu }
            '15' { Nginx-TemplateGenerator; Pause-Menu }
            '16' { Validate-All; Pause-Menu }
            { $_ -in @('0', 'q', 'Q') } { Write-Info 'Goodbye.'; exit 0 }
            default { Write-Err 'Invalid option.'; Pause-Menu }
        }
    }
}

Parse-Args $CliArgs
Init-Paths
Main-Loop
exit 0
