<#
  TW3 DB 테이블 추출기 (의존성: zstd.exe, RPFM schema RON)
  ------------------------------------------------------------------
  db.pack 안의 테이블을 zstd 해제 + 스키마 파싱하여 TSV로 덤프한다.
  - 바이너리 컬럼 순서 = RON fields 배열 순서(ca_order 아님, 실측 확인).
  - 검증: 파싱 종료 pos == 테이블 크기여야 정확(불일치 시 에러).
  - 행 파싱은 C#(Add-Type)에서 수행. 순수 PS 루프는 필드당 함수호출+정규식
    switch라 building_levels(5259행×26열)에 CPU 13분을 태웠다. 실측 후 교체.

  사용:
    .\extract_db_table.ps1 -Table cai_personalities_budget_allocations
    .\extract_db_table.ps1 -Table technologies -OutTsv out.tsv
    .\extract_db_table.ps1 -Table building_levels,building_chains -OutDir ..\reference\db
    .\extract_db_table.ps1 -Table X -Preview 5     # 앞 5행만 미리보기
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string[]]$Table,
  [string]$OutTsv,
  [string]$OutDir,
  [int]$Preview = 0,
  [string]$Pack   = "C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\data\db.pack",
  [string]$Schema = "C:\Users\veria\AppData\Roaming\FrodoWazEre\rpfm\config\schemas\schema_wh3.ron",
  [string]$Zstd   = "C:\Users\veria\tools\zstd\zstd-v1.5.7-win64\zstd.exe",
  [string]$Scratch = "C:\Users\veria\AppData\Local\Temp\claude\C--Program-Files--x86--Steam-steamapps-common-Total-War-WARHAMMER-III\efc55d5c-cfee-42c6-b3b9-b74142338567\scratchpad"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Scratch | Out-Null
if ($OutDir) { New-Item -ItemType Directory -Force $OutDir | Out-Null }

# --- 0) C# 행 파서 ---
#  타입코드: 0 Bool 1 I16 2 I32 3 I64 4 F32 5 F64
#            6 StrU8 7 StrU16 8 OptStrU8 9 OptStrU16
#  문자열 안의 탭/개행은 공백으로 치환한다(TSV 열 어긋남 방지).
if (-not ("TwDbParser" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Globalization;

public class TwDbParser {
    public string[] Lines;
    public int EndPos;

    static string Clean(string s) {
        if (s == null) return "";
        for (int i = 0; i < s.Length; i++) {
            char c = s[i];
            if (c == '\t' || c == '\n' || c == '\r') {
                var a = s.ToCharArray();
                for (int j = i; j < a.Length; j++)
                    if (a[j] == '\t' || a[j] == '\n' || a[j] == '\r') a[j] = ' ';
                return new string(a);
            }
        }
        return s;
    }

    public void Parse(byte[] d, int start, int rowCount, int[] t) {
        var inv = CultureInfo.InvariantCulture;
        int pos = start, nf = t.Length;
        var lines = new string[rowCount];
        var sb = new StringBuilder(512);
        for (int r = 0; r < rowCount; r++) {
            sb.Length = 0;
            for (int c = 0; c < nf; c++) {
                if (c > 0) sb.Append('\t');
                int l;
                switch (t[c]) {
                    case 0: sb.Append(d[pos] != 0 ? "True" : "False"); pos += 1; break;
                    case 1: sb.Append(BitConverter.ToInt16(d, pos).ToString(inv)); pos += 2; break;
                    case 2: sb.Append(BitConverter.ToInt32(d, pos).ToString(inv)); pos += 4; break;
                    case 3: sb.Append(BitConverter.ToInt64(d, pos).ToString(inv)); pos += 8; break;
                    case 4: sb.Append(BitConverter.ToSingle(d, pos).ToString(inv)); pos += 4; break;
                    case 5: sb.Append(BitConverter.ToDouble(d, pos).ToString(inv)); pos += 8; break;
                    case 6:
                        l = BitConverter.ToUInt16(d, pos); pos += 2;
                        sb.Append(Clean(Encoding.UTF8.GetString(d, pos, l))); pos += l; break;
                    case 7:
                        l = BitConverter.ToUInt16(d, pos); pos += 2;
                        sb.Append(Clean(Encoding.Unicode.GetString(d, pos, l * 2))); pos += l * 2; break;
                    case 8:
                        if (d[pos++] != 0) {
                            l = BitConverter.ToUInt16(d, pos); pos += 2;
                            sb.Append(Clean(Encoding.UTF8.GetString(d, pos, l))); pos += l;
                        }
                        break;
                    case 9:
                        if (d[pos++] != 0) {
                            l = BitConverter.ToUInt16(d, pos); pos += 2;
                            sb.Append(Clean(Encoding.Unicode.GetString(d, pos, l * 2))); pos += l * 2;
                        }
                        break;
                    default: throw new Exception("bad type code " + t[c] + " at col " + c);
                }
            }
            lines[r] = sb.ToString();
        }
        Lines = lines; EndPos = pos;
    }
}
'@
}

$TYPECODE = @{
  'Boolean'=0; 'I16'=1; 'I32'=2; 'OptionalI32'=2; 'I64'=3
  'F32'=4; 'Single'=4; 'F64'=5; 'Double'=5
  'StringU8'=6; 'StringU16'=7; 'OptionalStringU8'=8; 'OptionalStringU16'=9
}

# --- 1) pack 파일목록을 한 번만 훑어 테이블→(오프셋,크기,압축) 지도를 만든다 ---
function Get-PackIndex {
  param($pack)
  $b = [System.IO.File]::ReadAllBytes($pack)
  $off12=[BitConverter]::ToUInt32($b,12); $fc=[BitConverter]::ToUInt32($b,16); $isz=[BitConverter]::ToUInt32($b,20)
  $pos = 28 + $off12; $dataOff = $pos + $isz
  $map = @{}
  for ($i=0;$i -lt $fc;$i++){
    $sz=[BitConverter]::ToUInt32($b,$pos); $pos+=4; $flag=$b[$pos]; $pos+=1
    $st=$pos; while($b[$pos] -ne 0){$pos++}; $p=[Text.Encoding]::ASCII.GetString($b,$st,$pos-$st); $pos++
    # db\<table>_tables\<file>
    $m = [regex]::Match($p, '\\([a-z0-9_]+_tables)\\')
    if ($m.Success -and -not $map.ContainsKey($m.Groups[1].Value)) {
      $map[$m.Groups[1].Value] = [pscustomobject]@{ Size=$sz; Flag=$flag; Off=$dataOff }
    }
    $dataOff += $sz
  }
  return [pscustomobject]@{ Bytes=$b; Map=$map }
}

function Get-TableBinary {
  param($idx, $table, $zstd, $scratch)
  $t = $idx.Map[("{0}_tables" -f $table)]
  if (-not $t) { throw "테이블 없음: $table" }
  $blob = New-Object byte[] $t.Size; [Array]::Copy($idx.Bytes,$t.Off,$blob,0,$t.Size)
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
$script:SchemaLines = $null
function Get-SchemaFields {
  param($schema, $table, $version)
  if (-not $script:SchemaLines) { $script:SchemaLines = [System.IO.File]::ReadAllLines($schema) }
  $all = $script:SchemaLines
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

# --- 3) 테이블별 처리 ---
$idx = Get-PackIndex -pack $Pack
if ($Table.Count -gt 1 -and $OutTsv) { throw "-OutTsv는 테이블 1개일 때만. 여러 개는 -OutDir 사용." }

foreach ($tbl in $Table) {
  # 스키마에는 있으나 팩에는 실제 데이터가 없는 표가 있다(= 이 게임 버전에서 미사용).
  # 배치 추출이 그것 하나로 죽지 않도록 경고만 남기고 넘어간다.
  if (-not $idx.Map.ContainsKey(("{0}_tables" -f $tbl))) {
    Write-Host ("[없음] {0} — 팩에 데이터 없음(미사용 표). 건너뜀." -f $tbl) -ForegroundColor Yellow
    continue
  }
  $d = Get-TableBinary -idx $idx -table $tbl -zstd $Zstd -scratch $Scratch

  # 바이너리 헤더 파싱 → version, rowcount, 데이터 시작 pos
  $pos = 0
  if ($d[0]-eq 0xFD -and $d[1]-eq 0xFE -and $d[2]-eq 0xFC -and $d[3]-eq 0xFF) {  # GUID 마커
    $pos = 4; $glen=[BitConverter]::ToUInt16($d,$pos); $pos += 2 + $glen*2
  }
  $version = 0
  if ($d[$pos]-eq 0xFC -and $d[$pos+1]-eq 0xFD -and $d[$pos+2]-eq 0xFE -and $d[$pos+3]-eq 0xFF) {  # version 마커
    $pos += 4; $version=[BitConverter]::ToInt32($d,$pos); $pos += 4
  }
  $pos += 1                                   # 마커 바이트
  $rowCount = [BitConverter]::ToInt32($d,$pos); $pos += 4

  $fields = Get-SchemaFields -schema $Schema -table $tbl -version $version
  Write-Host ("[추출] {0}  version={1}  rows={2}  cols={3}  dataStart={4}" -f $tbl,$version,$rowCount,$fields.Count,$pos) -ForegroundColor Cyan

  $codes = New-Object int[] $fields.Count
  for ($i=0;$i -lt $fields.Count;$i++){
    $c = $TYPECODE[$fields[$i].Type]
    if ($null -eq $c) { throw ("미지원 필드타입: {0} (컬럼 {1} {2})" -f $fields[$i].Type,$i,$fields[$i].Name) }
    $codes[$i] = $c
  }

  $p = New-Object TwDbParser
  $p.Parse($d, $pos, $rowCount, $codes)

  # 검증 + 출력
  $ok = ($p.EndPos -eq $d.Length)
  Write-Host ("[검증] 파싱종료 pos={0} / 크기={1} → {2}" -f $p.EndPos,$d.Length, ($(if($ok){"OK 일치"}else{"불일치! 컬럼순/타입 오류"}))) -ForegroundColor $(if($ok){"Green"}else{"Red"})
  if (-not $ok) { throw ("레이아웃 검증 실패: {0}" -f $tbl) }

  $header = ($fields | ForEach-Object { $_.Name }) -join "`t"
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add($header)
  $lines.AddRange([string[]]$p.Lines)

  $dest = if ($OutTsv) { $OutTsv } elseif ($OutDir) { Join-Path $OutDir ("{0}.tsv" -f $tbl) } else { $null }
  if ($dest) {
    [System.IO.File]::WriteAllLines($dest, $lines)
    Write-Host ("[저장] {0} ({1} 행)" -f $dest,$rowCount) -ForegroundColor Cyan
  }
  if (-not $dest -or $Preview -gt 0) {
    $show = if ($Preview -gt 0) { [Math]::Min($Preview, $rowCount) } else { $rowCount }
    Write-Output $header
    for ($i=0;$i -lt $show;$i++){ Write-Output $lines[$i+1] }
  }
}
