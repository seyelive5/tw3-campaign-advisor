<#
  TW3 DB 테이블 추출기 (의존성: zstd.exe, RPFM schema RON)
  ------------------------------------------------------------------
  db.pack 안의 한 테이블을 zstd 해제 + 스키마 파싱하여 TSV로 덤프한다.
  - 바이너리 컬럼 순서 = RON fields 배열 순서(ca_order 아님, 실측 확인).
  - 검증: 파싱 종료 pos == 테이블 크기여야 정확(불일치 시 에러).

  사용:
    .\extract_db_table.ps1 -Table cai_personalities_budget_allocations
    .\extract_db_table.ps1 -Table cai_personalities_income_allocations -OutTsv out.tsv
    .\extract_db_table.ps1 -Table X -Preview 5     # 앞 5행만 미리보기
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Table,
  [string]$OutTsv,
  [int]$Preview = 0,
  [string]$Pack   = "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\db.pack",
  [string]$Schema = "C:\Users\veria\AppData\Roaming\FrodoWazEre\rpfm\config\schemas\schema_wh3.ron",
  [string]$Zstd   = "C:\Users\veria\tools\zstd\zstd-v1.5.7-win64\zstd.exe",
  [string]$Scratch = "C:\Users\veria\AppData\Local\Temp\claude\C--Program-Files--x86--Steam-steamapps-common-Total-War-WARHAMMER-III\efc55d5c-cfee-42c6-b3b9-b74142338567\scratchpad"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Scratch | Out-Null

# --- 1) pack에서 테이블 바이너리 추출 (+ 필요시 zstd 해제) ---
function Get-TableBinary {
  param($pack, $table, $zstd, $scratch)
  $b = [System.IO.File]::ReadAllBytes($pack)
  $off12=[BitConverter]::ToUInt32($b,12); $fc=[BitConverter]::ToUInt32($b,16); $isz=[BitConverter]::ToUInt32($b,20)
  $pos = 28 + $off12; $dataOff = $pos + $isz; $t=$null
  $needle = "\{0}_tables\" -f $table
  for ($i=0;$i -lt $fc;$i++){
    $sz=[BitConverter]::ToUInt32($b,$pos); $pos+=4; $flag=$b[$pos]; $pos+=1
    $st=$pos; while($b[$pos] -ne 0){$pos++}; $p=[Text.Encoding]::ASCII.GetString($b,$st,$pos-$st); $pos++
    if ($p -like ("*{0}*" -f $needle)) { $t=[pscustomobject]@{Size=$sz;Flag=$flag;Off=$dataOff}; break }
    $dataOff += $sz
  }
  if (-not $t) { throw "테이블 없음: $table" }
  $blob = New-Object byte[] $t.Size; [Array]::Copy($b,$t.Off,$blob,0,$t.Size)
  if ($t.Flag -eq 1) {
    $payload = New-Object byte[] ($t.Size-4); [Array]::Copy($blob,4,$payload,0,$t.Size-4)
    $zst=Join-Path $scratch "_t.zst"; $bin=Join-Path $scratch "_t.bin"
    [System.IO.File]::WriteAllBytes($zst,$payload)
    $eap=$ErrorActionPreference; $ErrorActionPreference='Continue'
    & $zstd -q -d -f -o $bin $zst 2>&1 | Out-Null
    $ErrorActionPreference=$eap
    return [System.IO.File]::ReadAllBytes($bin)
  }
  return $blob
}

# --- 2) 스키마에서 (해당 version의) 필드 목록을 RON 배열 순서로 ---
function Get-SchemaFields {
  param($schema, $table, $version)
  $all = [System.IO.File]::ReadAllLines($schema)
  $key = ('"{0}_tables":' -f $table)
  # 시작줄($s) = key를 포함한 정의줄. Contains 우선(진단서 검증됨).
  $s = -1
  for ($i=0;$i -lt $all.Count;$i++){ if ($all[$i].Contains($key)) { $s = $i; break } }
  if ($s -lt 0) { throw "스키마에 테이블 없음: $table" }
  # 끝줄($e) = 그 다음 "..._tables": [ 정의줄.
  $e = $all.Count
  for ($i=$s+1;$i -lt $all.Count;$i++){ if ($all[$i] -match '^\s*"[a-z0-9_]+_tables":\s*\[') { $e = $i; break } }
  $blockText = ($all[$s..($e-1)]) -join "`n"
  # version 서브블록으로 분할
  $parts = [regex]::Split($blockText, '(?=\(\s*version:\s*-?\d+,)')
  $chunk = $null
  foreach ($p in $parts) {
    $m = [regex]::Match($p, '^\(\s*version:\s*(-?\d+),')
    if ($m.Success -and [int]$m.Groups[1].Value -eq $version) { $chunk = $p; break }
  }
  if (-not $chunk) { throw "테이블 $table 에 version $version 스키마 없음" }
  # fields: [ ... ] 영역만 — ★localised_fields는 db 바이너리에 없음(.loc 파일 소관)!
  #   기존 버그: version 청크 전체를 긁어 localised_fields까지 컬럼으로 포함 → wide 테이블 4컬럼 과독 desync.
  $fi = $chunk.IndexOf('fields:')
  $chunk = $chunk.Substring($fi)
  $li = $chunk.IndexOf('localised_fields:')
  if ($li -ge 0) { $chunk = $chunk.Substring(0, $li) }
  $rx = [regex]'name:\s*"([^"]+)",\s*field_type:\s*(\w+)'
  $fields = New-Object System.Collections.Generic.List[object]
  foreach ($m in $rx.Matches($chunk)) { $fields.Add([pscustomobject]@{ Name=$m.Groups[1].Value; Type=$m.Groups[2].Value }) }
  return $fields
}

# --- 3) 바이너리 헤더 파싱 → version, rowcount, 데이터 시작 pos ---
$d = Get-TableBinary -pack $Pack -table $Table -zstd $Zstd -scratch $Scratch
$script:pos = 0
if ($d[0]-eq 0xFD -and $d[1]-eq 0xFE -and $d[2]-eq 0xFC -and $d[3]-eq 0xFF) {  # GUID 마커
  $script:pos = 4; $glen=[BitConverter]::ToUInt16($d,$script:pos); $script:pos += 2 + $glen*2
}
$version = 0
if ($d[$script:pos]-eq 0xFC -and $d[$script:pos+1]-eq 0xFD -and $d[$script:pos+2]-eq 0xFE -and $d[$script:pos+3]-eq 0xFF) {  # version 마커
  $script:pos += 4; $version=[BitConverter]::ToInt32($d,$script:pos); $script:pos += 4
}
$script:pos += 1                                   # 마커 바이트
$rowCount = [BitConverter]::ToInt32($d,$script:pos); $script:pos += 4

$fields = Get-SchemaFields -schema $Schema -table $Table -version $version
Write-Host ("[추출] {0}  version={1}  rows={2}  cols={3}  dataStart={4}" -f $Table,$version,$rowCount,$fields.Count,$script:pos) -ForegroundColor Cyan

# --- 4) 행 파싱 ---
function Read-Field($d, $type) {
  switch -Regex ($type) {
    '^Boolean$'          { $v=$d[$script:pos]; $script:pos+=1; return [bool]$v }
    '^I16$'              { $v=[BitConverter]::ToInt16($d,$script:pos); $script:pos+=2; return $v }
    '^(I32|OptionalI32)$'{ $v=[BitConverter]::ToInt32($d,$script:pos); $script:pos+=4; return $v }
    '^I64$'              { $v=[BitConverter]::ToInt64($d,$script:pos); $script:pos+=8; return $v }
    '^(F32|Single)$'     { $v=[BitConverter]::ToSingle($d,$script:pos); $script:pos+=4; return $v }
    '^(F64|Double)$'     { $v=[BitConverter]::ToDouble($d,$script:pos); $script:pos+=8; return $v }
    '^StringU8$'         { $l=[BitConverter]::ToUInt16($d,$script:pos); $script:pos+=2; $s=[Text.Encoding]::UTF8.GetString($d,$script:pos,$l); $script:pos+=$l; return $s }
    '^StringU16$'        { $l=[BitConverter]::ToUInt16($d,$script:pos); $script:pos+=2; $s=[Text.Encoding]::Unicode.GetString($d,$script:pos,$l*2); $script:pos+=$l*2; return $s }
    '^OptionalStringU8$' { $has=$d[$script:pos]; $script:pos+=1; if($has -eq 0){return ""}; $l=[BitConverter]::ToUInt16($d,$script:pos); $script:pos+=2; $s=[Text.Encoding]::UTF8.GetString($d,$script:pos,$l); $script:pos+=$l; return $s }
    '^OptionalStringU16$'{ $has=$d[$script:pos]; $script:pos+=1; if($has -eq 0){return ""}; $l=[BitConverter]::ToUInt16($d,$script:pos); $script:pos+=2; $s=[Text.Encoding]::Unicode.GetString($d,$script:pos,$l*2); $script:pos+=$l*2; return $s }
    default { throw ("미지원 필드타입: {0} (pos {1})" -f $type,$script:pos) }
  }
}
$rows = New-Object System.Collections.Generic.List[object]
for ($r=0;$r -lt $rowCount;$r++){
  $o=[ordered]@{}
  foreach ($f in $fields){ $o[$f.Name] = Read-Field $d $f.Type }
  $rows.Add([pscustomobject]$o)
}

# --- 5) 검증 + 출력 ---
$ok = ($script:pos -eq $d.Length)
Write-Host ("[검증] 파싱종료 pos={0} / 크기={1} → {2}" -f $script:pos,$d.Length, ($(if($ok){"OK 일치"}else{"불일치! 컬럼순/타입 오류"}))) -ForegroundColor $(if($ok){"Green"}else{"Red"})
if (-not $ok) { throw "레이아웃 검증 실패" }

$header = ($fields | ForEach-Object { $_.Name }) -join "`t"
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add($header)
foreach ($row in $rows){ $lines.Add((($fields | ForEach-Object { [string]$row.$($_.Name) }) -join "`t")) }

if ($OutTsv) { [System.IO.File]::WriteAllLines($OutTsv, $lines); Write-Host ("[저장] {0} ({1} 행)" -f $OutTsv,$rows.Count) -ForegroundColor Cyan }
$show = if ($Preview -gt 0) { [Math]::Min($Preview, $rows.Count) } else { $rows.Count }
Write-Output $header
for ($i=0;$i -lt $show;$i++){ Write-Output $lines[$i+1] }
