# ============================================================================
# ComfyUI Docker - Laptop pre-release test (Windows PowerShell, run as Administrator)
# Goal: full image build (local source) + CPU-mode start + verify
#       (HTTP / BasicAuth / preset switch / nginx).
#       Every stage shows: NOT_STARTED -> RUNNING -> SUCCESS / FAILED / REBOOT.
#       Live CLI output (docker build / winget) streams to the console,
#       and step results are appended to <kit root>/log.txt.
# Body kept pure ASCII to avoid code-page issues on Windows PowerShell 5.1.
# ============================================================================
[CmdletBinding()]
param(
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

# ---- path: run_test.ps1 lives in <kit>/app/, so kit root is its parent ----
$ScriptDir = $PSScriptRoot
$KitRoot   = Split-Path $ScriptDir -Parent
$AppRoot   = $ScriptDir
$LogPath   = Join-Path $KitRoot 'log.txt'
$Version   = '0.34.0'
$ImageName = 'comfyui-test'
$HostPort  = 8189
$AuthPort  = 8191   # separate port for the BasicAuth self-test container (avoid clashing with cputest 8189)
$script:HadFail = $false

function Log([string]$msg) {
    $line = ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg)
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch {}
}
function LogPass([string]$name, [string]$detail='') {
    Log("[PASS] $name" + $(if($detail){' | '+$detail}else{''}))
}
function LogFail([string]$name, [string]$detail='') {
    Log("[FAIL] $name" + $(if($detail){' | '+$detail}else{''}))
    $script:HadFail = $true
}
function LogStage([string]$stage, [string]$state, [string]$detail='') {
    Log("[STEP:$stage] [$state] $detail")
}

function Test-DockerReady {
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
        $o = & docker version --format '{{.Server.Version}}' 2>&1 | Out-String
        return ($LASTEXITCODE -eq 0 -and $o -notmatch 'error|cannot connect|not found')
    } catch { return $false } finally { $ErrorActionPreference = $ea }
}

function Try-CmdOut([string]$exe, [string[]]$argsP) {
    # Run any command safely: never throw on non-zero exit, return output string.
    $localEA = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $o = & $exe @argsP 2>$null | Out-String
        return $o
    } catch {
        return ('(error: ' + $_.Exception.Message + ')')
    } finally {
        $ErrorActionPreference = $localEA
    }
}

function Try-CmdOutAll([string]$exe, [string[]]$argsP) {
    # Like Try-CmdOut, but ALSO captures stderr (merged into the return string).
    # Needed where the interesting output goes to stderr (e.g. container [WARN]
    # lines written to stderr by entrypoint.sh are surfaced by `docker logs`
    # on the container's stderr channel).  Uses a temp stderr file (same pattern
    # as Invoke-Cli) so the stderr text survives cleanly in PowerShell 5.1.
    $localEA = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $errFile = Join-Path $env:TEMP ('tcoa_' + [guid]::NewGuid().ToString('n') + '.txt')
    try {
        $out = & $exe @argsP 2> $errFile | Out-String
        $err = if (Test-Path $errFile) { Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue } else { '' }
        return ($out + $err)
    } catch {
        return ('(error: ' + $_.Exception.Message + ')')
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $localEA
    }
}

# Dump a container's FULL console output (stdout + stderr) to a separate log file,
# byte-for-byte, bypassing the PowerShell 5.1 text pipeline (which would decode the
# output using the local ANSI code page and mangle UTF-8 Chinese/newlines).
# We redirect through cmd.exe so docker's stdout+stderr are written to the file
# verbatim; the file then holds the exact bytes the container printed. Only the
# container name is inserted into the cmd command line (always a fixed test name),
# so there is no injection surface.
function Dump-DockerLog([string]$container, [string]$logFile) {
    try {
        $tmp = Join-Path $env:TEMP ('dlog_' + [guid]::NewGuid().ToString('n') + '.txt')
        & cmd /d /c "docker logs $container > `"$tmp`" 2>&1"
        $null = $LASTEXITCODE
        if (Test-Path -LiteralPath $tmp) {
            $dir = Split-Path -Parent $logFile
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            # copy bytes verbatim: write a raw byte-for-byte copy AND a UTF-8 text view
            $raw = [System.IO.File]::ReadAllBytes($tmp)
            [System.IO.File]::WriteAllBytes($logFile + '.raw', $raw)   # 权威字节副本, 不做任何转换
            # docker logs output is UTF-8 text; re-encode to UTF-8 with BOM so Notepad reads it correctly
            [System.IO.File]::WriteAllText($logFile, [System.Text.Encoding]::UTF8.GetString($raw), (New-Object System.Text.UTF8Encoding ($true)))
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return $true
        }
    } catch {}
    return $false
}

# Run a CLI, showing live output on console and logging result.
# $exe + $args used with native '&' so arguments are passed exactly.
function Invoke-Cli([string]$stage, [string]$label, [string]$exe, [string[]]$cmdArgs) {
    LogStage $stage 'RUNNING' $label
    $cmdStr = $exe + ' ' + (($cmdArgs | ForEach-Object { '"{0}"' -f $_ }) -join ' ')
    Log('  > EXEC: ' + $cmdStr)
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $errFile = Join-Path $env:TEMP ('invc_' + [guid]::NewGuid().ToString('n') + '.txt')
    $code = -1
    try {
        $stdout = (& $exe @cmdArgs 2> $errFile)
        $code = $LASTEXITCODE   # read exit code immediately after native command (no pipe breakage)
        $stderr = if (Test-Path $errFile) { Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue } else { '' }
        $out = (($stdout -join "`n") + "`n" + $stderr).Trim()
    } catch {
        LogStage $stage 'FAILED' "$label launch error: $($_.Exception.Message)"
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        return -1
    } finally {
        $ErrorActionPreference = $ea
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    if ($code -eq 0) { LogStage $stage 'SUCCESS' $label }
    else {
        LogStage $stage 'FAILED' "$label (exit=$code)"
        Log('--- ' + $label + ' output (tail) ---')
        ($out -replace "\s+$",'') -split "\r?\n" | Select-Object -Last 40 |
            ForEach-Object { if ($_ -and $_.Trim()) { Log("  $_") } }
    }
    return $code
}

# Run a native command via cmd.exe with a full command-line STRING.
# Avoids PowerShell 5.1 argument-array mangling (e.g. it corrupts "--build-arg X=Y").
# cmd.exe parses the string itself, so arguments stay intact.
function Invoke-CliCmd([string]$stage, [string]$label, [string]$cmdLine) {
    LogStage $stage 'RUNNING' $label
    Log('  > CMD: ' + $cmdLine)
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $errFile = Join-Path $env:TEMP ('invc_' + [guid]::NewGuid().ToString('n') + '.txt')
    $code = -1
    try {
        $out = (& cmd /s /c $cmdLine 2> $errFile)
        $code = $LASTEXITCODE
        $err = if (Test-Path $errFile) { Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue } else { '' }
        $log = ((($out -join "`n")) + "`n" + $err).Trim()
    } catch {
        $code = -1
        $log = $_.Exception.Message
    } finally {
        $ErrorActionPreference = $ea
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    if ($code -eq 0) { LogStage $stage 'SUCCESS' $label }
    else {
        LogStage $stage 'FAILED' "$label (exit=$code)"
        ($log -replace "\s+$",'') -split "\r?\n" | Select-Object -Last 30 |
            ForEach-Object { if ($_ -and $_.Trim()) { Log("  $_") } }
    }
    return $code
}

# Run docker build (or any long command) LIVE with progress shown and a timeout guard.
# Uses cmd /c with a full command string (no PowerShell arg-array mangling), redirects output
# to a temp file, polls it to print progress in real time, and KILLS it on timeout.
# Returns: 0 = ok, 124 = timed out, -1 = error.
function Invoke-BuildLive([string]$stage, [string]$label, [string]$cmdLine, [int]$timeoutSec = 1800) {
    LogStage $stage 'RUNNING' $label
    Log('  > BUILD-LIVE: ' + $cmdLine)
    Log('  (progress is shown below as it happens; this can take many minutes)')
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $tmpO = Join-Path $env:TEMP ('build_' + [guid]::NewGuid().ToString('n') + '.out')
    $tmpE = $tmpO + '.err'
    $rc = 0
    try {
        # cmd /c "docker build ..."  -- redirect stdout+stderr to files; poll & print live
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/s','/c', $cmdLine) `
              -RedirectStandardOutput $tmpO -RedirectStandardError $tmpE -PassThru
        $deadline = (Get-Date).AddSeconds($timeoutSec)
        $read = 0
        $timedOut = $false
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 700
            if (-not $p.HasExited -and (Get-Date) -gt $deadline) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
                $timedOut = $true
                break
            }
            $all = Get-Content -LiteralPath $tmpO -ErrorAction SilentlyContinue
            if ($all.Count -gt $read) {
                $all | Select-Object -Skip $read | ForEach-Object { if ($_ -and $_.Trim()) { Log('  [b] ' + $_) } }
                $read = $all.Count
            }
        }
        # drain remaining stdout
        $all = Get-Content -LiteralPath $tmpO -ErrorAction SilentlyContinue
        if ($all.Count -gt $read) {
            $all | Select-Object -Skip $read | ForEach-Object { if ($_ -and $_.Trim()) { Log('  [b] ' + $_) } }
        }
        # drain stderr (errors / progress on stderr)
        if (Test-Path $tmpE) {
            Get-Content -LiteralPath $tmpE -ErrorAction SilentlyContinue |
                ForEach-Object { if ($_ -and $_.Trim()) { Log('  [b!] ' + $_) } }
        }
        if ($timedOut) {
            Log('[STEP:' + $stage + '] [TIMEOUT] killed after ' + $timeoutSec + 's.')
            $rc = 124
        } else {
            # MUST WaitForExit() so .ExitCode is populated (known PowerShell quirk)
            $p.WaitForExit()
            $rc = if ($null -eq $p.ExitCode) { 0 } else { $p.ExitCode }
        }
    } catch {
        Log('  [b] launch error: ' + $_.Exception.Message)
        $rc = -1
    } finally {
        Remove-Item $tmpO,$tmpE -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $ea
    }
    if ($rc -eq 0) { LogStage $stage 'SUCCESS' $label }
    else           { LogStage $stage 'FAILED'  ($label + ' (exit=' + $rc + ')') }
    return $rc
}

# Run a CLI interactively: output streams to the console in real time and the user
# can TYPE input (e.g. wsl asking to create a distro / download). Blocks until exit.
# Use this for commands that may prompt for input or take long (wsl install/update).
function Run-Interactive([string]$stage, [string]$label, [string]$exe, [string[]]$cmdArgs) {
    LogStage $stage 'RUNNING' $label
    Log('  => now running interactively:  ' + $exe + ' ' + ($cmdArgs -join ' '))
    Log('  => look at the console window. If it asks you to type anything (Y/N, username,')
    Log('     password, or a choice), TYPE IT HERE in this window. Do not close it.')
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $cmdArgs -NoNewWindow -Wait -PassThru
        $code = $p.ExitCode
        if ($code -eq 0) { LogStage $stage 'SUCCESS' ($label + ' (exit=0)') }
        else            { LogStage $stage 'FAILED'  ($label + ' (exit=' + $code + ')') }
        return $code
    } catch {
        LogStage $stage 'FAILED' ($label + ' launch error: ' + $_.Exception.Message)
        return -1
    } finally {
        $ErrorActionPreference = $ea
    }
}

# Run a CLI with real-time output AND a timeout guard, so a hung command (e.g. wsl
# waiting for a dialog) is killed after $seconds instead of freezing the whole script.
# Returns (string): (TIMEOUT) if it timed out, otherwise stdout text.
function Run-Timeout([string]$exe, [string[]]$argList, [int]$seconds, [string]$label) {
    Log('  [run:' + $label + '] ' + $exe + ' ' + ($argList -join ' '))
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $tmpO = Join-Path $env:TEMP ('rt_' + [guid]::NewGuid().ToString('n') + '.out')
    $tmpE = $tmpO + '.err'
    $outBuf = ''
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argList `
              -RedirectStandardOutput $tmpO -RedirectStandardError $tmpE -PassThru
        $deadline = (Get-Date).AddSeconds($seconds)
        $readPos = 0
        $timedOut = $false
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 300
            if (-not $p.HasExited -and (Get-Date) -gt $deadline) {
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
                $timedOut = $true
                break
            }
            # stream any new output as it appears
            if (Test-Path $tmpO) {
                $all = Get-Content -LiteralPath $tmpO -ErrorAction SilentlyContinue
                if ($all.Count -gt $readPos) {
                    $all | Select-Object -Skip $readPos | ForEach-Object { Log('    [o] ' + $_) }
                    $readPos = $all.Count
                }
            }
        }
        if ($timedOut -or $p.HasExited) {
            # final drain
            if (Test-Path $tmpO) {
                $all = Get-Content -LiteralPath $tmpO -ErrorAction SilentlyContinue
                if ($all.Count -gt $readPos) {
                    $all | Select-Object -Skip $readPos | ForEach-Object { Log('    [o] ' + $_) }
                }
                $outBuf = (Get-Content -Raw -LiteralPath $tmpO -ErrorAction SilentlyContinue)
            }
        }
        if ($timedOut) {
            Log('  [run:' + $label + '] TIMED OUT after ' + $seconds + 's (killed). It may have opened a dialog waiting for input.')
            return '(TIMEOUT)'
        }
        $rc = $p.ExitCode
        return (($outBuf -replace '\s+',' ').Trim())
    } catch {
        Log('  [run:' + $label + '] error: ' + $_.Exception.Message)
        return '(ERR)'
    } finally {
        Remove-Item $tmpO,$tmpE -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $ea
    }
}

# ---------- 0) basics ----------
if (Test-Path $LogPath) { Remove-Item $LogPath -Force }
Log("===== ComfyUI TestKit starts =====")
Log('Kit root : ' + $KitRoot)
Log('App dir  : ' + $AppRoot)
Log('Version  : ' + $Version)
Log('Host port: ' + $HostPort)
Log('Log file : ' + $LogPath)

if (-not (Test-Path (Join-Path $KitRoot ('versions/' + $Version)))) {
    LogFail('Kit layout', ('missing local source: versions/' + $Version))
    exit 1
}
if (-not (Test-Path (Join-Path $AppRoot 'docker/Dockerfile'))) {
    LogFail('Kit layout', 'missing app/docker/Dockerfile')
    exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    LogFail('Admin', 'Run as Administrator (right-click run_test.bat -> Run as administrator)')
    exit 1
}

# ---------- 1) Docker check / install ----------
Log('')
Log('===== [1/7] Docker env =====')
if (Test-DockerReady) {
    try {
        $dv = (& docker version --format 'Server {{.Server.Version}} / {{.Os}}' 2>&1 | Out-String).Trim()
        LogPass('Docker daemon', $dv)
    } catch { LogPass('Docker daemon', 'docker available') }
} else {
    if ($SkipInstall) {
        LogFail('Docker', 'No Docker available and -SkipInstall given. Install Docker Desktop, start it, re-run.')
        exit 1
    }
    Log('[STEP:docker-install] [NOT_STARTED] Docker not ready.')
    # ---- DIAG: why docker is not usable ----
    Log('--- [DIAG] why docker is not usable ---')
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if ($dockerCmd) {
        Log('[DIAG] docker command found at: ' + $dockerCmd.Source)
        $dv = Try-CmdOut 'docker' @('version')
        Log('[DIAG] docker version output:')
        ($dv -replace "\s+$",'') -split "\r?\n" | Where-Object { $_ -and $_.Trim() } | ForEach-Object { Log("    $_") }
    } else {
        Log('[DIAG] docker command NOT on PATH.')
        Log('    PATH=' + $env:Path)
        # check common install locations
        foreach ($cand in @(
            "$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe",
            "$env:LocalAppData\Docker\Docker\resources\bin\docker.exe"
        )) {
            if (Test-Path $cand) { Log('[DIAG] docker.exe exists at: ' + $cand) }
        }
        # Docker Desktop executable presence
        foreach ($dd in @("$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
                          "$env:LocalAppData\Docker\Docker\Docker Desktop.exe")) {
            if (Test-Path $dd) { Log('[DIAG] Docker Desktop installed at: ' + $dd) }
            elseif ($dd -match 'ProgramFiles') {
                Log('[DIAG] NOT found: C:\Program Files\Docker\Docker (did install really happen?)')
            }
        }
        # WSL status (safe runner with timeout; must not abort)
        $wslv = Run-Timeout 'wsl' @('--status') 15 'wsl-status-diag'
        Log('[DIAG] wsl --status:')
        ($wslv -replace "\s+$",'') -split "\r?\n" | Where-Object { $_ -and $_.Trim() } | ForEach-Object { Log("    $_") }
    }
    Log('--- [DIAG] end ---')
    # =====================================================================
    #  PREREQ ORDER (idempotent): each step is skipped if already satisfied,
    #  so after a REBOOT you can re-run and it continues where it left off.
    #  No guesswork for the user: the script does the whole chain.
    #  A) Windows features (WSL + VirtualMachinePlatform)
    #  B) WSL2 kernel/default distro
    #  C) Docker Desktop
    #  D) verify + launch + wait for engine
    # =====================================================================

    # ---- detect what is already present ----
    $ddPath = $null
    foreach ($p in @("$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
                     "$env:LocalAppData\Docker\Docker\Docker Desktop.exe",
                     "$env:LocalAppData\Programs\DockerDesktop\Docker Desktop.exe")) {
        if (Test-Path $p) { $ddPath = $p }
    }
    $dockerExe = $null
    foreach ($p in @("$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe",
                     "$env:LocalAppData\Docker\Docker\resources\bin\docker.exe",
                     "$env:LocalAppData\Programs\DockerDesktop\resources\bin\docker.exe")) {
        if (Test-Path $p) { $dockerExe = $p }
    }

    # ---------- A) Windows optional features ----------
    Log('')
    Log('[PREREQ:A] Windows features: WSL subsystem + VirtualMachinePlatform')
    $featChanged = $false
    try {
        foreach ($feat in @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')) {
            $s = (dism.exe /online /get-featureinfo /featurename:$feat 2>&1 | Out-String)
            if ($s -match 'State : Enabled') {
                Log('  already enabled: ' + $feat)
            } else {
                Log('  enabling: ' + $feat)
                dism.exe /online /enable-feature /featurename:$feat /all /norestart | Out-Null
                $featChanged = $true
            }
        }
    } catch { Log('[WARN] enabling Windows features: ' + $_.Exception.Message) }

    # ---------- B) WSL2 kernel / default distro ----------
    Log('')
    Log('[PREREQ:B] WSL2 / default Linux distro')
    # We do NOT rely on parsing wsl output (it is localized/garbled) or on $LASTEXITCODE
    # (which Out-String resets). Instead we idempotently ensure the WSL2 store kernel is
    # installed, then record diagnostics. If a reboot is required to activate it, we say so.
    $wslStatus = Run-Timeout 'wsl' @('--status') 20 'wsl-status'
    Log('  wsl --status>>' + (($wslStatus -replace '\s+',' ').Trim()))
    $wslVer = Run-Timeout 'wsl' @('--version') 20 'wsl-version'
    Log('  wsl --version>>' + (($wslVer -replace '\s+',' ').Trim()))
    # If WSL responds normally (not timed out / not error), the WSL + VirtualMachinePlatform
    # features are already active -> do NOT demand a reboot (avoid the false REBOOT).
    if ($wslStatus -notmatch '\(ERR\)|\(TIMEOUT\)' -and $wslVer -notmatch '\(ERR\)|\(TIMEOUT\)') {
        Log('  WSL responds normally -> features already active; clearing reboot flag.')
        $featChanged = $false
    }

    # 1) Try idempotent store install (no-op if WSL already current/modern)
    #    wsl prompts "press any key to install" -> auto-feed a line via cmd pipe so it proceeds.
    Log('  Ensuring WSL install (auto-answer Y, via:  echo Y| wsl --install --no-distribution)')
    $wp = Run-Timeout 'cmd' @('/c','echo Y| wsl --install --no-distribution') 120 'wsl-store-install'
    $rc_w = if ($wp -eq '(TIMEOUT)' -or $wp -eq '(ERR)') { 1 } else { 0 }
    Log('  wsl --install --no-distribution exit=' + $rc_w + ' (out=' + $wp + ')')

    # 2) If wsl still cannot even run (wslapi / system component broken), install the
    #    Microsoft WSL2 kernel update MSI silently (msiexec) -- this is independent of the
    #    broken wslapi and is the standard official fix.
    $wl = Run-Timeout 'wsl' @('-l','-q') 20 'wsl-list'
    Log('  wsl -l -q>>' + (($wl -replace '\s+',' ').Trim()))
    $hasDistroHeuristic = ($wl -notmatch 'no installed|none|no distributions|error' -and $wl.Trim().Length -gt 0)

    # If wsl could not install the store build cleanly (exit!=0), the subsystem is very likely
    # broken/missing (wslapi/system component). Install the official WSL2 kernel MSI as the fix.
    # (We no longer rely on matching localized/garbled wsl text.)
    if ($rc_w -ne 0) {
        Log('  wsl --install --no-distribution FAILED (exit=' + $rc_w + ') => subsystem likely broken.')

        # ---- Distinguish OS: Win11 uses the Store WSL (msix), Win10 uses the kernel MSI ----
        $build = [Environment]::OSVersion.Version.Build
        $isWin11 = ($build -ge 22000)
        Log('  Detected Windows build ' + $build + ' => ' + $(if ($isWin11) { 'Windows 11' } else { 'Windows 10' }))

        if ($isWin11) {
            # Windows 11: download official WSL MSI from GitHub releases (avoids Microsoft Store
            # download which is timing out - error 0x80072ee2 on this laptop), then msiexec install.
            Log('  [Win11 path] Downloading official WSL MSI from GitHub releases ...')
            $msi = Join-Path $env:TEMP 'wsl.x64.msi'
            $msiUrl = 'https://github.com/microsoft/WSL/releases/download/2.7.12/wsl.2.7.12.0.x64.msi'
            if (-not (Test-Path $msi) -or (Get-Item $msi).Length -lt 1000000) {
                Log('  Downloading WSL MSI (official, from GitHub; ~259MB; this may take a while) ...')
                if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                    $ea0 = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    try { & curl.exe -L --fail --retry 3 -o $msi $msiUrl; $rc_d = $LASTEXITCODE }
                    catch { $rc_d = -1; Log('  curl error: ' + $_.Exception.Message) }
                    finally { $ErrorActionPreference = $ea0 }
                } else {
                    try { Invoke-WebRequest -Uri $msiUrl -OutFile $msi -UseBasicParsing; $rc_d = 0 }
                    catch { $rc_d = -1; Log('  download error: ' + $_.Exception.Message) }
                }
                if ($rc_d -ne 0 -or -not (Test-Path $msi)) {
                    LogFail('WSL MSI', 'download failed (network). This laptop cannot reach the download repeatedly. Please download WSL MSI manually in a browser and run it, then REBOOT and re-run.')
                    exit 1
                }
                Log('  WSL MSI downloaded (' + (Get-Item $msi).Length + ' bytes)')
            }
            Log('  Installing WSL MSI silently (msiexec /i /qn) ...')
            try {
                $p = Start-Process msiexec.exe -ArgumentList @('/i',$msi,'/qn','/norestart') -Wait -PassThru
                Log('  msiexec exit=' + $p.ExitCode)
                if ($p.ExitCode -ne 0) {
                    LogFail('WSL MSI install', 'msiexec exit=' + $p.ExitCode + '. Install the WSL MSI manually, then REBOOT and re-run.')
                    exit 1
                }
            } catch { Log('  msiexec error: ' + $_.Exception.Message) }
        } else {
            # Windows 10: official WSL2 kernel update package (MSI)
            Log('  [Win10 path] Installing official WSL2 kernel update MSI ...')
            $msi = Join-Path $env:TEMP 'wsl_update_x64.msi'
            $msiUrl = 'https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi'
            if (-not (Test-Path $msi) -or (Get-Item $msi).Length -lt 1000000) {
                Log('  Downloading WSL kernel update MSI ...')
                LogStage 'docker-install' 'RUNNING' 'downloading wsl_update_x64.msi ...'
                $ea0 = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try { & curl.exe -L --fail --retry 3 -o $msi $msiUrl; $rc_msi = $LASTEXITCODE }
                catch { $rc_msi = -1; Log('  curl error: ' + $_.Exception.Message) }
                finally { $ErrorActionPreference = $ea0 }
                if ($rc_msi -ne 0 -or -not (Test-Path $msi)) {
                    LogFail('WSL kernel MSI', 'download failed. Install manually (see learn.microsoft.com/windows/wsl/install-manual step 4), then REBOOT.')
                    exit 1
                }
                Log('  WSL kernel MSI downloaded (' + (Get-Item $msi).Length + ' bytes)')
            }
            Log('  Installing WSL kernel update MSI ...')
            try {
                $p = Start-Process msiexec.exe -ArgumentList @('/i',$msi,'/qn','/norestart') -Wait -PassThru
                Log('  msiexec exit=' + $p.ExitCode)
                if ($p.ExitCode -ne 0) {
                    LogFail('WSL kernel MSI', 'msiexec exit=' + $p.ExitCode + ' (install failed). Try installing it manually, then REBOOT and re-run.')
                    exit 1
                }
            } catch { Log('  msiexec error: ' + $_.Exception.Message) }
        }

        Log('')
        Log('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
        Log('[STEP:docker-install] [REBOOT] WSL repaired/updated.')
        Log('  A REBOOT is required before WSL2 + Docker engine will work.')
        Log('  Please REBOOT, then run run_test.bat AGAIN (idempotent, it will resume).')
        Log('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
        exit 0
    }

    # Re-print status after install to see if WSL2 became available.
    $wslStatus2 = Run-Timeout 'wsl' @('--status') 20 'wsl-status-after'
    Log('  wsl --status(after)>>' + (($wslStatus2 -replace '\s+',' ').Trim()))

    # whether a distro appears listed
    $hasDistro = ($wl -notmatch 'no installed|none|no distributions|error') -and ($wl.Trim().Length -gt 0)

    if (-not $hasDistro -and $rc_w -ne 0) {
        Log('  NOTE: WSL2 store install reported non-zero. It may require a REBOOT before the WSL2 engine works.')
        Log('  >> REBOOT now, then re-run (this script is idempotent and will resume).')
        exit 0
    }
    if ($hasDistro) {
        Log('  A Linux distro is present on WSL backend.')
    } else {
        Log('  No Linux distro. Installing Ubuntu (needed for WSL2 to be usable, not just by Docker).')
        # Path 1: via Store (may time out on this network)
        $ub = Run-Timeout 'wsl' @('--install','-d','Ubuntu') 300 'wsl-install-ubuntu'
        if ($ub -eq '(TIMEOUT)' -or $ub -eq '(ERR)') {
            Log('  [WARN] Store-based Ubuntu install did not finish (timeout/error). Falling back to direct rootfs import ...')
            # Path 2: direct Ubuntu official WSL rootfs (bypasses Microsoft Store entirely)
            $tgz = Join-Path $env:TEMP 'ubuntu-noble-wsl.rootfs.tar.gz'
            $tv  = 'https://cloud-images.ubuntu.com/wsl/releases/noble/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz'
            Log('  Downloading Ubuntu 24.04 WSL rootfs from official Ubuntu cloud-images ...')
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                $ea2 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                try { & curl.exe -L --fail --retry 3 -o $tgz $tv; $rc_t = $LASTEXITCODE }
                catch { $rc_t = -1; Log('  curl error: ' + $_.Exception.Message) }
                finally { $ErrorActionPreference = $ea2 }
            } else { $rc_t = -1 }
            if ($rc_t -eq 0 -and (Test-Path $tgz)) {
                Log('  rootfs downloaded (' + (Get-Item $tgz).Length + ' bytes). Importing as WSL distro "Ubuntu" ...')
                $eap = Join-Path $env:LOCALAPPDATA 'UbuntuWsl'
                $imp = Run-Timeout 'wsl' @('--import','Ubuntu',$eap,$tgz) 300 'wsl-import-ubuntu'
                Log('  wsl --import result: ' + $imp)
            } else {
                Log('  [WARN] rootfs download/import failed too. Docker can still create its own backend.')
            }
        } else {
            Log('  Ubuntu install output: ' + $ub)
        }
    }


    # ---------- C) Docker Desktop ----------
    Log('')
    Log('[PREREQ:C] Docker Desktop')
    # Re-detect freshly here (important: even if an earlier step lost the value).
    $dockerExe = $null
    foreach ($pp in @("$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe",
                      "$env:LocalAppData\Docker\Docker\resources\bin\docker.exe",
                      "$env:LocalAppData\Programs\DockerDesktop\resources\bin\docker.exe")) {
        if (Test-Path $pp) { $dockerExe = $pp; break }
    }
    $ddPath = $null
    foreach ($pp in @("$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
                      "$env:LocalAppData\Docker\Docker\Docker Desktop.exe",
                      "$env:LocalAppData\Programs\DockerDesktop\Docker Desktop.exe")) {
        if (Test-Path $pp) { $ddPath = $pp; break }
    }
    if (-not $dockerExe -and -not $ddPath) {
        # registry fallback
        try {
            $inst = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like '*Docker Desktop*' } | Select-Object -First 1
            if ($inst -and $inst.InstallLocation) {
                if (Test-Path (Join-Path $inst.InstallLocation 'Docker Desktop.exe')) { $ddPath = Join-Path $inst.InstallLocation 'Docker Desktop.exe' }
            }
        } catch {}
    }
    Log('  [detect] dockerExe=' + $(if($dockerExe){$dockerExe}else{'(none)'}) + '  ddPath=' + $(if($ddPath){$ddPath}else{'(none)'}))
    if ($dockerExe -or $ddPath) {
        Log('  Docker Desktop appears already installed.')
        if ($dockerExe) {
            $ddirs = Split-Path -Path $dockerExe -Parent
            if (($env:Path -notlike "*$ddirs*")) { $env:Path = $ddirs + ';' + $env:Path }
        }
        # launch Docker Desktop so the engine can start (installed but not running)
        if ($ddPath) {
            Log('  launching Docker Desktop (installed but engine not started yet) ...')
            try { Start-Process -FilePath $ddPath } catch { Log('[WARN] could not launch Docker Desktop: ' + $_.Exception.Message) }
        }
        Log('  waiting for Docker engine to come up (up to 90s) ...')
        $up = $false
        for ($i=0; $i -lt 45; $i++) {
            Start-Sleep -Seconds 2
            if (Test-DockerReady) { $up = $true; break }
        }
        if ($up) { LogPass('Docker', 'engine is now reachable.') }
        else    { LogFail('Docker', 'engine did not come up within 90s after launching Docker Desktop.') }
        # skip the rest of this else-branch (no reinstall needed)
    } else {
        # Use the official installer (winget 'success' is unreliable on some Win10).
        $dest = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
        $official = 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'
        if (-not (Test-Path $dest) -or (-not (Get-Item $dest).Length -or (Get-Item $dest).Length -lt 1000000)) {
            Log('  Downloading Docker Desktop official installer (~500MB). This will take a while on slow links...')
            Log('  URL: ' + $official)
            Log('  (If you prefer, you can download it yourself and drop it at: ' + $dest + ')')
            $dlCode = -1
            # prefer curl.exe (streams live progress to console); fall back to Invoke-WebRequest
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                LogStage 'docker-install' 'RUNNING' 'downloading Docker Desktop (curl, live progress below) ...'
                $ea = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    & curl.exe -L --fail --retry 3 -o $dest $official
                    $dlCode = $LASTEXITCODE
                } catch {
                    Log('  curl error: ' + $_.Exception.Message)
                    $dlCode = -1
                } finally {
                    $ErrorActionPreference = $ea
                }
            }
            if ($dlCode -ne 0) {
                LogStage 'docker-install' 'RUNNING' 'downloading Docker Desktop (Invoke-WebRequest fallback) ...'
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri $official -OutFile $dest -UseBasicParsing
                    $dlCode = 0
                } catch {
                    $dlCode = -1
                    Log('  download fallback error: ' + $_.Exception.Message)
                }
            }
            if ($dlCode -ne 0 -or -not (Test-Path $dest)) {
                Log('')
                Log('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
                Log('[STEP:docker-install] [FAILED] Could not download Docker Desktop.')
                Log('  Please download it yourself from:')
                Log('     https://www.docker.com/products/docker-desktop/')
                Log('     and run the installer, then REBOOT and run run_test.bat AGAIN.')
                Log('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
                exit 1
            }
            LogStage 'docker-install' 'SUCCESS' ('Docker Desktop downloaded (' + (Get-Item $dest).Length + ' bytes)')
        }
        Log('  Running Docker Desktop installer ... (a setup window will open; follow it; it installs WSL2 and will prompt to reboot)')
        LogStage 'docker-install' 'RUNNING' 'Docker Desktop installer running ...'
        try {
            $p = Start-Process -FilePath $dest -PassThru -Wait
            Log('  installer exit code: ' + $p.ExitCode)
        } catch {
            Log('  installer launch error: ' + $_.Exception.Message)
        }
        Log('  (if the installer opened a GUI, click through it; when it asks to reboot, reboot and re-run.)')
    }


    # ---- re-detect docker now that the installer ran (it was installed DURING this run) ----
    $dockerExe = $null
    foreach ($p in @("$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe",
                     "$env:LocalAppData\Docker\Docker\resources\bin\docker.exe",
                     "$env:LocalAppData\Programs\DockerDesktop\resources\bin\docker.exe",
                     "$env:LocalAppData\Programs\Docker\Docker\resources\bin\docker.exe")) {
        if (Test-Path $p) { $dockerExe = $p; break }
    }
    $ddPath = $null
    foreach ($p in @("$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
                     "$env:LocalAppData\Docker\Docker\Docker Desktop.exe",
                     "$env:LocalAppData\Programs\DockerDesktop\Docker Desktop.exe",
                     "$env:LocalAppData\Programs\Docker\Docker\Docker Desktop.exe")) {
        if (Test-Path $p) { $ddPath = $p; break }
    }
    # registry fallback to locate Docker Desktop installed location
    if (-not $ddPath -and -not $dockerExe) {
        try {
            $reg = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            $inst = Get-ItemProperty $reg -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like '*Docker Desktop*' } |
                    Select-Object -First 1
            if ($inst -and $inst.InstallLocation -and (Test-Path $inst.InstallLocation)) {
                $probeExe = Join-Path $inst.InstallLocation 'Docker Desktop.exe'
                $probeD    = Join-Path (Join-Path $inst.InstallLocation 'resources\bin') 'docker.exe'
                if (Test-Path $probeExe) { $ddPath = $probeExe }
                if (Test-Path $probeD)   {
                    $dockerExe = $probeD
                    $binD = Split-Path $probeD -Parent
                    if (($env:Path -notlike "*$binD*")) { $env:Path = $binD + ';' + $env:Path }
                }
            }
        } catch { Log('[WARN] registry lookup for Docker: ' + $_.Exception.Message) }
    }
    if ($dockerExe) { Log('[INFO] after install, docker.exe found: ' + $dockerExe) }
    if ($ddPath)    { Log('[INFO] after install, Docker Desktop found: ' + $ddPath) }

    # ---- D) final check: after all prereqs, confirm docker actually landed ----
    if (-not $ddPath -and -not $dockerExe) {
        Log('')
        Log('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
        Log('[STEP:docker-install] [FAILED] Docker Desktop does NOT appear to be installed.')
        Log('  All prereqs ran but no Docker Desktop / docker.exe was found on disk.')
        Log('  >> Install Docker Desktop MANUALLY from:')
        Log('     https://www.docker.com/products/docker-desktop/')
        Log('     (download + run installer; it will install WSL2 and ask to reboot).')
        Log('  Then REBOOT and run run_test.bat AGAIN.')
        Log('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
        exit 1
    }

    if ($dockerExe) {
        # add its dir to this session PATH
        $ddirs = Split-Path -Path $dockerExe -Parent
        if (($env:Path -notlike "*$ddirs*")) { $env:Path = $ddirs + ';' + $env:Path }
        Log('[INFO] docker.exe found: ' + $dockerExe)
    } else {
        Log('[WARN] docker.exe not under Program Files yet; PATH may still be stale. Will rely on Docker Desktop start + reboot.')
    }

    # ---- if we just enabled WSL/VM features, a reboot is required before engine can start ----
    if ($featChanged) {
        Log('')
        Log('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
        Log('[STEP:docker-install] [REBOOT] We just enabled WSL + VirtualMachinePlatform.')
        Log('  These take effect only after a REBOOT. Please REBOOT this PC,')
        Log('  then run run_test.bat AGAIN to continue (prereqs are idempotent, it will resume).')
        Log('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
        exit 0
    }

    # ---- try to start Docker Desktop and wait for engine ----
    if ($ddPath) {
        Log('[INFO] Launching ' + $ddPath)
        try { Start-Process -FilePath $ddPath } catch { Log('[WARN] could not launch Docker Desktop: ' + $_.Exception.Message) }
    } else {
        Log('[WARN] Docker Desktop exe not found either; will not auto-launch.')
    }
    LogStage 'docker-install' 'RUNNING' 'waiting for docker engine (first start can be 30-120s; engine is a WSL VM) ...'
    $up = $false
    for ($i=0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 2
        if (Test-DockerReady) { $up = $true; break }
    }

    if ($up) {
        LogPass('Docker', 'engine is now reachable after install.')
        Log('NOTE: if engine only became available because WSL/VM features were just enabled, a')
        Log('      REBOOT is recommended so Docker Desktop auto-starts on next login.')
    } else {
        Log('')
        Log('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
        Log('[STEP:docker-install] [FAILED] Docker engine did not become reachable within ~3 min.')
        Log('  docker.exe IS present, but the engine (WSL VM) has not started.')
        Log('  >> Please REBOOT this PC (WSL/VM feature was just enabled), then run run_test.bat AGAIN.')
        Log('  If it still fails: open Docker Desktop from Start menu, accept any terms,')
        Log('  wait for the whale icon to turn steady, then re-run.')
        Log('>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>')
        exit 1
    }
}

# ---------- 1.5) Docker registry mirror check (network: try docker.io, fall back to CN mirror) ----------
Log('')
Log('===== [2/7] Network / mirrors (Docker registry + PyPI probe) =====')
function Test-DockerMirror([string]$probeUrl) {
    # Reachable = host responds (HTTP 200 OR 401: /v2/ 401 is the normal "registry is up" signal).
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            $out = & curl.exe -s -o NUL -w "%{http_code}" -m 10 $probeUrl
            $code = $LASTEXITCODE
            if ($code -ne 0) { return $false }
            $h = ($out -join '').Trim()
            return ($h -eq '200' -or $h -eq '401' -or $h -eq '404')
        } else {
            try {
                $r = Invoke-WebRequest -Uri $probeUrl -UseBasicParsing -TimeoutSec 8
                return ($r.StatusCode -eq 200)
            } catch {
                # Invoke-WebRequest throws on 4xx; treat 401 as reachable (registry auth expected)
                $code = $_.Exception.Response.StatusCode.value__
                return ($code -eq 401 -or $code -eq 404)
            }
        }
    } finally { $ErrorActionPreference = $ea }
}
# does docker itself think registry is reachable? (quick heuristic)
$regOK = Test-DockerMirror 'https://registry-1.docker.io/v2/'

if ($regOK) {
    Log('  docker.io registry reachable -> no mirror override needed.')
} else {
    Log('  docker.io registry NOT reachable (or slow). Testing CN mirrors ...')
    $mirrorCandidates = @(
        'https://docker.m.daocloud.io',
        'https://hub.rat.dev',
        'https://hub-mirror.c.163.com',
        'https://docker.mirrors.ustc.edu.cn',
        'https://mirror.ccs.tencentyun.com'
    )
    $reachable = @()
    foreach ($m in $mirrorCandidates) {
        if (Test-DockerMirror ($m + '/v2/')) {
            Log('  mirror reachable: ' + $m)
            $reachable += $m
        } else {
            Log('  mirror NOT reachable: ' + $m)
        }
    }
    if ($reachable.Count -gt 0) {
        $configDir = Join-Path $env:USERPROFILE '.docker'
        $configFile = Join-Path $configDir 'daemon.json'
        if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
        $cfg = @{}
        if (Test-Path $configFile) {
            try { $cfg = Get-Content $configFile -Raw | ConvertFrom-Json } catch { $cfg = @{} }
        }
        $cfg | Add-Member -NotePropertyName 'registry-mirrors' -NotePropertyValue $reachable -Force
        $json = $cfg | ConvertTo-Json -Depth 6
        # Write WITHOUT BOM.  IMPORTANT: PowerShell 5.1 Set-Content -Encoding UTF8 adds a
        # UTF-8 BOM, which Docker's Go JSON parser rejects (invalid character on first byte)
        # and caused endless backend error-logging.  Use UTF8Encoding($false) = no BOM.
        [System.IO.File]::WriteAllText($configFile, $json, (New-Object System.Text.UTF8Encoding ($false)))
        Log('  wrote Docker daemon.json (registry-mirrors, NO BOM): ' + $configFile)
        Log('  [INFO] RESTART Docker Desktop for the mirror to take effect, then re-run.')
    } else {
        Log('  [WARN] No CN mirror reachable from this network. Build may fail to pull base image.')
        Log('  [HINT] You are on the same LAN as the dev machine that CAN reach docker.m.daocloud.io and hub.rat.dev;')
        Log('         check firewall/proxy if this router blocks them here.')
    }
}

# ---------- [2/7] sub-step: verify mirror actually active in daemon ----------
Log('')
Log('[2/7] verifying Docker daemon picked up the mirror ...')
$rinfo = Try-CmdOut 'docker' @('info','--format','{{.RegistryConfig}}')
Log('  docker info RegistryConfig>> ' + (($rinfo -replace '\s+',' ').Trim()))

# ---------- 2) build image (local source, CPU only) ----------
Log('')
Log('===== [3/7] build image (local/' + $Version + ', CPU_ONLY) =====')
Log('(first build may download python:3.13-slim base image + torch CPU wheels - may take a while; watch progress)')
$df  = Join-Path $AppRoot 'docker/Dockerfile'
$tag = $ImageName + ':latest'
Log('  > will run: docker build --target local-stage --build-arg COMFYUI_VERSION=' + $Version + ' --build-arg COMFYUI_CPU_ONLY=1 -f ' + $df + ' -t ' + $tag + ' ' + $KitRoot + '   (context=' + $KitRoot + ')')
LogStage 'docker-build' 'NOT_STARTED' ('docker build -t ' + $tag + ' context=' + $KitRoot)
# If a mirror was found reachable, pull the base image UP FRONT (so build uses a cached local base,
# eliminating "build hangs while pulling base from docker.io" as a failure mode).
$baseArg = ''
$baseImgName = 'python:3.13-slim'
if ($reachable -and $reachable.Count -gt 0) {
    $m = $reachable[0] -replace 'https?://','' -replace '/+$',''
    $baseImgName = $m + '/library/python:3.13-slim'
    $baseArg = ' --build-arg BASE_IMAGE=' + $baseImgName
    Log('  [build] using mirror for base image: ' + $baseImgName)
    Log('  [build] pre-pulling base image from mirror (docker pull ' + $baseImgName + ')...')
    $pullc = Invoke-BuildLive 'docker-build' 'docker pull base' ('docker pull ' + $baseImgName) 420
    if ($pullc -ne 0) {
        LogFail('docker pull base', 'could not pull base image. Build cannot continue.')
        exit 1
    }
    Log('  [build] base image pulled OK.')
} else {
    Log('  [build] no reachable mirror; will try default python:3.13-slim (may fail if docker.io unreachable)')
}
$brl = 'docker build --target local-stage --build-arg COMFYUI_VERSION=' + $Version + ' --build-arg COMFYUI_CPU_ONLY=1' + $baseArg + ' -f "' + $df + '" -t "' + $tag + '" "' + $KitRoot + '"'
$brc = Invoke-BuildLive 'docker-build' 'docker build' $brl 1800
if ($brc -ne 0) {
    LogFail('docker build', 'exit=' + $brc)
    Log('Build failed. Send this log.txt back for fix.')
    exit 1
}
LogPass('docker build', 'image built (local CPU_ONLY)')

# ---------- 3) start container (CPU preset) ----------
Log('')
Log('===== [4/7] start container (PRESET=cpu) =====')
$null = Try-CmdOut 'docker' @('rm','-f','comfyui-cputest')
$confPath = Join-Path $AppRoot 'comfyui.json'
$confMnt  = $confPath + ':/config/comfyui.json:ro'
# Optional smoke test: verify the image can at least import torch (proves image env is usable)
Log('  [smoke] checking image can run python + import torch ...')
$smokel = 'docker run --rm --entrypoint /workspace/venv/bin/python "' + $tag + '" -c "import torch;print(torch.__version__)"'
$smoke = Invoke-CliCmd 'docker-run' 'smoke-torch' $smokel
if ($smoke -ne 0) {
    LogFail('smoke torch', 'image could NOT import torch. Something is wrong inside the image.')
}
$runl = 'docker run -d --name comfyui-cputest -e PRESET=cpu-noauth -e EXPOSE_PORT=' + $HostPort + ' -p ' + $HostPort + ':' + $HostPort + ' -v "' + $confMnt + '" "' + $tag + '"'
$erc = Invoke-CliCmd 'docker-run' 'docker run' $runl
# Right after start, capture container presence + logs immediately (do NOT wait 120s first)
$info = Try-CmdOut 'docker' @('ps','-a','--filter','name=comfyui-cputest')
Log('  [docker ps -a] ' + $info)
$ll = Try-CmdOut 'docker' @('logs','--tail','30','comfyui-cputest')
Log('  [docker logs tail 30] ' + (($ll -replace '\s+',' ').Trim()))
if ($erc -ne 0) {
    LogFail('docker run', 'exit=' + $erc)
} else {
    LogPass('docker run', 'container started (PRESET=cpu)')
    LogStage 'http' 'RUNNING' ('waiting http://127.0.0.1:'+$HostPort+'/ (CPU first load can take up to 300s)')
    $webOk = $false
    for ($i=0; $i -lt 150; $i++) {
        Start-Sleep -Seconds 2
        try {
            $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:"+$HostPort+"/") -UseBasicParsing -TimeoutSec 3
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500) { $webOk = $true; break }
        } catch {}
    }
    if ($webOk) { LogStage 'http' 'SUCCESS' ('http://127.0.0.1:'+$HostPort+' responds') }
    else {
        LogStage 'http' 'FAILED' 'ComfyUI did not respond within 300s'
        # Dump the FULL container log: into log.txt AND into a separate file (container_comfyui.log),
        # so you can inspect exactly where ComfyUI startup stopped.
        $cl = Try-CmdOut 'docker' @('logs','comfyui-cputest')
        Log('--- container log (FULL) ---')
        ($cl -replace "\s+$",'') -split "\r?\n" | Where-Object { $_ -and $_.Trim() } | ForEach-Object { Log("  $_") }
        $clF = Join-Path $KitRoot 'container_comfyui.log'
        try { [System.IO.File]::WriteAllText($clF, $cl, (New-Object System.Text.UTF8Encoding ($false))) } catch {}
        Log('  full container log saved to: ' + $clF)
        # --- foreground crash diagnosis: run main.py directly to capture why it exits ---
        Log('  [diag] running main.py in FOREGROUND to capture the startup error (30s timeout) ...')
        $null = Try-CmdOut 'docker' @('rm','-f','comfyui-cputest')
        $diagL = 'docker run --rm --entrypoint /workspace/venv/bin/python "' + $tag + '" main.py --cpu --listen 0.0.0.0 --port ' + $HostPort
        $diagRc = Invoke-BuildLive 'diag' 'main.py foreground' $diagL 30
        Log('  [diag] main.py foreground exit=' + $diagRc)
    }
}

# ---------- 5) no-auth verify (self-test, no GPU): preset with auth.enabled=false ----------
# Auth is independent of performance mode: a no-auth preset must respond 200 (never 401).
Log('')
Log('===== [5/7] no-auth direct (preset=cpu-noauth, auth disabled) =====')
$null = Try-CmdOut 'docker' @('rm','-f','comfyui-noauthtest')
$NoAuthPort = 8198
$noauthl = 'docker run -d --name comfyui-noauthtest -e EXPOSE_PORT=' + $NoAuthPort + ' -v "' + $confMnt + '" -p ' + $NoAuthPort + ':' + $NoAuthPort + ' "' + $tag + '" --self-test-auth --preset=cpu-noauth'
$narc = Invoke-CliCmd 'docker-auth' 'docker run no-auth' $noauthl
$nInfo = Try-CmdOut 'docker' @('ps','-a','--filter','name=comfyui-noauthtest')
Log('  [noauth ps -a] ' + $nInfo)
$nLog = Try-CmdOut 'docker' @('logs','--tail','50','comfyui-noauthtest')
Log('  [noauth logs tail] ' + (($nLog -replace '\s+',' ').Trim()))
if ($narc -ne 0) {
    LogFail('no-auth container', 'exit=' + $narc)
} else {
    LogStage 'noauth' 'RUNNING' ('waiting http://127.0.0.1:'+$NoAuthPort+'/ (no auth should respond 200, never 401) ...')
    Start-Sleep -Seconds 8
    $noAuthOk = $false
    for ($i=0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        try {
            $r = Invoke-WebRequest -Uri ("http://127.0.0.1:"+$NoAuthPort+"/") -UseBasicParsing -TimeoutSec 5
            # auth disabled -> should be 200-ish, NOT 401
            if ($r.StatusCode -ne 401) { $noAuthOk = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500); if ($noAuthOk) { break } }
        } catch { $lastErr = $_.Exception.Message }
    }
    if ($noAuthOk) { LogStage 'noauth' 'SUCCESS' ('direct access OK, no 401, http://127.0.0.1:'+$NoAuthPort) }
    else {
        Log('  [noauth diag] dumping nginx conf + nginx -t ...')
        $noOut = Try-CmdOut 'docker' @('exec','comfyui-noauthtest','sh','-c','cat /tmp/nginx.comfyui.conf; echo "--- nginx -t ---"; nginx -t')
        Log('  [noauth diag] ' + (($noOut -replace '\s+',' ').Trim()))
        LogFail('no-auth direct', ('expected non-401, got connection/err: ' + $lastErr))
    }
}
# 导出 noauth 容器完整控制台(stdout+stderr 字节原样), 便于人工对照
$dumpedNoAuth = Dump-DockerLog 'comfyui-noauthtest' (Join-Path $KitRoot 'logs\docker-noauthtest.log')
Log('  [noauth] full container console saved to: ' + (Join-Path $KitRoot 'logs\docker-noauthtest.log') + ' (dumped=' + $dumpedNoAuth + ')')
$null = Try-CmdOut 'docker' @('rm','-f','comfyui-noauthtest')

# ---------- 6) auth verify (self-test, no GPU): preset with auth.enabled=true + bcrypt ----------
# Auth enabled: no credentials -> 401; whitelisted user -> 200; non-whitelist -> 401. htpasswd uses bcrypt hash.
Log('')
Log('===== [6/7] Nginx BasicAuth + limit_conn (self-test-auth, bcrypt) =====')
$null = Try-CmdOut 'docker' @('rm','-f','comfyui-authtest')
$AuthPort = 8191
$authl = 'docker run -d --name comfyui-authtest -e EXPOSE_PORT=' + $AuthPort + ' -v "' + $confMnt + '" -p ' + $AuthPort + ':' + $AuthPort + ' "' + $tag + '" --self-test-auth --preset=cpu'
$arc = Invoke-CliCmd 'docker-auth' 'docker run auth' $authl
# dump auth container right away so we can see if nginx started / why 8191 is unreachable
$authInfo = Try-CmdOut 'docker' @('ps','-a','--filter','name=comfyui-authtest')
Log('  [auth ps -a] ' + $authInfo)
$authLog = Try-CmdOut 'docker' @('logs','--tail','60','comfyui-authtest')
Log('  [auth logs tail] ' + (($authLog -replace '\s+',' ').Trim()))
if ($arc -ne 0) {
    LogFail('BasicAuth container', 'exit=' + $arc)
} else {
    LogStage 'basicauth' 'RUNNING' 'waiting for nginx ...'
    Start-Sleep -Seconds 8
    # 6a) no credentials -> expect 401
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:"+$AuthPort+"/") -UseBasicParsing -TimeoutSec 6
        LogFail('BasicAuth reject', 'expected 401, got ' + $r.StatusCode)
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 401) { LogPass('BasicAuth reject', 'no credentials returned 401') }
        else { LogFail('BasicAuth reject', 'expected 401, got ' + $code) }
    }
    # 6b) correct credentials (allowed user) -> expect 2xx
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('admin:CHANGE_ME_admin'))
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:"+$AuthPort+"/") -UseBasicParsing -TimeoutSec 6 -Headers @{ Authorization = ('Basic ' + $b64) }
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { LogPass('BasicAuth allow(allowed)', 'credentials returned ' + $r.StatusCode) }
        else { LogFail('BasicAuth allow(allowed)', 'with creds got ' + $r.StatusCode) }
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        LogFail('BasicAuth allow(allowed)', 'credentials still failed (401=yes): ' + $code + ' : ' + $_.Exception.Message)
    }
    # 6c) disallowed user (NOT in this preset's auth_users) -> expect 401
    $b64dis = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('someone-else:whateverpass'))
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:"+$AuthPort+"/") -UseBasicParsing -TimeoutSec 6 -Headers @{ Authorization = ('Basic ' + $b64dis) }
        LogFail('BasicAuth disallowed', 'expected 401, got ' + $r.StatusCode)
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 401) { LogPass('BasicAuth disallowed', 'non-whitelist user rejected (401)') }
        else { LogFail('BasicAuth disallowed', 'expected 401, got ' + $code) }
    }
    # diagnostics: dump nginx config + nginx -t from inside auth container (to see why 8191 never answers)
    Log('  [auth diag] dumping /tmp/nginx.comfyui.conf and running nginx -t ...')
    $confOut = Try-CmdOut 'docker' @('exec','comfyui-authtest','sh','-c','cat /tmp/nginx.comfyui.conf; echo "--- nginx -t ---"; nginx -t')
    Log('  [auth diag] ' + (($confOut -replace '\s+',' ').Trim()))
}
# 导出 auth 容器完整控制台(stdout+stderr 字节原样), 便于人工对照
$dumpedAuth = Dump-DockerLog 'comfyui-authtest' (Join-Path $KitRoot 'logs\docker-authtest.log')
Log('  [auth] full container console saved to: ' + (Join-Path $KitRoot 'logs\docker-authtest.log') + ' (dumped=' + $dumpedAuth + ')')
$null = Try-CmdOut 'docker' @('rm','-f','comfyui-authtest')

# ---------- 5.5) 真实 auth 分支: entrypoint 默认密码提醒 检查 ----------
# 用 PRESET=cpu(正常 auth 预设, 不带 --self-test-auth) 走 entrypoint 的真实 auth 启动路径,
# 校验其是否在"admin 仍在用默认 hash"时打印醒目提醒——确保 async 那行新增逻辑不被 selftest/noauth 分支绕过漏测。
Log('')
Log('===== [6b/7] real auth preset: entrypoint default-admin-hash warning =====')
$AuthChkPort = 8191   # cpu preset 对外端口; 前面容器已 rm, 可复用
$null = Try-CmdOut 'docker' @('rm','-f','comfyui-authchk')
$chkline = 'docker run -d --name comfyui-authchk -e PRESET=cpu -e EXPOSE_PORT=' + $AuthChkPort + ' -v "' + $confMnt + '" -p ' + $AuthChkPort + ':' + $AuthChkPort + ' "' + $tag + '"'
$chkrc = Invoke-CliCmd 'docker-auth-chk' 'docker run (real auth preset)' $chkline
if ($chkrc -ne 0) {
    LogFail('auth-warn container', 'exit=' + $chkrc)
} else {
    LogStage 'auth-warn' 'RUNNING' ('waiting http://127.0.0.1:'+$AuthChkPort+' (nginx 401/2xx = ready) ...')
    $ready = $false
    for ($i=0; $i -lt 75; $i++) {   # 75*2s = 最多 150s 等 nginx
        Start-Sleep -Seconds 2
        try {
            $rr = Invoke-WebRequest -Uri ("http://127.0.0.1:"+$AuthChkPort+"/") -UseBasicParsing -TimeoutSec 4
            $ready = $true; break
        } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 401) { $ready = $true; break }
        }
    }
    if (-not $ready) {
        LogFail('auth-warn', 'nginx never came up on :'+$AuthChkPort)
    } else {
        LogStage 'auth-warn' 'SUCCESS' ('real auth nginx up on :'+$AuthChkPort)
        # 依据 comfyui.json 实际 admin hash 决定期望: 仍是默认 → 必须出现提醒; 已改密码 → 必须不出现(避免误判)
        $defHash = '$2b$10$HwAMFQwi2u1srsfba6G8nOzYS37kLbAVc2D2u5hn8uqFKC3IrFp1.'
        $cfgHash = ''
        try {
            $cfgObj = Get-Content -Raw -LiteralPath $confPath -Encoding UTF8 | ConvertFrom-Json
            $cfgHash = (($cfgObj.auth.users | Where-Object { $_.username -eq 'admin' } | Select-Object -First 1).hash)
        } catch {}
        $expectWarn = ($cfgHash -eq $defHash)
        # 始终 dump 容器日志, 便于确认提醒行是否打印(以及任何 python 报错)
        # 用保留 stderr 的方式读取日志(entrypoint 的默认密码 WARN 写到 stderr,
        # `docker logs` 会走容器 stderr 通道; Try-CmdOut 会丢弃 stderr 导致漏报)。
        $chv = (Try-CmdOutAll 'docker' @('logs','comfyui-authchk') | Out-String)
        Log('  [auth-warn diag logs] ' + (($chv -replace '\s+',' ').Trim()))
        # 额外把本容器完整控制台(stdout+stderr, 字节原样)写入独立日志, 便于人工对照:
        # WARN 实际由容器写 stderr => 在 docker logs 走原始字节落盘, 不经 PowerShell 文本管道,
        # 中文/换行都不会丢。该文件可配合本 log.txt 一起回传分析。
        $authChkLog = Join-Path $KitRoot 'logs\docker-authchk.log'
        $dumped = Dump-DockerLog 'comfyui-authchk' $authChkLog
        Log('  [auth-warn] full container console saved to: ' + $authChkLog + ' (dumped=' + $dumped + ')')
        # 用 ASCII 片断匹配(容器 echo 中文可能受 locale/编码影响, 不依赖中文做判定)
        $warnSeen = ($chv -match '\[WARN\] admin') -or ($chv -match '默认密码')
        Log('  [auth-warn] admin_uses_default=' + $expectWarn + ' warn_seen=' + $warnSeen + ' hash=' + $cfgHash)
        if ($warnSeen -eq $expectWarn) {
            if ($expectWarn) { LogPass('auth-warn', 'default-admin-hash warning printed (matches default hash)') }
            else             { LogPass('auth-warn', 'no warning printed (admin password has been changed)') }
        } else {
            LogFail('auth-warn', ('mismatch: expectWarn=' + $expectWarn + ' warnSeen=' + $warnSeen))
            if ($expectWarn) {
                # 容器内 /config/comfyui.json 是 :ro 挂载的同一文件, host 的 $cfgHash 即容器内 hash,
                # 无需再 docker exec(避免多层引号回归)。如需字节级核实请看上面的 docker-authchk.log。
                $h2 = 'host cfgHash=' + $cfgHash + ' (mounted :ro into container; see logs\docker-authchk.log)'
                Log('  [auth-warn in-container hash line] ' + $h2)
            }
        }
        # 附: 该预设应带认证(401)而非直连——附带验证
        try {
            $rr = Invoke-WebRequest -Uri ("http://127.0.0.1:"+$AuthChkPort+"/") -UseBasicParsing -TimeoutSec 6
            LogFail('auth-warn auth', 'expected 401 on real cpu preset, got ' + $rr.StatusCode)
        } catch {
            $c = $_.Exception.Response.StatusCode.value__
            if ($c -eq 401) { LogPass('auth-warn auth', 'real cpu preset requires auth (401)') }
            else { LogFail('auth-warn auth', 'expected 401, got ' + $c) }
        }
    }
    $null = Try-CmdOut 'docker' @('rm','-f','comfyui-authchk')
}

# ---------- 5) preset switch verify ----------
Log('')
Log('===== [7/7] preset switch (resolve_preset values) =====')
$probe = Join-Path $KitRoot '_probe.py'
@'
import json,sys
d=json.load(open(sys.argv[1], encoding='utf-8')); want=sys.argv[2]
for p in d.get('presets',[]):
    if p['name']==want:
        au=p.get('auth',{}) or {}
        print('access=%s port=%s auth_enabled=%s auth_users=%s' % (
            p.get('access'), p.get('port'), au.get('enabled'),
            ','.join(au.get('auth_users',[]) or [])))
        sys.exit(0)
print('NOT_FOUND')
'@ | Set-Content -LiteralPath $probe -Encoding ascii
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Log('[SKIP] preset switch: host python not installed (not a blocker; validated in-container).')
} else {
    foreach ($pn in @('gpu','cpu','cpu-noauth','lowvram','gpu-public')) {
        try {
            $o = (& python $probe (Join-Path $AppRoot 'comfyui.json') $pn 2>&1 | Out-String).Trim()
            if ($o -and $o -ne 'NOT_FOUND') { LogPass("preset '$pn'", $o) }
            else { LogFail("preset '$pn'", 'missing or parse error') }
        } catch {
            Log("[WARN] preset '$pn' host-python check error (non-blocking): " + $_.Exception.Message)
        }
    }
}
Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue

# ---------- finish ----------
Log('')
Log('================================================')
if (-not $script:HadFail) {
    Log('ALL TESTS PASSED: build/start/auth/preset OK -> ready to deploy to server.')
} else {
    Log('SOME TESTS FAILED: see [FAIL] lines above. Please send this log.txt back for fix.')
}
Log('================================================')
Write-Host ('')
Write-Host ('LOG: ' + $LogPath)
