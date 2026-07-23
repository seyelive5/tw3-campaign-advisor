# TW3 어드바이저 — 오프라인 두뇌 테스트 러너 (LuaJIT = Lua 5.1)
# 사용: .\scripts\test.ps1   (게임 불필요, 수 초 내 완료)
$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$LuaJit = "C:\Users\veria\AppData\Local\Programs\LuaJIT\bin\luajit.exe"
if (-not (Test-Path $LuaJit)) { throw "LuaJIT 없음: $LuaJit (winget install DEVCOM.LuaJIT)" }
& $LuaJit (Join-Path $Root "test\run_brain_tests.lua") ($Root -replace '\\','/')
$code = $LASTEXITCODE
Write-Host ("리포트: {0}\test\out_brain_report.txt" -f $Root)
exit $code
