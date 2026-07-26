<#
  기술표 → Lua 데이터 생성기
  ------------------------------------------------------------------
  reference/db 의 TSV 4종을 합쳐 src/.../advisor_db_tech.lua 를 만든다.
  런타임에는 기술 '목록'을 묻는 API가 없어서(has_technology(키)뿐)
  이 표가 없으면 무엇을 연구할지 말할 수 없다.

  합치는 것:
    technologies.tsv            key · is_civil/is_engineering/is_military · is_hidden
    technology_nodes.tsv        technology_key · technology_node_set · tier · 비용 · faction_key
    technology_node_sets.tsv    key → culture / subculture / faction_key
    technology_required.tsv     technology ← required_technology (선행조건)

  사용: .\gen_tech_data.ps1            (기본 경로로 생성)
        .\gen_tech_data.ps1 -Stats     (생성 없이 통계만)
#>
[CmdletBinding()]
param(
  [string]$DbDir  = "C:\Users\veria\tw3-campaign-advisor\reference\db",
  [string]$OutLua = "C:\Users\veria\tw3-campaign-advisor\src\script\campaign\mod\advisor_db_tech.lua",
  [switch]$Stats
)
$ErrorActionPreference = "Stop"

function Read-Tsv($path) {
  if (-not (Test-Path $path)) { throw "없음: $path" }
  Import-Csv -Path $path -Delimiter "`t"
}

$techs = Read-Tsv (Join-Path $DbDir "technologies.tsv")
$nodes = Read-Tsv (Join-Path $DbDir "technology_nodes.tsv")
$sets  = Read-Tsv (Join-Path $DbDir "technology_node_sets.tsv")
$reqs  = Read-Tsv (Join-Path $DbDir "technology_required.tsv")
$links = Read-Tsv (Join-Path $DbDir "technology_node_links.tsv")
Write-Host ("[입력] techs={0} nodes={1} sets={2} reqs={3} links={4}" -f $techs.Count,$nodes.Count,$sets.Count,$reqs.Count,$links.Count) -ForegroundColor Cyan

# --- 채택할 기술 목록 ---
#   ※ is_civil/is_engineering/is_military는 쓰지 않는다. 1869개 '전부'
#     is_military=True인 죽은 필드다(로마·아틸라 시절 잔재). 이걸로 계열을
#     나누면 존재하지 않는 구분을 지어내는 셈이 된다.
$attr = @{}
foreach ($t in $techs) {
  if ($t.is_hidden -eq "True") { continue }          # 숨김 기술은 화면에 못 뜬다
  $attr[$t.key] = $true
}

# --- 효과 기반 분류 ---
#   죽은 is_civil/is_military 대신, 기술이 실제로 주는 효과의 category를 쓴다.
#   한 기술이 여러 효과를 주면 가장 많은 카테고리를 대표로 삼는다.
$catOf = @{}
$fxPath = Join-Path $DbDir "technology_effects.tsv"
$fdPath = Join-Path $DbDir "effects.tsv"
if ((Test-Path $fxPath) -and (Test-Path $fdPath)) {
  $fx = Read-Tsv $fxPath
  $fd = Read-Tsv $fdPath
  $ecat = @{}
  foreach ($e in $fd) { if ($e.category) { $ecat[$e.effect] = $e.category } }
  $tally = @{}
  foreach ($j in $fx) {
    $c = $ecat[$j.effect]
    if (-not $c) { continue }
    if (-not $tally.ContainsKey($j.technology)) { $tally[$j.technology] = @{} }
    $tally[$j.technology][$c] = ([int]$tally[$j.technology][$c]) + 1
  }
  foreach ($k in $tally.Keys) {
    $best = $null; $bn = -1
    foreach ($c in ($tally[$k].Keys | Sort-Object)) {   # 동수면 이름 순 — 생성이 결정적이어야 한다
      if ($tally[$k][$c] -gt $bn) { $best = $c; $bn = $tally[$k][$c] }
    }
    $catOf[$k] = $best
  }
  Write-Host ("[분류] 효과표에서 {0}개 기술의 계열을 얻었다(효과 {1}행 · 효과정의 {2}행)" -f $catOf.Count,$fx.Count,$fd.Count) -ForegroundColor Cyan
} else {
  Write-Host "[분류] 효과표가 없어 계열 없이 생성한다" -ForegroundColor Yellow
}

# --- 노드 키 → 기술 키 (트리 링크는 '노드' 키로 걸려 있다) ---
$nodeTech = @{}
foreach ($n in $nodes) { $nodeTech[$n.key] = $n.technology_key }

# --- 선행조건: 기술 → 필요 기술 목록 ---
#   출처 두 곳을 합친다.
#   ① technology_node_links : 트리의 실제 부모-자식(노드 키 기준) — 본체
#   ② technology_required_technology_junctions : 트리 밖 추가 조건(114행뿐)
$pre = @{}
function Add-Pre($tech, $req) {
  if ([string]::IsNullOrEmpty($tech) -or [string]::IsNullOrEmpty($req) -or $tech -eq $req) { return }
  if (-not $pre.ContainsKey($tech)) { $pre[$tech] = New-Object System.Collections.Generic.List[string] }
  if (-not $pre[$tech].Contains($req)) { $pre[$tech].Add($req) }
}
foreach ($l in $links) {
  $ct = $nodeTech[$l.child_key]; $pt = $nodeTech[$l.parent_key]
  Add-Pre $ct $pt
}
foreach ($r in $reqs) { Add-Pre $r.technology $r.required_technology }

# --- 노드셋 메타 ---
$setMeta = @{}
foreach ($s in $sets) {
  $setMeta[$s.key] = [pscustomobject]@{
    Culture = $s.culture; Sub = $s.subculture; Faction = $s.faction_key; Campaign = $s.campaign_key
  }
}

# --- 노드 → 셋별 기술 목록 ---
$bySet = @{}
$skipped = 0
foreach ($n in $nodes) {
  $tk = $n.technology_key
  if (-not $attr.ContainsKey($tk)) { $skipped++; continue }    # 숨김이거나 technologies에 없음
  $set = $n.technology_node_set
  if (-not $bySet.ContainsKey($set)) { $bySet[$set] = New-Object System.Collections.Generic.List[object] }
  # required_parents = 부모 중 '몇 개'가 필요한가. 0/누락이면 전부(AND)로 본다.
  $rp = 0
  if ($n.PSObject.Properties.Name -contains 'required_parents' -and $n.required_parents -ne '') { $rp = [int]$n.required_parents }
  $bySet[$set].Add([pscustomobject]@{
    Key = $tk; Tier = [int]$n.tier; Indent = [int]$n.indent
    Need = $rp; NodeKey = $n.key
  })
}

# --- 트리 구조가 미더운 세트인지 판정 ---
#   정상적인 트리라면 티어 0 노드에는 부모가 없다(입구니까). 실제로 대부분의
#   종족이 그렇다. 그런데 카타이·젠취·오거·벨라코르처럼 원형으로 짜인 트리는
#   티어 0에도 부모가 걸려 있어, 부모-자식만 보고 '고를 수 있는 기술'을 뽑으면
#   엉뚱한 답이 나온다. 그런 세트는 표시해 두고 런타임에서 단서를 붙인다.
$isChildNode = @{}
foreach ($l in $links) { $isChildNode[$l.child_key] = $true }
$t0all = @{}; $t0withParent = @{}
foreach ($n in $nodes) {
  if ([int]$n.tier -ne 0) { continue }
  $s = $n.technology_node_set
  $t0all[$s] = ([int]$t0all[$s]) + 1
  if ($isChildNode[$n.key]) { $t0withParent[$s] = ([int]$t0withParent[$s]) + 1 }
}
$oddSet = @{}
foreach ($s in $t0all.Keys) {
  # 티어 0 노드가 '하나도' 입구가 아니면 = 이 트리에는 우리가 아는 시작점이 없다.
  # 일부만 부모를 가진 것(제국·키슬레프 등)은 정상 — 트리가 여러 갈래인 것뿐이다.
  if (([int]$t0withParent[$s]) -ge $t0all[$s]) { $oddSet[$s] = $true }
}

if ($Stats) {
  Write-Host ("[통계] 노드셋 {0}개 · 채택 기술 {1}개 · 제외 {2}개" -f $bySet.Count, ($bySet.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum, $skipped)
  Write-Host ("[통계] 구조 불확실 세트(티어0에 부모 있음): {0}" -f (($oddSet.Keys | Sort-Object) -join ", "))
  if ($catOf.Count -gt 0) {
    Write-Host "[통계] 효과 계열 분포:"
    $catOf.Values | Group-Object | Sort-Object Count -Descending | Select-Object -First 20 |
      ForEach-Object { "   {0,-40} {1}개" -f $_.Name, $_.Count }
  }
  Write-Host "[통계] 캠페인 키:" ; $sets | Group-Object campaign_key | ForEach-Object { "   '{0}' x{1}" -f $_.Name, $_.Count }
  Write-Host "[통계] 큰 노드셋 상위 10:"
  $bySet.GetEnumerator() | Sort-Object { -$_.Value.Count } | Select-Object -First 10 | ForEach-Object {
    $m = $setMeta[$_.Key]
    "   {0,-42} {1,4}개  sub={2} cul={3} fac={4}" -f $_.Key, $_.Value.Count, $m.Sub, $m.Culture, $m.Faction
  }
  return
}

# --- Lua 출력 ---
function Q($s) { if ([string]::IsNullOrEmpty($s)) { return "nil" } return '"' + ($s -replace '"','\"') + '"' }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine(@'
--[[===========================================================================
  TW3 어드바이저 — 기술표 (게임 DB에서 생성 · 손으로 고치지 말 것)
  ---------------------------------------------------------------------------
  생성기: scripts/gen_tech_data.ps1
  원본:   db.pack의 technologies / technology_nodes / technology_node_sets /
          technology_required_technology_junctions (RPFM 스키마로 파싱, 검증 통과)
  왜 필요한가: 런타임에 기술 '목록'을 묻는 API가 없다. has_technology(키)로
  하나씩 물어볼 수만 있어서, 물어볼 키 목록이 없으면 아무 말도 할 수 없다.
  구조:
    CA_TECH.sets[노드셋키] = { sub=서브컬처, cul=컬처, fac=팩션키, odd=구조불확실 }
    CA_TECH.list[노드셋키] = { {k=기술키, t=티어, c=계열, p={선행기술...}, n=부모중필요수}, ... }
      계열은 effects.category 실측값: c=campaign(지도) b=battle(전투) x=both
      ※ technologies의 is_civil/is_military는 쓰지 않는다 — 1869개 전부
        is_military=True인 죽은 필드다(로마·아틸라 잔재).
      odd = 티어 0에 입구가 하나도 없는 트리(카타이·젠취 등 원형 배치).
        부모-자식만 보고 판정하면 어긋나므로 런타임이 단서를 붙인다.
=============================================================================]]

CA_TECH = { sets = {}, list = {} }
local S, L = CA_TECH.sets, CA_TECH.list
'@)

$order = $bySet.Keys | Sort-Object
$nTech = 0
foreach ($set in $order) {
  $m = $setMeta[$set]
  if (-not $m) { continue }
  $odd = if ($oddSet[$set]) { ", odd = true" } else { "" }
  [void]$sb.AppendLine(("S[{0}] = {{ sub = {1}, cul = {2}, fac = {3}{4} }}" -f (Q $set), (Q $m.Sub), (Q $m.Culture), (Q $m.Faction), $odd))
  [void]$sb.AppendLine(("L[{0}] = {{" -f (Q $set)))
  foreach ($r in ($bySet[$set] | Sort-Object Tier, Indent, Key)) {
    $nTech++
    $p = ""
    if ($pre.ContainsKey($r.Key)) {
      $ks = ($pre[$r.Key] | ForEach-Object { Q $_ }) -join ","
      $p = (", p={{{0}}}" -f $ks)
      # n = 부모 중 필요한 개수. 전부 필요하면 생략(런타임 기본값이 '전부').
      if ($r.Need -gt 0 -and $r.Need -lt $pre[$r.Key].Count) { $p += (", n={0}" -f $r.Need) }
    }
    # 계열은 effects.category 실측값 3종뿐: campaign / battle / both → c / b / x
    $cat = ""
    if ($catOf.ContainsKey($r.Key)) {
      $short = switch ($catOf[$r.Key]) { "campaign" { "c" } "battle" { "b" } "both" { "x" } default { $null } }
      if ($short) { $cat = (",c=`"{0}`"" -f $short) }
    }
    [void]$sb.AppendLine(("{{k={0},t={1}{2}{3}}}," -f (Q $r.Key), $r.Tier, $cat, $p))
  }
  [void]$sb.AppendLine("}")
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine(("-- 노드셋 {0}개 · 기술 {1}개" -f $order.Count, $nTech))

[System.IO.File]::WriteAllText($OutLua, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
$kb = [math]::Round((Get-Item $OutLua).Length / 1KB, 1)
Write-Host ("[생성] {0}  노드셋 {1}개 · 기술 {2}개 · {3} KB" -f $OutLua, $order.Count, $nTech, $kb) -ForegroundColor Green
