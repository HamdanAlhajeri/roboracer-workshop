# Run in a fresh PowerShell process. All Docker, download and process calls are mocked.
$ErrorActionPreference = 'Stop'
$workshopRoot = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $workshopRoot ('.runtime\launcher-tests\' + [Guid]::NewGuid().ToString('N') + '\folder with spaces')
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $workshopRoot 'workshop.ps1'), (Join-Path $workshopRoot 'compose.yaml') -Destination $fixture
$fakeExe = Join-Path $fixture 'AutoDRIVE Simulator.exe'
'fixture' | Set-Content -LiteralPath $fakeExe
$launcher = Join-Path $fixture 'workshop.ps1'
$global:workshopCalls = [Collections.Generic.List[object]]::new()
$global:workshopPlayer = $null
$global:workshopPortBusy = $false
$global:workshopBridgeRunning = $false
$global:workshopDockerFailure = $false
$global:workshopDownloads = 0
$global:workshopZip = ''

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Operation, [string]$Message) {
    $failed = $false
    try { & $Operation | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
function global:Start-Sleep { }
function global:Get-NetTCPConnection { if ($global:workshopPortBusy) { return 'listener' } }
function global:Get-Process { param($Name, $Id, $ErrorAction) return $global:workshopPlayer }
function global:Start-Process {
    param($FilePath, $WorkingDirectory, $WindowStyle, $ArgumentList, [switch]$PassThru)
    Assert ($WindowStyle -eq 'Normal') 'Simulator window should be visible'
    $global:workshopPlayer = [pscustomobject]@{ Id = 7654; Path = $FilePath; Closed = $false }
    $global:workshopPlayer | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $this.Closed = $true }
    return $global:workshopPlayer
}
function global:docker {
    $global:workshopCalls.Add([pscustomobject]@{ Args = @($args); Controller = $env:WORKSHOP_CONTROLLER })
    $global:LASTEXITCODE = if ($global:workshopDockerFailure) { 1 } else { 0 }
    if ($global:workshopDockerFailure) { return }
    if ($args[0] -eq 'info') { return 'linux' }
    if ($args -contains 'ps' -and $args -contains '-q' -and $global:workshopBridgeRunning) { return 'fixture-bridge' }
    if ($args -contains 'up') { $global:workshopBridgeRunning = $true }
    if ($args -contains 'down') { $global:workshopBridgeRunning = $false }
}
function global:curl.exe {
    $destination = $args[[Array]::IndexOf($args, '--output') + 1]
    Copy-Item -LiteralPath $global:workshopZip -Destination $destination
    $global:workshopDownloads++
    $global:LASTEXITCODE = 0
}

Push-Location -LiteralPath $workshopRoot
try {
    & $launcher help | Out-Null
    Assert ($global:workshopCalls.Count -eq 0) 'Help contacted Docker'
    $global:workshopPortBusy = $true
    Expect-Failure { & $launcher start -SimulatorPath $fakeExe } 'Occupied port was accepted'
    $global:workshopPortBusy = $false
    Expect-Failure { & $launcher restart } 'Restart created a missing bridge'

    $env:WORKSHOP_CONTROLLER = 'previous-value'
    & $launcher start -SimulatorPath $fakeExe -Controller example | Out-Null
    Assert ($env:WORKSHOP_CONTROLLER -eq 'previous-value') 'Environment was not restored'
    Assert ($global:workshopPlayer.Path -eq $fakeExe) 'Launch from another working directory failed'
    $sessionFile = Join-Path $fixture '.runtime\session.json'
    $session = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json
    Assert ($session.controller -eq 'example') 'Controller selection was not saved'
    $global:workshopCalls.Clear()
    & $launcher restart | Out-Null
    $calls = @($global:workshopCalls | Where-Object { $_.Args -contains 'stop' -or $_.Args -contains 'up' })
    Assert ($calls[0].Args -contains 'stop') 'Reload did not stop old controller first'
    Assert ($calls[1].Args -contains '--no-deps') 'Reload could replace bridge'
    Assert ($calls[1].Controller -eq 'examples.follow_the_gap') 'Reload forgot selected example'
    & $launcher restart -Controller starter | Out-Null
    $session = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json
    Assert ($session.controller -eq 'starter') 'Could not switch back to participant code'
    & $launcher pause | Out-Null
    Assert (-not $global:workshopPlayer.Closed) 'Pause closed the simulator'
    & $launcher stop | Out-Null
    Assert $global:workshopPlayer.Closed 'Stop left owned simulator open'
    $global:workshopPlayer = $null
    $global:workshopDockerFailure = $true
    Expect-Failure { & $launcher status } 'Docker errors were hidden'
    $global:workshopDockerFailure = $false
    Write-Output 'PASS: paths, port ownership, reload, selection, pause, stop and Docker failures'

    # Exercise the real ZIP extraction using a local archive, without downloads.
    Remove-Item -LiteralPath $sessionFile
    $downloadSource = Join-Path $fixture 'download fixture\autodrive_simulator'
    New-Item -ItemType Directory -Path $downloadSource -Force | Out-Null
    'downloaded fixture' | Set-Content -LiteralPath (Join-Path $downloadSource 'AutoDRIVE Simulator.exe')
    $global:workshopZip = Join-Path $fixture 'download.zip'
    Compress-Archive -LiteralPath $downloadSource -DestinationPath $global:workshopZip
    & $launcher start | Out-Null
    Assert ($global:workshopDownloads -eq 1) 'Simulator was not downloaded'
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture '.runtime\practice.zip'))) 'Successful download retained duplicate ZIP'
    & $launcher start | Out-Null
    Assert ($global:workshopDownloads -eq 1) 'Second start downloaded again'
    Write-Output 'PASS: download, extraction and cached runtime reuse'
} finally {
    Pop-Location
    Remove-Item Env:WORKSHOP_CONTROLLER -ErrorAction SilentlyContinue
}
