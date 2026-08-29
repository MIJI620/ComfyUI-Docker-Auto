# ============================================================================
# ComfyUI-experience —— 构建镜像并启动一个预设容器(供体验包 GUI 调用)
# 用法:  powershell -File start_comfyui.ps1 <preset>
# 只输出到 stdout, 由 experience.ps1 日志面板实时捕获。
# ============================================================================
param([string]$Preset = 'cpu-noauth')

$AppRoot   = $PSScriptRoot
$ExpRoot   = Split-Path $AppRoot -Parent
$CfgPath   = Join-Path $AppRoot 'comfyui.json'
$Image     = 'comfyui-test'
$Container = 'comfyui-exp'
$Version   = '0.34.0'
$Base      = 'docker.m.daocloud.io/library/python:3.13-slim'

# 0) 确保 Docker 就绪
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host '[ERR] 未检测到 docker 命令, 请先点「修复环境」安装 Docker Desktop。'; exit 1
}
$ready = (& docker version 2>&1 | Out-String)
if ($ready -match 'error|cannot connect|unable') { Write-Host '[ERR] Docker 引擎未就绪, 请先「修复环境」。'; exit 1 }

# 1) 镜像缺失则构建(CPU_ONLY / local / 0.34.0)
$hasImg = (docker image inspect $Image 2>&1 | Out-String) -notmatch 'no such image'
if (-not $hasImg) {
    Write-Host '[build] 未找到本地镜像, 开始构建(CPU, local/0.34.0)。首次下载依赖可能较久, 请耐心...'
    docker build `
        --target local-stage `
        --build-arg COMFYUI_VERSION=$Version `
        --build-arg COMFYUI_CPU_ONLY=1 `
        --build-arg BASE_IMAGE=$Base `
        -f (Join-Path $AppRoot 'docker/Dockerfile') `
        -t $Image $ExpRoot 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { Write-Host '[ERR] 镜像构建失败, 请查看上方日志。'; exit 1 }
} else {
    Write-Host '[build] 已存在镜像, 跳过构建。'
}

# 2) 解析预设端口
$cfg = Get-Content -Raw -LiteralPath $CfgPath -Encoding UTF8 | ConvertFrom-Json
$p = $cfg.presets | Where-Object { $_.name -eq $Preset }
$port = if ($p) { [int]$p.port } else { 8188 }
Write-Host ('[run] 预设=' + $Preset + '  对外端口=' + $port)

# 3) 先清旧容器, 再启动
docker rm -f $Container 2>&1 | Out-Null
$src = $CfgPath.Replace('\', '/')
$runArgs = @(
    'run','-d','--name',$Container,
    '-e',('PRESET=' + $Preset),
    '-e',('EXPOSE_PORT=' + $port),
    '-v',($src + ':/config/comfyui.json:ro'),
    '-p',("$port`:$port"),
    $Image
)
docker @runArgs 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -eq 0) {
    Write-Host ('[ok] 已启动。浏览器访问 http://127.0.0.1:' + $port + '  (按预设, 认证/端口见 README)')
} else {
    Write-Host '[ERR] 容器启动失败, 请查看上方日志。'
}
