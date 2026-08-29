# ============================================================================
# ComfyUI-experience —— Docker 体验包(Windows 可视化引导)
# 给第一次接触 Docker 的用户: 自动建好环境 -> 一键启动 ComfyUI(默认 CPU 无认证)。
# 命令输出进入窗口自带黑色命令行(不弹外部黑窗、不乱码)。
# 布局:
#   行1: 环境状态 + 修复环境(白底黑字按钮)
#   行2: 电脑状态(启动时间/运行/CPU/GPU/当前状态) + 预设下拉 + 启动/停止(单钮, 白底黑字)
#   行3: 黑色命令行(占主体)
# 运行: 管理员双击 experience.bat。仅 Windows。本文件 UTF-8 with BOM。
# ============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ExpRoot   = Split-Path $PSScriptRoot -Parent
$AppRoot   = $PSScriptRoot
$CfgPath   = Join-Path $AppRoot 'comfyui.json'
$SetupFile = Join-Path $AppRoot 'setup_docker.ps1'
$StartFile = Join-Path $AppRoot 'start_comfyui.ps1'
$StopFile  = Join-Path $AppRoot 'stop_comfyui.ps1'

$queue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
$script:bgProc=$null; $script:outFile=$null; $script:errFile=$null
$script:procLogPosO=0; $script:procLogPosE=0

# 控件
$lblEnv=$null; $btnFix=$null
$lblState=$null; $presetCombo=$null; $btnToggle=$null
$logBox=$null

# ---------- 工具 ----------
function Append-Log([string]$msg){ $queue.Enqueue(('{0:HH:mm:ss}  {1}' -f (Get-Date), $msg)) }

function Refresh-EnvStatus {
    $ea=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try {
        $dockerReady = (Get-Command docker -ErrorAction SilentlyContinue) -and
                       (((& docker version 2>&1 | Out-String) -notmatch 'error|cannot connect') -and ($LASTEXITCODE -eq 0))
        if ($dockerReady) { $script:lblEnv.Text='环境状态: 就绪'; $script:lblEnv.ForeColor='Green'; return }
        $de=Get-Command docker -ErrorAction SilentlyContinue; $ws=Get-Command wsl -ErrorAction SilentlyContinue
        if(-not $de -and -not $ws){$script:lblEnv.Text='环境状态: 缺 Docker/WSL → 修复'}
        elseif(-not $de){$script:lblEnv.Text='环境状态: 有WSL缺Docker → 修复'}
        else{$script:lblEnv.Text='环境状态: Docker引擎未启动 → 修复'}
        $script:lblEnv.ForeColor='Red'
    } finally { $ErrorActionPreference=$ea }
}

function Launch-Bg([string]$psFile,[string]$arg=''){
    if($script:bgProc -and (-not $script:bgProc.HasExited)){ Append-Log '上一个操作进行中, 请等待完成。'; return }
    $o=Join-Path $env:TEMP ('exp_o_'+[guid]::NewGuid().ToString('n')+'.log'); $e=Join-Path $env:TEMP ('exp_e_'+[guid]::NewGuid().ToString('n')+'.log')
    $null=[System.IO.File]::WriteAllText($o,''); $null=[System.IO.File]::WriteAllText($e,'')
    $script:outFile=$o; $script:errFile=$e; $script:procLogPosO=0; $script:procLogPosE=0
    $a=@('-NoProfile','-ExecutionPolicy','Bypass','-File','"'+$psFile+'"'); if($arg -ne ''){$a+=('"'+$arg+'"')}
    $script:bgProc=Start-Process -FilePath 'powershell.exe' -ArgumentList $a -RedirectStandardOutput $o -RedirectStandardError $e -PassThru -WindowStyle Hidden
    Append-Log ('> '+[IO.Path]::GetFileName($psFile)+$(if($arg){' '+$arg}else{''}))
}
function Drain-File([string]$path,[string]$kind){
    if($null -eq $path){return}
    try{ if(-not(Test-Path $path)){return}
        $all=Get-Content -LiteralPath $path -ErrorAction SilentlyContinue
        $pos=if($kind -eq 'err'){$script:procLogPosE}else{$script:procLogPosO}
        for($i=$pos;$i -lt $all.Count;$i++){ if($all[$i] -ne ''){ $queue.Enqueue($all[$i]) } }
        if($kind -eq 'err'){$script:procLogPosE=$all.Count}else{$script:procLogPosO=$all.Count}
    }catch{}
}
function Test-Running {
    if(-not(Get-Command docker -ErrorAction SilentlyContinue)){return $false}
    $st=(& docker inspect -f '{{.State.Running}}' comfyui-exp 2>&1|Out-String).Trim()
    return ($st -eq 'true')
}
function Set-StateText {
    $run = if($script:runStatus -eq '运行中'){'运行中'}else{'已停止'}
    if($script:dtStarted){ $script:lblState.Text = ('状态:'+$run+'  启动时间:'+$script:dtStarted.ToString('HH:mm:ss')) }
    else { $script:lblState.Text = '状态:'+$run }
}
# 仅在必要时(启动/停止任务结束后)查询一次容器状态, 更新缓存与按钮文字
function Update-RunStatus {
    $running = $false
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $running = ((& docker ps --filter name=comfyui-exp --format '{{.Names}}' 2>$null | Out-String).Trim() -eq 'comfyui-exp')
    }
    $script:runStatus = if($running){'运行中'}else{'已停止'}
    if($running){ $btnToggle.Text='停止' } else { $btnToggle.Text='启动' }
    Set-StateText
}
function New-WhiteButton([string]$text,[int]$x,[int]$y,[int]$w){
    $b=New-Object System.Windows.Forms.Button; $b.Text=$text; $b.Location=New-Object System.Drawing.Point($x,$y); $b.Size=New-Object System.Drawing.Size($w,28)
    $b.BackColor='White'; $b.ForeColor='Black'
    return $b
}
function New-Label([string]$text,[int]$x,[int]$y){
    $l=New-Object System.Windows.Forms.Label; $l.Text=$text; $l.Location=New-Object System.Drawing.Point($x,$y); $l.AutoSize=$true; $l.ForeColor='White'
    return $l
}

# ---------- 窗体 ----------
$form=New-Object System.Windows.Forms.Form
$form.Text='ComfyUI-experience · Docker 体验包'
$form.ClientSize=New-Object System.Drawing.Size(880,480)
$form.StartPosition='CenterScreen'
$form.BackColor=[System.Drawing.Color]::FromArgb(30,30,30)

# 行1: 环境状态 + 修复环境
$lblEnv = New-Label '环境状态: 检测中...' 12 14
$form.Controls.Add($lblEnv)
$btnFix = New-WhiteButton '修复环境' 778 10 90
$form.Controls.Add($btnFix)

# 行2: 电脑状态(左, 较长) + 预设 + 启动/停止
$lblState = New-Object System.Windows.Forms.Label
$lblState.Text='状态: -'; $lblState.ForeColor='White'
$lblState.Location=New-Object System.Drawing.Point(12,46); $lblState.AutoSize=$false
$lblState.Size=New-Object System.Drawing.Size(528,24)
$form.Controls.Add($lblState)

$lblPre=New-Object System.Windows.Forms.Label
$lblPre.Text='预设:'; $lblPre.ForeColor='White'; $lblPre.Location=New-Object System.Drawing.Point(552,47); $lblPre.AutoSize=$true
$form.Controls.Add($lblPre)
$presetCombo=New-Object System.Windows.Forms.ComboBox
$presetCombo.DropDownStyle='DropDownList'; $presetCombo.Location=New-Object System.Drawing.Point(600,44); $presetCombo.Size=New-Object System.Drawing.Size(170,24)
try{ $cfg=Get-Content -Raw -LiteralPath $CfgPath -Encoding UTF8|ConvertFrom-Json; $nm=@($cfg.presets|%{$_.name}); if($nm.Count){$presetCombo.Items.AddRange([object[]]$nm)} }catch{}
$DefaultPreset = 'cpu-noauth'   # 默认选中: CPU 且不开公网 + 无认证(直连)
if($presetCombo.Items.Count){
    $presetCombo.SelectedItem = $null
    $idx = $presetCombo.Items.IndexOf(([string]$DefaultPreset))
    if($idx -ge 0){ $presetCombo.SelectedIndex = $idx } else { $presetCombo.SelectedIndex = 0 }
}
$form.Controls.Add($presetCombo)
# 下拉展开/收起时暂停/恢复状态刷新(避免点下拉被 CPU/GPU 探测拖慢)
$script:paused=$false
$presetCombo.Add_DropDown({ $script:paused=$true })
$presetCombo.Add_DropDownClosed({ $script:paused=$false })
$btnToggle = New-WhiteButton '启动' 778 42 90
$form.Controls.Add($btnToggle)

# 行3: 黑色命令行(占主体)
$logBox=New-Object System.Windows.Forms.TextBox
$logBox.Multiline=$true; $logBox.ReadOnly=$true
$logBox.BackColor='Black'; $logBox.ForeColor='LimeGreen'
$logBox.ScrollBars='Vertical'; $logBox.Font=New-Object System.Drawing.Font('Consolas',9.5)
$logBox.Location=New-Object System.Drawing.Point(12,112)
$logBox.Size=New-Object System.Drawing.Size(856,330)
$logBox.Anchor='Top,Left,Right,Bottom'
$form.Controls.Add($logBox)

# ---------- 事件 ----------
$btnFix.Add_Click({ $btnFix.Enabled=$false; Append-Log '== 修复环境: 检测并安装/启动 Docker =='; Refresh-EnvStatus; Launch-Bg $SetupFile })
$btnToggle.Add_Click({
    if($btnToggle.Text -eq '启动'){
        $p=$presetCombo.SelectedItem
        if(-not $p){ Append-Log '请先选预设。'; return }
        $btnToggle.Enabled=$false; Append-Log ('== 启动 ComfyUI, 预设='+$p+' =='); $script:dtStarted=Get-Date
        Set-StateText; Launch-Bg $StartFile $p
    } else {
        $btnToggle.Enabled=$false; Append-Log '== 停止容器 =='; $script:dtStarted=$null; Set-StateText; Launch-Bg $StopFile
    }
})

# ---------- 定时器 ----------
$timer=New-Object System.Windows.Forms.Timer
$timer.Interval=500
$timer.Add_Tick({
    if($script:bgProc){
        Drain-File $script:outFile 'out'; Drain-File $script:errFile 'err'
        if($script:bgProc.HasExited){
            Append-Log '(操作完成)'; if(-not $btnFix.Enabled){$btnFix.Enabled=$true}
            $script:bgProc=$null; Refresh-EnvStatus; Update-RunStatus
        }
    }
    # 电脑状态: 用缓存 runStatus(不在 UI 线程反复查 docker, 避免点下拉被拖慢) + CPU/GPU(每3s)
    # 下拉展开时暂停状态刷新
    if(-not $script:paused){
        if($null -eq $script:statTick -or ((Get-Date).Ticks-$script:statTick)/10000000 -ge 3){
            $script:statTick=(Get-Date).Ticks
            $run = if($script:runStatus -eq '运行中'){'运行中'}else{'已停止'}
            $start = if($script:dtStarted){$script:dtStarted.ToString('HH:mm:ss')}else{'-'}
            $up = ''
            if($script:dtStarted){ $up = '运行 '+((Get-Date)-$script:dtStarted).ToString('hh\:mm\:ss') }
            $cpuTxt='-'; if($c=(Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue)){ $cpuTxt=[Math]::Round($c.CounterSamples[0].CookedValue).ToString()+'%' }
            $gpuTxt='N/A'
            if($script:hasGpu){ $gv=(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>$null|Select-Object -First 1); if($gv){$gpuTxt=$gv.Trim()+'%'} else { $script:hasGpu=$false } }
            $script:lblState.Text = ('状态:'+$run+'  启动时间:'+$start+'  '+$up+'  CPU:'+$cpuTxt+'  GPU:'+$gpuTxt)
        }
    }
    $line=$null
    while($queue.TryDequeue([ref]$line)){ $logBox.AppendText($line+"`r`n") }
    $logBox.SelectionStart=$logBox.TextLength; $logBox.ScrollToCaret()
})
$timer.Start()

# ---------- 初始 ----------
$script:runStatus='未知'; $script:statTick=$null; $script:dtStarted=$null
# GPU 探测一次, 有 nvidia-smi 才在后续刷新 GPU%(否则显示 N/A)
$script:hasGpu = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
try{ Refresh-EnvStatus }catch{ $script:lblEnv.Text='环境状态: 检测失败' }
Append-Log '欢迎使用 ComfyUI 体验包! 默认预设 cpu-noauth(CPU 无认证)。'
Append-Log '首次使用: ①点「修复环境」装好Docker → ②选预设 → ③点「启动」。'
Append-Log '浏览器访问 http://127.0.0.1:<预设端口> (认证/端口见 README.md)。'

# 窗口显示后再异步探测容器初始状态(避免首次查 docker 阻塞首屏)
$form.Add_Shown({
    $form.Activate()
    $form.Refresh()
    try { Update-RunStatus } catch {}
})
[void]$form.ShowDialog()
