# ============================================================================
# ComfyUI-experience —— Docker 环境自举(安装/修复 WSL2 + Docker Desktop + 启动引擎)
# 从 TestKit(run_test.ps1) 的 Docker 自举链复制提炼而来, 独立、可复用。
# 用途: 给第一次接触 Docker 的用户(e.g. 体验包)快速把本机 Docker 环境建好。
# 仅 Windows。
#
# 对外:
#  1. 直接运行:  powershell -ExecutionPolicy Bypass -File setup_docker.ps1 [-SkipInstall]
#     -> 自动检测; 缺则装 WSL2/Docker Desktop; 启动引擎; 输出进度到 stdout; exit 0=就绪 / 1=未就绪
#  2. dot-source 后调用:  $ready = Invoke-DockerSetup -SkipInstall:$true
# 所有进度都会打到 stdout(便于上层 GUI / 日志面板实时捕获), 同时写 Write-Host。
# 整体幂等: 装到一半重启后重跑会接着继续。
# ============================================================================
[CmdletBinding()]
param(
    [switch]$SkipInstall
)

# ---- 路径 ----
$ExpRoot = Split-Path $PSScriptRoot -Parent      # 体验包根(ComfyUI-experience/)
$AppRoot = $PSScriptRoot                          # 本脚本所在 app/

# ---- 暴露一个可由 dot-source 调用的函数 ----
function Invoke-DockerSetup {
    [CmdletBinding()]
    param([switch]$sk)
    return (Test-DockerReady)
}

# ---- 日志: 同时输出到 Host 和 stdout(供上层捕获) ----
function Write-Log([string]$msg) {
    $line = ('{0:HH:mm:ss}  {1}' -f (Get-Date), $msg)
    Write-Host $line
    Write-Output $line                                   # stdout, GUI 面板可实时捕获
}
function Write-LogStage([string]$stage, [string]$state, [string]$detail='') {
    Write-Log("[STEP:$stage] [$state] $detail")
}
function Write-Ok([string]$name, [string]$detail='') {
    Write-Log("[OK] $name" + $(if($detail){' | '+$detail}else{''}))
}
function Write-Need([string]$name, [string]$detail='') {
    Write-Log("[NEED] $name" + $(if($detail){' | '+$detail}else{''}))
}

# ---- 辅助执行 ----
function Test-DockerReady {
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
        $o = & docker version --format '{{.Server.Version}}' 2>&1 | Out-String
        return ($LASTEXITCODE -eq 0 -and $o -notmatch 'error|cannot connect|not found')
    } catch { return $false } finally { $ErrorActionPreference = $ea }
}

function Try-Out([string]$exe, [string[]]$argsP) {
    $localEA = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $exe @argsP 2>&1 | Out-String) } catch { return ('(error: ' + $_.Exception.Message + ')') } finally { $ErrorActionPreference = $localEA }
}

# 运行带超时的命令(避免挂起 e.g. wsl 弹窗)。返回 stdout 文本; (TIMEOUT)/(ERR) 表示失败。
function Run-Time([string]$exe, [string[]]$argList, [int]$seconds, [string]$label) {
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $tmpO = Join-Path $env:TEMP ('exp_r_'+[guid]::NewGuid().ToString('n')+'.out')
    $tmpE = $tmpO+'.err'
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argList -RedirectStandardOutput $tmpO -RedirectStandardError $tmpE -PassThru
        $deadline = (Get-Date).AddSeconds($seconds); $timedOut=$false
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 300
            if (-not $p.HasExited -and (Get-Date) -gt $deadline) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}; $timedOut=$true; break }
        }
        $rc = $p.ExitCode
        if ($timedOut) { return '(TIMEOUT)' }
        $o = Get-Content -Raw -LiteralPath $tmpO -ErrorAction SilentlyContinue
        return ($o -replace '\s+',' ').Trim()
    } catch { return '(ERR)' } finally { Remove-Item $tmpO,$tmpE -Force -ErrorAction SilentlyContinue; $ErrorActionPreference=$ea }
}

# ============================================================================
# 主流程: 检测 -> (缺则) 安装 WSL2/Docker Desktop -> 启动引擎 -> 确认就绪
# ============================================================================
function Setup {
    $ready = Test-DockerReady
    if ($ready) {
        Write-Log 'Docker 环境已就绪。'
        return $true
    }

    if ($SkipInstall) {
        Write-Log '未检测到可用的 Docker 且已指定 -SkipInstall: 请先安装 Docker Desktop 并启动, 再运行。'
        return $false
    }

    Write-Log 'Docker 未就绪, 开始自动准备环境(WSL2 + Docker Desktop) ...'

    # ---- A) Windows 可选功能: WSL + VirtualMachinePlatform ----
    Write-Log ''
    Write-LogStage 'prereq' 'RUNNING' 'A) Windows 功能: WSL + VirtualMachinePlatform'
    $featChanged=$false
    try {
        foreach ($feat in @('Microsoft-Windows-Subsystem-Linux','VirtualMachinePlatform')) {
            $s = (dism.exe /online /get-featureinfo /featurename:$feat 2>&1 | Out-String)
            if ($s -match 'State : Enabled') { Write-Log '  已启用: '+$feat }
            else { Write-Log '  启用: '+$feat; dism.exe /online /enable-feature /featurename:$feat /all /norestart | Out-Null; $featChanged=$true }
        }
    } catch { Write-Log ('[WARN] 启用 Windows 功能: ' + $_.Exception.Message) }

    # ---- 检测 Docker Desktop / docker.exe ----
    $ddPath=$null
    foreach ($p in @("$env:ProgramFiles\Docker\Docker\Docker Desktop.exe","$env:LocalAppData\Docker\Docker\Docker Desktop.exe","$env:LocalAppData\Programs\DockerDesktop\Docker Desktop.exe")) { if (Test-Path $p) { $ddPath=$p } }
    $dockerExe=$null
    foreach ($p in @("$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe","$env:LocalAppData\Docker\Docker\resources\bin\docker.exe","$env:LocalAppData\Programs\DockerDesktop\resources\bin\docker.exe")) { if (Test-Path $p) { $dockerExe=$p } }

    # ---- B) WSL2 内核 / 发行版 ----
    Write-Log ''
    Write-LogStage 'prereq' 'RUNNING' 'B) WSL2 内核 / 默认发行版'
    $wslStatus = Run-Time 'wsl' @('--status') 20 'wsl-status'
    Write-Log ('  wsl --status>>' + (($wslStatus -replace '\s+',' ').Trim()))
    if ($wslStatus -notmatch '\(ERR\)|\(TIMEOUT\)') {
        Write-Log '  WSL 正常响应 -> 功能已启用(无需立即重启)。'
    }
    $wp = Run-Time 'cmd' @('/c','echo Y| wsl --install --no-distribution') 120 'wsl-store-install'
    $rc_w = $LASTEXITCODE
    Write-Log ('  wsl --install --no-distribution exit=' + $rc_w)
    $wl = Run-Time 'wsl' @('-l','-q') 20 'wsl-list'
    Write-Log ('  wsl -l -q>>' + (($wl -replace '\s+',' ').Trim()))

    if (($wp -eq '(ERR)') -or ($wp -eq '(TIMEOUT)') -or ($rc_w -ne 0)) {
        Write-Log '  wsl --install 未成功, 尝试用官方 WSL MSI 修复(system component)...'
        $msi = Join-Path $env:TEMP 'wsl.x64.msi'
        $msiUrl = 'https://github.com/microsoft/WSL/releases/download/2.7.12/wsl.2.7.12.0.x64.msi'
        if (-not (Test-Path $msi) -or (Get-Item $msi).Length -lt 1000000) {
            Write-Log '  下载官方 WSL MSI(约 259MB, 可能较慢)...'
            $ea0=$ErrorActionPreference; $ErrorActionPreference='Continue'
            try { & curl.exe -L --fail --retry 3 -o $msi $msiUrl; $c=$LASTEXITCODE } catch { $c=-1 }
            finally { $ErrorActionPreference=$ea0 }
            Write-Log ('  WSL MSI 下载 exit=' + $c)
        }
        if (Test-Path $msi) {
            Write-Log '  静默安装 WSL MSI...'
            try { $p = Start-Process msiexec.exe -ArgumentList @('/i',$msi,'/qn','/norestart') -Wait -PassThru; Write-Log ('  msiexec exit=' + $p.ExitCode) } catch { Write-Log ('  msiexec 错误: ' + $_.Exception.Message) }
        } else {
            Write-Log '[NEED] 无法自动下载 WSL MSI, 请参考官方手动安装后重启再试。'
        }
    }

    # 发行版缺失则装 Ubuntu
    $hasDistro = ($wl -notmatch 'no installed|none|no distributions|error') -and ($wl.Trim().Length -gt 0)
    if (-not $hasDistro) {
        Write-Log '  未检测到 Linux 发行版, 尝试安装 Ubuntu(WSL 后端需要)...'
        $ub = Run-Time 'wsl' @('--install','-d','Ubuntu') 300 'wsl-install-ubuntu'
        if ($ub -eq '(TIMEOUT)' -or $ub -eq '(ERR)') {
            Write-Log '  Store 装 Ubuntu 超时/失败, 尝试官方 rootfs 直接导入 ...'
            $tgz = Join-Path $env:TEMP 'ubuntu-noble-wsl.rootfs.tar.gz'
            $tv  = 'https://cloud-images.ubuntu.com/wsl/releases/noble/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz'
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                $ea2=$ErrorActionPreference; $ErrorActionPreference='Continue'
                try { & curl.exe -L --fail --retry 3 -o $tgz $tv; $r=$LASTEXITCODE } catch { $r=-1 }
                finally { $ErrorActionPreference=$ea2 }
                if ($r -eq 0 -and (Test-Path $tgz)) {
                    Write-Log '  rootfs 已下载, 导入 WSL distro "Ubuntu"...'
                    $imp = Run-Time 'wsl' @('--import','Ubuntu', (Join-Path $env:LOCALAPPDATA 'UbuntuWsl'), $tgz) 300 'wsl-import'
                    Write-Log ('  wsl --import 结果: ' + $imp)
                } else { Write-Log '  [WARN] rootfs 下载/导入亦失败, Docker 仍可自行创建后端。' }
            }
        } else { Write-Log ('  Ubuntu 安装输出: ' + $ub) }
    }

    # ---- 若刚启用 WSL/VM 功能, 需重启 ----
    if ($featChanged) {
        Write-Log ''
        Write-Log '>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>'
        Write-Log '[REBOOT] 已启用 WSL + VirtualMachinePlatform, 只会在重启后生效。'
        Write-Log '  请重启本机后再次运行本工具(幂等, 会继续), 或由上方按钮重新触发。'
        Write-Log '>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>'
        return $false
    }

    # ---- C) Docker Desktop ----
    Write-Log ''
    Write-LogStage 'prereq' 'RUNNING' 'C) Docker Desktop'
    if (-not $dockerExe -and -not $ddPath) {
        $dest = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
        $official = 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe'
        if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1000000) {
            Write-Log '  下载 Docker Desktop 官方安装包(约 500MB, 若慢请耐心)...'
            $ea4=$ErrorActionPreference; $ErrorActionPreference='Continue'
            try { & curl.exe -L --fail --retry 3 -o $dest $official; $dc=$LASTEXITCODE } catch { $dc=-1 }
            finally { $ErrorActionPreference=$ea4 }
            if ($dc -ne 0 -or -not (Test-Path $dest)) {
                Write-Log '[NEED] 无法自动下载 Docker Desktop, 请手动到 docker.com/products/docker-desktop 下载并安装后重启。'
                return $false
            }
        }
        Write-Log '  运行 Docker Desktop 安装包(会出现安装窗口, 请按提示完成并允许重启)...'
        try { $p = Start-Process -FilePath $dest -PassThru -Wait; Write-Log ('  installer exit=' + $p.ExitCode) } catch { Write-Log ('  installer 错误: ' + $_.Exception.Message) }
    } else {
        Write-Log '  Docker Desktop 已安装。'
    }

    # ---- 启动引擎并等待 ----
    if ($ddPath) { Write-Log ('  启动 Docker Desktop: ' + $ddPath); try { Start-Process -FilePath $ddPath } catch { Write-Log '  启动失败: '+$_.Exception.Message } }
    Write-Log '  等待 Docker 引擎就绪(首次 30-120s, 是 WSL VM)...'
    $up=$false
    for ($i=0; $i -lt 90; $i++) { Start-Sleep -Seconds 2; if (Test-DockerReady) { $up=$true; break } }

    if ($up) {
        Write-Log '  Docker 引擎已就绪。'
        return $true
    } else {
        Write-Log '  Docker 引擎未在 3 分钟内就绪。若刚启用 WSL/VM, 请重启本机后重试; 或打开 Docker Desktop 等鲸鱼图标稳定。'
        return $false
    }
}

# ============================================================================
# 直接运行时执行
# ============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    $ok = Setup
    if ($ok) { Write-Log 'READY'; exit 0 } else { exit 1 }
}
