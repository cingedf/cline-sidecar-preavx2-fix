<#
  repatch-cline-sidecar.ps1 — 官方 Cline Desktop 更新后一键重打 sidecar 补丁
  ---------------------------------------------------------------------------
  背景：本机 CPU（Intel Pentium Gold 5405U）不支持 AVX2。官方 sidecar 使用 Bun 1.3.13
        标准构建，在该 CPU 上启动即崩溃，表现为“Cline 无法联网/后端不可用”。
        用 Bun 1.4.2 重新编译 sidecar 并替换，即可恢复正常。

  本脚本流程：读取 cline-app.exe 版本 -> 检出对应源码 tag -> bun install -> build:sdk
              -> 编译 sidecar（校验产物版本）-> 关闭进程 -> 备份旧 sidecar -> 替换
              -> 重新启动并验证 sidecar 监听端口与进程存活。

  用法（Win10 PowerShell）：
      powershell -ExecutionPolicy Bypass -File D:\cline-build\repatch-cline-sidecar.ps1

  前置条件：
      D:\cline-build\bun.exe      Bun 1.4.2（构建用）
      D:\cline-build\cline        官方源码（浅克隆，脚本会自动拉取目标 tag）

  注意：脚本会先关闭正在运行的 Cline 与汉化注入器，完成后通过中文版启动器重新启动。
  说明：指定 -PinnedDir 时，补丁会同时写入该固定副本；中文版启动器通过环境变量
        CLINE_CODE_SIDECAR_BIN 指向它，官方更新覆盖安装目录后应用仍可正常启动。
#>
[CmdletBinding()]
param(
    [string]$ClineDir = "D:\Cline",
    [string]$RepoDir  = "D:\cline-build\cline",
    [string]$BunExe   = "D:\cline-build\bun.exe",
    [string]$ChineseLauncher = "D:\cline-zh\launch-silent.vbs",
    [string]$PinnedDir = "D:\cline-zh\bin",
    [string]$Tag = ""
)

$ErrorActionPreference = "Stop"
function Say([string]$m)  { Write-Host ("[repatch] " + $m) -ForegroundColor Cyan }
function Warn([string]$m) { Write-Host ("[repatch] " + $m) -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host ("[repatch] 失败: " + $m) -ForegroundColor Red; exit 1 }

# ---------- 0. 前置检查 ----------
if (-not (Test-Path $BunExe)) { Fail ("找不到 bun.exe：" + $BunExe) }
$appExe = Join-Path $ClineDir "cline-app.exe"
if (-not (Test-Path $appExe)) { Fail ("找不到 " + $appExe) }
if (-not (Test-Path (Join-Path $RepoDir ".git"))) { Fail ("源码目录不是 git 仓库：" + $RepoDir) }

$version = (Get-Item $appExe).VersionInfo.FileVersion.Trim()
if (-not $Tag) { $Tag = "desktop-v" + $version }
$bunVer = (& $BunExe --version).Trim()
Say ("cline-app.exe 版本 = " + $version + "，目标 tag = " + $Tag)
Say ("bun 版本 = " + $bunVer)

$repoSidecar = Join-Path $RepoDir "apps\examples\desktop-app\src-tauri\bin\code-sidecar-x86_64-pc-windows-msvc.exe"

# ---------- 1. 检出对应版本源码 ----------
Say "拉取并检出源码 tag ..."
Push-Location $RepoDir
try {
    git fetch --depth 1 origin ("+refs/tags/" + $Tag + ":refs/tags/" + $Tag) | Out-Null
    git rev-parse --verify --quiet ("refs/tags/" + $Tag) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ("仓库中没有 tag " + $Tag + "（官方可能更换了 tag 命名，请用 -Tag 参数指定）") }
    git checkout -f $Tag | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ("git checkout " + $Tag + " 失败") }
} catch { Pop-Location; Fail $_.Exception.Message }
Pop-Location
Say "源码已切换到 $Tag"

# ---------- 2. 构建环境 ----------
$env:BUILD_MODE = "package"
$env:PATH = (Split-Path $BunExe) + ";" + $env:PATH

Say "bun install ..."
Push-Location $RepoDir
try { & $BunExe install | Out-Null; if ($LASTEXITCODE -ne 0) { throw "bun install 失败" } }
catch { Pop-Location; Fail $_.Exception.Message }
Pop-Location

Say "构建 SDK（build:sdk）..."
Push-Location $RepoDir
try { & $BunExe run build:sdk | Out-Null; if ($LASTEXITCODE -ne 0) { throw "build:sdk 失败" } }
catch { Pop-Location; Fail $_.Exception.Message }
Pop-Location

# ---------- 3. 编译 sidecar ----------
Say "编译 sidecar（目标 bun-windows-x64）..."
Push-Location (Join-Path $RepoDir "apps\examples\desktop-app")
try {
    & $BunExe build ./sidecar/index.ts --compile --target=bun-windows-x64 --no-compile-autoload-dotenv --no-compile-autoload-bunfig --compile-exec-argv=--use-system-ca --outfile $repoSidecar | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sidecar 编译失败" }
} catch { Pop-Location; Fail $_.Exception.Message }
Pop-Location

if (-not (Test-Path $repoSidecar)) { Fail ("编译产物不存在：" + $repoSidecar) }
$newVer = (Get-Item $repoSidecar).VersionInfo.FileVersion.Trim()
$newLen = (Get-Item $repoSidecar).Length
Say ("产物 FileVersion = " + $newVer + "，大小 = " + [math]::Round($newLen/1MB,1) + " MB")
if ($newVer -ne $bunVer) { Fail ("产物版本 " + $newVer + " 与 bun " + $bunVer + " 不一致，为防误替换已中止") }
if ($newLen -lt 100MB) { Fail "产物小于 100MB，疑似不完整，已中止" }

# ---------- 4. 关闭进程 / 备份 / 替换 ----------
Say "关闭 Cline 与汉化注入器 ..."
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object { $_.CommandLine -like "*cline-zh\inject.js*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process -Name cline-app  -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
Get-Process -Name code-sidecar -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
Start-Sleep -Seconds 3

$target = Join-Path $ClineDir "code-sidecar.exe"
if (Test-Path $target) {
    $oldVer = (Get-Item $target).VersionInfo.FileVersion.Trim()
    $bak = Join-Path $ClineDir ("code-sidecar.exe.bak-" + $oldVer)
    if (Test-Path $bak) { Say ("备份已存在，跳过：" + $bak) }
    else { [System.IO.File]::Copy($target, $bak, $true); Say ("旧 sidecar（" + $oldVer + "）已备份 -> " + $bak) }
}
[System.IO.File]::Copy($repoSidecar, $target, $true)
Say ("已替换 " + $target)

# 同步更新固定副本（launch-silent.vbs 通过 CLINE_CODE_SIDECAR_BIN 指向它，
# 官方更新覆盖安装目录时该副本不受影响）
if ($PinnedDir) {
    [System.IO.Directory]::CreateDirectory($PinnedDir) | Out-Null
    $pinned = Join-Path $PinnedDir "code-sidecar.exe"
    [System.IO.File]::Copy($repoSidecar, $pinned, $true)
    Say ("已更新固定副本 " + $pinned)
}

# ---------- 5. 重新启动并验证 ----------
if (Test-Path $ChineseLauncher) {
    Say "通过中文版启动器启动（含调试端口与汉化注入）..."
    Start-Process "wscript.exe" -ArgumentList ('"' + $ChineseLauncher + '"')
} else {
    Warn ("未找到 " + $ChineseLauncher + "，直接启动原版 cline-app.exe")
    Start-Process $appExe | Out-Null
}

Say "验证启动（等待 sidecar 监听端口，最长 60 秒）..."
$deadline = (Get-Date).AddSeconds(60)
$firstPid = $null
$ok = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $side = Get-Process -Name code-sidecar -ErrorAction SilentlyContinue
    if ($side) {
        $proc = $side | Select-Object -First 1
        $listen = Get-NetTCPConnection -State Listen -OwningProcess $proc.Id -ErrorAction SilentlyContinue
        if ($listen) { $ok = $true; $firstPid = $proc.Id; break }
    }
}
if (-not $ok) { Fail "60 秒内未检测到 sidecar 监听端口，请手动检查" }

$ports = (Get-NetTCPConnection -State Listen -OwningProcess $firstPid -ErrorAction SilentlyContinue | Select-Object -ExpandProperty LocalPort | Sort-Object -Unique) -join ", "
Say ("sidecar 运行中（PID " + $firstPid + "），监听端口: " + $ports)
$sidePath = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $firstPid) -ErrorAction SilentlyContinue).ExecutablePath
if ($sidePath) { Say ("sidecar 路径: " + $sidePath) }

Say "稳定性检查（再观察 30 秒，防止崩溃循环）..."
Start-Sleep -Seconds 30
$side2 = Get-Process -Name code-sidecar -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $side2) { Fail "sidecar 已退出，疑似崩溃循环，请检查" }
if ($side2.Id -ne $firstPid) { Fail ("sidecar PID 发生变化（" + $firstPid + " -> " + $side2.Id + "），疑似崩溃重启，请检查") }

$app = Get-Process -Name cline-app -ErrorAction SilentlyContinue
if (-not $app) { Fail "cline-app 未在运行，请手动检查" }

Say ("完成：Cline " + $version + " 已使用 Bun " + $newVer + " 编译的 sidecar 正常启动（PID " + $side2.Id + "）。")
Say "如未看到中文界面，请确认是从 Cline 中文版 快捷方式启动的。"