<#
  TW3 로컬라이즈(.loc) 추출기 — 언어팩에서 공식 명칭 사전 뽑기
  ------------------------------------------------------------------
  local_XX.pack → text\localisation__.loc (zstd) → key/text TSV.
  .loc 포맷(실측): [FF FE][ 'L''O''C' 00 ][ver i32][count i32]
    행: key StringU16(u16 문자수+UTF-16LE) · text StringU16 · tooltip u8
  사용:
    .\extract_loc.ps1                              # 한국어, 이름류 접두사만
    .\extract_loc.ps1 -Prefix "" -OutTsv all.tsv   # 전체 덤프(대용량)
#>
[CmdletBinding()]
param(
  [string]$Pack   = "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\local_kr.pack",
  [string]$Entry  = "text\localisation__.loc",
  [string[]]$Prefix = @("provinces_onscreen_", "regions_onscreen_", "factions_screen_name_", "campaign_map_settlements_onscreen_"),
  [string]$OutTsv = "C:\Users\veria\tw3-campaign-advisor\reference\loc\kr_names.tsv",
  [string]$Zstd   = "C:\Users\veria\tools\zstd\zstd-v1.5.7-win64\zstd.exe",
  [string]$Scratch = "C:\Users\veria\AppData\Local\Temp\claude\C--Program-Files--x86--Steam-steamapps-common-Total-War-WARHAMMER-III\efc55d5c-cfee-42c6-b3b9-b74142338567\scratchpad"
)
$ErrorActionPreference = "Stop"

# --- pack에서 엔트리 추출(+zstd) ---
$b = [System.IO.File]::ReadAllBytes($Pack)
$depSize=[BitConverter]::ToUInt32($b,12); $fc=[BitConverter]::ToUInt32($b,16); $isz=[BitConverter]::ToUInt32($b,20)
$pos = 28 + $depSize; $dataOff = $pos + $isz; $found=$null
for ($i=0; $i -lt $fc; $i++) {
  $sz=[BitConverter]::ToUInt32($b,$pos); $pos+=4; $flag=$b[$pos]; $pos+=1
  $st=$pos; while($b[$pos] -ne 0){$pos++}; $p=[Text.Encoding]::ASCII.GetString($b,$st,$pos-$st); $pos++
  if ($p -eq $Entry) { $found=[pscustomobject]@{Size=$sz;Flag=$flag;Off=$dataOff} }
  $dataOff += $sz
}
if (-not $found) { throw "엔트리 없음: $Entry" }
$blob = New-Object byte[] $found.Size; [Array]::Copy($b,$found.Off,$blob,0,$found.Size)
if ($found.Flag -eq 1) {
  $payload = New-Object byte[] ($found.Size-4); [Array]::Copy($blob,4,$payload,0,$found.Size-4)
  $zst=Join-Path $Scratch "_loc.zst"; $bin=Join-Path $Scratch "_loc.bin"
  [System.IO.File]::WriteAllBytes($zst,$payload)
  $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'
  & $Zstd -q -d -f -o $bin $zst 2>&1 | Out-Null
  $ErrorActionPreference=$eap
  $d = [System.IO.File]::ReadAllBytes($bin)
} else { $d = $blob }
Write-Host ("[loc] 비압축 {0:N0} bytes" -f $d.Length)

# --- loc 파싱 ---
if (-not ($d[0] -eq 0xFF -and $d[1] -eq 0xFE)) { throw ("BOM 아님: {0:X2} {1:X2}" -f $d[0],$d[1]) }
$q = 2
$tag = [Text.Encoding]::ASCII.GetString($d,$q,3); $q += 3
if ($tag -ne "LOC") { throw "LOC 태그 아님: $tag" }
$q += 1  # null
$ver = [BitConverter]::ToInt32($d,$q); $q += 4
$cnt = [BitConverter]::ToInt32($d,$q); $q += 4
Write-Host ("[loc] ver={0} entries={1:N0}" -f $ver,$cnt)

function Read-U16Str([byte[]]$d) {
  $n = [BitConverter]::ToUInt16($d,$script:q); $script:q += 2
  $s = [Text.Encoding]::Unicode.GetString($d,$script:q,$n*2); $script:q += $n*2
  return $s
}
$script:q = $q
$out = New-Object System.Collections.Generic.List[string]
$out.Add("key`ttext")
$kept = 0
for ($i=0; $i -lt $cnt; $i++) {
  $key = Read-U16Str $d
  $txt = Read-U16Str $d
  $script:q += 1  # tooltip bool
  $take = ($Prefix.Count -eq 0)
  if (-not $take) { foreach ($pf in $Prefix) { if ($pf -eq "" -or $key.StartsWith($pf)) { $take = $true; break } } }
  if ($take) { $out.Add($key + "`t" + ($txt -replace "`t"," " -replace "`r?`n"," ")); $kept++ }
}
if ($script:q -ne $d.Length) { Write-Warning ("파싱종료 {0} ≠ 크기 {1} (포맷 확인 필요)" -f $script:q,$d.Length) }
else { Write-Host "[검증] 파싱종료 pos == 크기 OK" -ForegroundColor Green }
New-Item -ItemType Directory -Force (Split-Path $OutTsv) | Out-Null
[System.IO.File]::WriteAllLines($OutTsv, $out, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("[저장] {0} ({1:N0}/{2:N0} 행)" -f $OutTsv,$kept,$cnt)
