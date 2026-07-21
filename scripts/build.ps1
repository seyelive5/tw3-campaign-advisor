<#
  TW3 캠페인 어드바이저 — 빌드/패킹 스크립트 (의존성 0, 순수 PowerShell)
  ------------------------------------------------------------------
  PFH5 pack 포맷은 실제 바닐라/워크샵 pack을 해부해 도출·검증한 것이며,
  -SelfTest 로 참조 pack과 바이트 단위 왕복 비교하여 정확성을 증명한다.

  포맷 요약(PFH5, WH3 8.1.1):
    헤더(28B): "PFH5" + 비트마스크/타입(u32) + 의존성수(u32) + 의존성블록크기(u32)
               + 파일수(u32) + 파일인덱스크기(u32) + 타임스탬프(u32)
    인덱스 엔트리: 크기(u32) + 압축플래그(1B, 비압축=0) + 경로(백슬래시, null 종료)
    이후: 파일 데이터 연속

  사용법:
    .\build.ps1              # src\ → build\campaign_advisor.pack
    .\build.ps1 -Deploy      # 빌드 후 유저 mods 폴더로 복사
    .\build.ps1 -SelfTest    # 패커 정확성 왕복 검증
#>
[CmdletBinding()]
param(
  [switch]$Deploy,
  [switch]$SelfTest,
  [string]$OutName = "campaign_advisor.pack",
  [string]$ModsDir = "$env:APPDATA\The Creative Assembly\Warhammer3\mods"
)
$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$SrcDir   = Join-Path $ProjectRoot "src"
$BuildDir = Join-Path $ProjectRoot "build"

# --- PFH5 직렬화 (핵심) -------------------------------------------------
function Build-PackBytes {
  param([object[]]$Entries, [uint32]$Timestamp = 0, [uint32]$PackType = 3)
  $idx = New-Object System.IO.MemoryStream
  $iw  = New-Object System.IO.BinaryWriter($idx)
  foreach ($e in $Entries) {
    $iw.Write([uint32]$e.Bytes.Length)                              # 크기
    $iw.Write([byte]0)                                              # 압축 플래그(비압축)
    $iw.Write([System.Text.Encoding]::ASCII.GetBytes($e.Path))     # 경로
    $iw.Write([byte]0)                                             # null 종료
  }
  $iw.Flush(); $idxBytes = $idx.ToArray(); $iw.Dispose()

  $out = New-Object System.IO.MemoryStream
  $ow  = New-Object System.IO.BinaryWriter($out)
  $ow.Write([System.Text.Encoding]::ASCII.GetBytes('PFH5'))
  $ow.Write([uint32]$PackType)        # 3 = Mod, 상위 플래그 없음
  $ow.Write([uint32]0)                # 의존성 개수
  $ow.Write([uint32]0)                # 의존성 블록 크기
  $ow.Write([uint32]$Entries.Count)   # 파일 수
  $ow.Write([uint32]$idxBytes.Length) # 파일 인덱스 크기
  $ow.Write([uint32]$Timestamp)       # 타임스탬프
  $ow.Write($idxBytes)
  foreach ($e in $Entries) { $ow.Write($e.Bytes) }
  $ow.Flush(); $bytes = $out.ToArray(); $ow.Dispose()
  return ,$bytes
}

# --- pack 읽기(파서: 자기검증/디버깅용) ---------------------------------
function Read-Pack {
  param([string]$Path)
  $b = [System.IO.File]::ReadAllBytes($Path)
  $depSize   = [BitConverter]::ToUInt32($b,12)
  $fileCount = [BitConverter]::ToUInt32($b,16)
  $ts        = [BitConverter]::ToUInt32($b,24)
  $pos = 28 + $depSize
  $entries = New-Object System.Collections.Generic.List[object]
  for ($i=0; $i -lt $fileCount; $i++) {
    $sz = [BitConverter]::ToUInt32($b,$pos); $pos += 4
    $flag = $b[$pos]; $pos += 1
    $start = $pos; while ($b[$pos] -ne 0) { $pos++ }
    $p = [System.Text.Encoding]::ASCII.GetString($b,$start,$pos-$start); $pos++
    $entries.Add([pscustomobject]@{ Path=$p; Size=$sz; Flag=$flag; DataOffset=0 })
  }
  foreach ($e in $entries) {
    $data = New-Object byte[] $e.Size
    if ($e.Size -gt 0) { [Array]::Copy($b, $pos, $data, 0, $e.Size) }
    $e | Add-Member -NotePropertyName Bytes -NotePropertyValue $data
    $pos += $e.Size
  }
  return [pscustomobject]@{ Timestamp=$ts; Entries=$entries }
}

# --- src 디렉터리 → pack 빌드 -------------------------------------------
function New-TWPack {
  param([string]$SourceDir, [string]$OutFile, [uint32]$Timestamp = 0)
  $root = (Resolve-Path $SourceDir).Path.TrimEnd('\')
  $files = Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object { $_.FullName.ToLower() }
  if (-not $files) { throw "src에 파일이 없습니다: $root" }
  $entries = foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length + 1) -replace '/', '\'
    [pscustomobject]@{ Path = $rel; Bytes = [System.IO.File]::ReadAllBytes($f.FullName) }
  }
  $bytes = Build-PackBytes -Entries $entries -Timestamp $Timestamp
  [System.IO.File]::WriteAllBytes($OutFile, $bytes)
  return $entries
}

# --- 자기검증: 참조 pack 재패킹 → 바이트 비교 ---------------------------
function Invoke-SelfTest {
  $ref = "C:\Program Files (x86)\Steam\steamapps\workshop\content\1142710\2789858755\@@@bettercameramod.pack"
  if (-not (Test-Path $ref)) { Write-Warning "참조 pack 없음, 자기검증 건너뜀: $ref"; return }
  $orig = [System.IO.File]::ReadAllBytes($ref)
  $parsed = Read-Pack -Path $ref
  # 원본 순서/타임스탬프 그대로 재직렬화
  $rebuilt = Build-PackBytes -Entries $parsed.Entries -Timestamp $parsed.Timestamp
  $same = ($orig.Length -eq $rebuilt.Length)
  if ($same) { for ($i=0; $i -lt $orig.Length; $i++) { if ($orig[$i] -ne $rebuilt[$i]) { $same=$false; $diffAt=$i; break } } }
  Write-Host ("[자기검증] 참조: {0}" -f (Split-Path $ref -Leaf))
  Write-Host ("[자기검증] 원본 {0}B / 재빌드 {1}B" -f $orig.Length, $rebuilt.Length)
  if ($same) {
    Write-Host "[자기검증] ✅ 바이트 단위 완전 일치 — 패커 정확성 증명됨" -ForegroundColor Green
  } else {
    Write-Host ("[자기검증] ❌ 불일치 (offset {0})" -f $diffAt) -ForegroundColor Red
    throw "자기검증 실패"
  }
}

# ======================= 메인 =======================
if ($SelfTest) { Invoke-SelfTest; return }

New-Item -ItemType Directory -Force $BuildDir | Out-Null
$outFile = Join-Path $BuildDir $OutName
$entries = New-TWPack -SourceDir $SrcDir -OutFile $outFile
$sz = (Get-Item $outFile).Length
Write-Host ("[빌드] {0} ({1} 파일, {2:N0} bytes)" -f $OutName, $entries.Count, $sz) -ForegroundColor Green
$entries | ForEach-Object { Write-Host ("  + {0}" -f $_.Path) }

if ($Deploy) {
  New-Item -ItemType Directory -Force $ModsDir | Out-Null
  Copy-Item $outFile (Join-Path $ModsDir $OutName) -Force
  Write-Host ("[배포] → {0}\{1}" -f $ModsDir, $OutName) -ForegroundColor Cyan
  Write-Host "[배포] 런처(또는 TWMM) 모드 목록에서 활성화 필요" -ForegroundColor Yellow
}
