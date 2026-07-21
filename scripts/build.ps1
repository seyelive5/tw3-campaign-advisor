<#
  TW3 캠페인 어드바이저 — 빌드/배포 스크립트 (의존성 0, 순수 PowerShell)
  ------------------------------------------------------------------
  PFH5 pack 포맷은 실제 pack 해부로 도출·검증(-SelfTest, 바이트 일치).

  [로컬 모드 배포 방식 — 실측으로 결정됨]
  CA 런처는 모드 목록을 "스팀 워크샵 구독"에서만 만든다(launcher.log의 STEAM DATA RAW).
  => %APPDATA%\...\mods\ 에 넣은 로컬 pack은 런처에 안 뜬다.
  대신 게임은 data\manifest.txt 에 등재된 pack을 로드한다. 바닐라 자동로드 스크립트
  (battle_logging.lua 등)도 data_script.pack(타입1) 안에서 이 방식으로 로드된다.
  => 우리 pack을 data\ 에 넣고 manifest.txt 에 등재하면 런처와 무관하게 항상 로드된다.

  사용법:
    .\build.ps1              # src\ → build\campaign_advisor.pack (빌드만)
    .\build.ps1 -Deploy      # 빌드 + data\ 설치 + manifest.txt 등재
    .\build.ps1 -Undo        # data\ pack 제거 + manifest.txt 원복
    .\build.ps1 -SelfTest    # 패커 정확성 왕복 검증
#>
[CmdletBinding()]
param(
  [switch]$Deploy,
  [switch]$Undo,
  [switch]$SelfTest,
  [string]$OutName = "campaign_advisor.pack",
  [string]$GameData = "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data"
)
$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$SrcDir   = Join-Path $ProjectRoot "src"
$BuildDir = Join-Path $ProjectRoot "build"

# --- PFH5 직렬화 -------------------------------------------------------
function Build-PackBytes {
  param([object[]]$Entries, [uint32]$Timestamp = 0, [uint32]$PackType = 3)
  $idx = New-Object System.IO.MemoryStream; $iw = New-Object System.IO.BinaryWriter($idx)
  foreach ($e in $Entries) {
    $iw.Write([uint32]$e.Bytes.Length); $iw.Write([byte]0)
    $iw.Write([System.Text.Encoding]::ASCII.GetBytes($e.Path)); $iw.Write([byte]0)
  }
  $iw.Flush(); $idxBytes = $idx.ToArray(); $iw.Dispose()
  $out = New-Object System.IO.MemoryStream; $ow = New-Object System.IO.BinaryWriter($out)
  $ow.Write([System.Text.Encoding]::ASCII.GetBytes('PFH5'))
  $ow.Write([uint32]$PackType); $ow.Write([uint32]0); $ow.Write([uint32]0)
  $ow.Write([uint32]$Entries.Count); $ow.Write([uint32]$idxBytes.Length); $ow.Write([uint32]$Timestamp)
  $ow.Write($idxBytes); foreach ($e in $Entries) { $ow.Write($e.Bytes) }
  $ow.Flush(); $bytes = $out.ToArray(); $ow.Dispose(); return ,$bytes
}

function Read-Pack {
  param([string]$Path)
  $b = [System.IO.File]::ReadAllBytes($Path)
  $depSize = [BitConverter]::ToUInt32($b,12); $fileCount = [BitConverter]::ToUInt32($b,16); $ts = [BitConverter]::ToUInt32($b,24)
  $pos = 28 + $depSize; $entries = New-Object System.Collections.Generic.List[object]
  for ($i=0; $i -lt $fileCount; $i++) {
    $sz = [BitConverter]::ToUInt32($b,$pos); $pos += 4; $flag = $b[$pos]; $pos += 1
    $start = $pos; while ($b[$pos] -ne 0) { $pos++ }
    $p = [System.Text.Encoding]::ASCII.GetString($b,$start,$pos-$start); $pos++
    $entries.Add([pscustomobject]@{ Path=$p; Size=$sz; Flag=$flag })
  }
  foreach ($e in $entries) { $d = New-Object byte[] $e.Size; if ($e.Size -gt 0){[Array]::Copy($b,$pos,$d,0,$e.Size)}; $e | Add-Member Bytes $d; $pos += $e.Size }
  return [pscustomobject]@{ Timestamp=$ts; Entries=$entries }
}

# --- src → pack ---------------------------------------------------------
function New-TWPack {
  param([string]$SourceDir, [string]$OutFile, [uint32]$Timestamp = 0, [uint32]$PackType = 3)
  $root = (Resolve-Path $SourceDir).Path.TrimEnd('\')
  $files = Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object { $_.FullName.ToLower() }
  if (-not $files) { throw "src에 파일이 없습니다: $root" }
  $entries = foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length + 1) -replace '/', '\'
    [pscustomobject]@{ Path = $rel; Bytes = [System.IO.File]::ReadAllBytes($f.FullName) }
  }
  [System.IO.File]::WriteAllBytes($OutFile, (Build-PackBytes -Entries $entries -Timestamp $Timestamp -PackType $PackType))
  return $entries
}

# --- 자기검증 -----------------------------------------------------------
function Invoke-SelfTest {
  $ref = "C:\Program Files (x86)\Steam\steamapps\workshop\content\1142710\2789858755\@@@bettercameramod.pack"
  if (-not (Test-Path $ref)) { Write-Warning "참조 pack 없음, 건너뜀"; return }
  $orig = [System.IO.File]::ReadAllBytes($ref); $parsed = Read-Pack -Path $ref
  $rebuilt = Build-PackBytes -Entries $parsed.Entries -Timestamp $parsed.Timestamp -PackType 3
  $same = ($orig.Length -eq $rebuilt.Length)
  if ($same) { for ($i=0;$i -lt $orig.Length;$i++){ if($orig[$i] -ne $rebuilt[$i]){$same=$false;break} } }
  if ($same) { Write-Host "[자기검증] OK 바이트 완전 일치" -ForegroundColor Green } else { throw "[자기검증] 불일치" }
}

# --- manifest.txt 등재/원복 --------------------------------------------
function Update-Manifest {
  param([string]$PackName, [long]$Size, [switch]$Remove)
  $mf = Join-Path $GameData "manifest.txt"
  if (-not (Test-Path "$mf.bak")) { Copy-Item $mf "$mf.bak" -Force }   # 최초 1회 원본 백업
  $raw = [System.IO.File]::ReadAllText($mf)
  $eol = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
  $escaped = [regex]::Escape($PackName)
  $raw = [regex]::Replace($raw, "(?m)^$escaped`t[^\r\n]*\r?\n?", "")   # 기존 우리 줄 제거(idempotent)
  if (-not $Remove) {
    if ($raw.Length -gt 0 -and $raw[-1] -ne "`n") { $raw += $eol }
    $raw += "$PackName`t$Size`t1" + $eol
  }
  [System.IO.File]::WriteAllText($mf, $raw)
}

# ======================= 메인 =======================
if ($SelfTest) { Invoke-SelfTest; return }

if ($Undo) {
  $dst = Join-Path $GameData $OutName
  if (Test-Path $dst) { Remove-Item $dst -Force; Write-Host "[원복] data\$OutName 제거" -ForegroundColor Cyan }
  Update-Manifest -PackName $OutName -Size 0 -Remove
  Write-Host "[원복] manifest.txt 에서 등재 제거 완료" -ForegroundColor Cyan
  return
}

New-Item -ItemType Directory -Force $BuildDir | Out-Null
$outFile = Join-Path $BuildDir $OutName
# data\ 로드용은 바닐라 data_script.pack 과 동일하게 타입 1(Release)로 — 자동로드 검증된 방식 그대로
$entries = New-TWPack -SourceDir $SrcDir -OutFile $outFile -PackType 1
$sz = (Get-Item $outFile).Length
Write-Host ("[빌드] {0} ({1} 파일, {2:N0} bytes, 타입1)" -f $OutName, $entries.Count, $sz) -ForegroundColor Green
$entries | ForEach-Object { Write-Host ("  + {0}" -f $_.Path) }

if ($Deploy) {
  $dst = Join-Path $GameData $OutName
  Copy-Item $outFile $dst -Force
  Update-Manifest -PackName $OutName -Size ((Get-Item $dst).Length)
  Write-Host ("[배포] → {0}" -f $dst) -ForegroundColor Cyan
  Write-Host  "[배포] manifest.txt 등재 완료 → 런처 무관하게 항상 로드됨(끄려면 -Undo)" -ForegroundColor Cyan
}
