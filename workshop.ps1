<#
.SYNOPSIS
Start, pause, restart or stop the standalone Windows simulator workshop.
.EXAMPLE
.\workshop.ps1 start
.EXAMPLE
.\workshop.ps1 start -Controller example
#>
param(
    [ValidateSet('start', 'pause', 'restart', 'stop', 'status', 'logs', 'test', 'help')]
    [string]$Action = 'start',
    [ValidateSet('starter', 'example')][string]$Controller,
    [string]$SimulatorPath,
    [switch]$Follow
)

$ErrorActionPreference = 'Stop'
$runtimePath = Join-Path $PSScriptRoot '.runtime'
$sessionPath = Join-Path $runtimePath 'session.json'
$composeArgs = @('compose', '--project-name', 'autodrive-workshop',
    '--project-directory', $PSScriptRoot, '-f', (Join-Path $PSScriptRoot 'compose.yaml'))

function Invoke-WorkshopCompose {
    & docker @composeArgs @args
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose failed: $args" }
}

if ($Action -eq 'help') {
    Write-Host @'
Start Docker Desktop with Linux containers, then:
  .\workshop.ps1 start                      Open simulator with your controller.py
  .\workshop.ps1 start -Controller example   Run the supplied teaching example
  .\workshop.ps1 pause                      Stop the controller; leave simulator open
  .\workshop.ps1 restart -Controller starter Reload your code and resume
  .\workshop.ps1 stop                       Stop workshop containers and its simulator
  .\workshop.ps1 status                     Inspect containers
  .\workshop.ps1 logs -Follow               Follow controller and bridge logs
  .\workshop.ps1 test                       Run Python checks in an isolated container
start also accepts -SimulatorPath 'C:\path\AutoDRIVE Simulator.exe'.
Save edits before restart. Without -Controller, the previous selection is reused.
'@
    return
}

$session = @{ controller = 'starter'; executable = ''; process_id = 0 }
if (Test-Path -LiteralPath $sessionPath) {
    $saved = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    if ($saved.controller -notin @('starter', 'example')) { throw 'Invalid workshop session file.' }
    $session.controller = $saved.controller
    $session.executable = $saved.executable
    $session.process_id = $saved.process_id
}
if ($Controller) { $session.controller = $Controller }
$previousController = $env:WORKSHOP_CONTROLLER
$env:WORKSHOP_CONTROLLER = if ($session.controller -eq 'example') { 'examples.follow_the_gap' } else { 'controller' }

function Save-WorkshopSession {
    New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
    $session | ConvertTo-Json | Set-Content -LiteralPath $sessionPath -Encoding UTF8
}

function Get-WorkshopSimulator {
    if ($session.process_id -and $session.executable) {
        Get-Process -Id $session.process_id -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $session.executable }
    }
}

try {
    if ($Action -eq 'status') { Invoke-WorkshopCompose ps -a; return }
    if ($Action -eq 'logs') {
        $options = @('--tail', '100')
        if ($Follow) { $options += '--follow' }
        Invoke-WorkshopCompose logs @options controller bridge
        return
    }
    if ($Action -eq 'pause' -or $Action -eq 'stop') {
        # Keep the bridge alive long enough to transmit stopped commands or expire them.
        Invoke-WorkshopCompose stop controller
        Start-Sleep -Milliseconds 700
        if ($Action -eq 'stop') {
            $player = Get-WorkshopSimulator
            if ($player) { $player.CloseMainWindow() | Out-Null }
            Invoke-WorkshopCompose down
            $session.process_id = 0
            Save-WorkshopSession
        }
        Write-Host 'Workshop controller stopped.'
        return
    }
    $engine = & docker info --format '{{.OSType}}'
    if ($LASTEXITCODE -ne 0 -or $engine -ne 'linux') {
        throw 'Start Docker Desktop and select Linux containers, then retry.'
    }
    if ($Action -eq 'test') {
        & docker run --rm --network none --env PYTHONDONTWRITEBYTECODE=1 `
            --volume "${PSScriptRoot}:/workshop:ro" --workdir /workshop --entrypoint python3 `
            autodriveecosystem/autodrive_roboracer_api:2026-icra-practice `
            -m unittest discover -s tests -v
        if ($LASTEXITCODE -ne 0) { throw 'Workshop tests failed.' }
        return
    }
    if ($Action -eq 'restart') {
        $bridge = Invoke-WorkshopCompose ps --status running -q bridge
        if (-not $bridge) { throw 'Start the workshop first: .\workshop.ps1 start' }
        Invoke-WorkshopCompose stop controller
        Start-Sleep -Milliseconds 700
        Invoke-WorkshopCompose up -d --no-deps --force-recreate controller
        Save-WorkshopSession
        Write-Host "Reloaded $($session.controller). Driving resumes when Autonomous is selected."
        return
    }

    $ownBridge = Invoke-WorkshopCompose ps --status running -q bridge
    $listener = Get-NetTCPConnection -LocalPort 4567 -State Listen -ErrorAction SilentlyContinue
    if ($listener -and -not $ownBridge) {
        throw 'Port 4567 is in use. Stop the main project or other simulator bridge first.'
    }
    $ownedPlayer = Get-WorkshopSimulator
    $otherPlayers = @(Get-Process -Name 'AutoDRIVE Simulator' -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_ -and (-not $ownedPlayer -or $_.Id -ne $ownedPlayer.Id) })
    if ($otherPlayers.Count) { throw 'Close the other AutoDRIVE simulator before starting the workshop.' }

    if ($SimulatorPath) {
        $executable = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SimulatorPath)
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "Simulator executable not found: $executable"
        }
    } elseif ($session.executable) {
        $executable = $session.executable
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw 'Saved simulator path is missing. Supply -SimulatorPath or remove .runtime/session.json.'
        }
    } else {
        $executable = Join-Path $runtimePath 'practice\autodrive_simulator\AutoDRIVE Simulator.exe'
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
            $archive = Join-Path $runtimePath 'practice.zip'
            $url = 'https://github.com/AutoDRIVE-Ecosystem/AutoDRIVE-RoboRacer-Sim-Racing/releases/download/2026-icra/autodrive_simulator_practice_windows.zip'
            & curl.exe --fail --location --retry 3 --output $archive $url
            if ($LASTEXITCODE -ne 0) { throw 'Simulator download failed; check the network and retry.' }
            Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $runtimePath 'practice') -Force
            if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
                throw 'Download did not contain the expected simulator. Archive kept for inspection.'
            }
            Remove-Item -LiteralPath $archive
        }
    }
    if ($ownedPlayer -and $ownedPlayer.Path -ne $executable) {
        throw 'Stop the workshop before selecting another simulator executable.'
    }
    Invoke-WorkshopCompose up -d bridge controller
    $session.executable = $executable
    if (-not $ownedPlayer) {
        New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
        $logPath = Join-Path $runtimePath 'simulator.log'
        $player = Start-Process -FilePath $executable -WorkingDirectory (Split-Path -Parent $executable) `
            -WindowStyle Normal -ArgumentList '-screen-fullscreen 0 -screen-width 1280 -screen-height 720 -ip 127.0.0.1 -port 4567 -logFile', ('"' + $logPath + '"') -PassThru
        $session.process_id = $player.Id
    }
    Save-WorkshopSession
    Write-Host "Workshop running with $($session.controller). In Unity select Connection (127.0.0.1:4567) and Autonomous."
    Write-Host 'The starter stays stopped until you implement controller.py. Pause with .\workshop.ps1 pause.'
} finally {
    if ($null -eq $previousController) { Remove-Item Env:WORKSHOP_CONTROLLER -ErrorAction SilentlyContinue }
    else { $env:WORKSHOP_CONTROLLER = $previousController }
}
