<#
  TW3 캠페인 어드바이저 — 빌드/배포 스크립트 (의존성 0, 순수 PowerShell)
  ------------------------------------------------------------------
  PFH5 pack 포맷은 실제 pack 해부로 도출·검증(-SelfTest, 바이트 일치).
  포맷 상세: docs/pack_format.md

  [배포/활성화 — 커뮤니티 표준 방식]
  로컬 모드는 게임 data\ 폴더에 두면 모드 매니저가 인식한다.
  이 프로젝트는 WH3 Mod Manager(Shazbot/WH3-Mod-Manager, wh3mm.exe)를 사용:
    build -Deploy 로 pack을 data\ 에 복사 → wh3mm 목록에 로컬 모드로 뜸
    → 체크(활성화) → wh3mm 이 used_mods.txt 생성 → Play 로 실행.
  (CA 런처는 워크샵만 나열해 로컬 pack 무시. manifest.txt 편집은 비표준/Steam 검증시 소실 → 사용 안 함.)

  사용법:
    .\build.ps1              # src\ → build\campaign_advisor.pack (빌드만)
    .\build.ps1 -Deploy      # 빌드 + data\ 로 복사 (wh3mm 이 인식)
    .\build.ps1 -Undo        # data\ 에서 제거
    .\build.ps1 -SelfTest    # 패커 정확성 왕복 검증(참조 pack 바이트 일치)
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
  param([object[]]$Entries, [uint32]$Timestamp = 0, [uint32]$PackType = 3)  # 3 = Mod
  $idx = New-Object System.IO.MemoryStream; $iw = New-Object System.IO.BinaryWriter($idx)
  foreach ($e in $Entries) {
    $iw.Write([uint32]$e.Bytes.Length); $iw.Write([byte]0)                    # 크기 + 압축플래그(비압축)
    $iw.Write([System.Text.Encoding]::ASCII.GetBytes($e.Path)); $iw.Write([byte]0)  # 경로 + null
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

# ======================= 메인 =======================
if ($SelfTest) { Invoke-SelfTest; return }

$dst = Join-Path $GameData $OutName

if ($Undo) {
  if (Test-Path $dst) { Remove-Item $dst -Force; Write-Host "[원복] data\$OutName 제거" -ForegroundColor Cyan }
  else { Write-Host "[원복] 이미 없음" }
  return
}

New-Item -ItemType Directory -Force $BuildDir | Out-Null
$outFile = Join-Path $BuildDir $OutName
$entries = New-TWPack -SourceDir $SrcDir -OutFile $outFile     # 타입 3(Mod)
$sz = (Get-Item $outFile).Length
Write-Host ("[빌드] {0} ({1} 파일, {2:N0} bytes, 타입3=Mod)" -f $OutName, $entries.Count, $sz) -ForegroundColor Green
$entries | ForEach-Object { Write-Host ("  + {0}" -f $_.Path) }

if ($Deploy) {
  Copy-Item $outFile $dst -Force
  Write-Host ("[배포] → {0}" -f $dst) -ForegroundColor Cyan
  Write-Host  "[배포] WH3 Mod Manager(wh3mm.exe) 목록에 로컬 모드로 뜸 → 체크 후 Play" -ForegroundColor Cyan
}
