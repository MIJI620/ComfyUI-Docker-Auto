# ComfyUI-experience —— 停止并移除容器(供体验包 GUI 调用)
$Container = 'comfyui-exp'
Write-Host '== 停止容器 =='
docker stop $Container 2>&1 | ForEach-Object { Write-Host $_ }
docker rm $Container 2>&1 | ForEach-Object { Write-Host $_ }
Write-Host 'STOPPED'
