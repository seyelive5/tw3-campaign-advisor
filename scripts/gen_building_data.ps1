<#
  건물표 → Lua 데이터 생성기
  ------------------------------------------------------------------
  reference/db 의 building_* / slot_* TSV를 합쳐 두 파일을 만든다.
    src/.../advisor_db_building.lua     본체(조언에 실제로 쓰는 것)
    src/.../advisor_db_building_fx.lua  원시 효과행(지금은 안 쓰지만 보존)
  fx를 따로 뺀 이유: 나중에 무게가 문제되면 이 파일만 빼면 되게.

  런타임이 알려주는 것 / 못 알려주는 것 (tw_autogen 실측):
    알려줌 — slot:template_key() type() resource_key() has_building()
             building:name() chain() building_level()
    못 알려줌 — "이 슬롯에 뭘 지을 수 있나"(can_build류 API 없음)
    → 그래서 slot_template → 허용 체인 → 종족 가용성 → 건물 레벨을
       이 표에서 미리 풀어둔다.

  조인 경로(오프라인 검증 완료):
    slot_template_permitted_building_chains  (chain | chain_set | super_chain) × slot_template, remove 플래그
      chain_set   → building_chain_sets(parent_set 상속) + building_chain_set_items
      super_chain → building_chains.building_superchain 이 같은 체인 전부
    building_chain_availability_sets  체인 → 가용성 세트 id
    building_chain_availabilities     세트 id → culture / sub_culture / faction / campaign
      ('everyone' 세트 = 전부 빈칸 = 모두에게 허용)
    building_levels                   체인의 각 단계 · 비용 · 턴 · 유지비
    building_upgrades_junction        from → to (업그레이드 간선)

  사용: .\gen_building_data.ps1
        .\gen_building_data.ps1 -Stats     (생성 없이 통계만)
#>
[CmdletBinding()]
param(
  [string]$DbDir  = "C:\Users\veria\tw3-campaign-advisor\reference\db",
  [string]$OutDir = "C:\Users\veria\tw3-campaign-advisor\src\script\campaign\mod",
  [switch]$Stats
)
$ErrorActionPreference = "Stop"

function Read-Tsv($name) {
  $p = Join-Path $DbDir "$name.tsv"
  if (-not (Test-Path $p)) { throw "없음: $p" }
  Import-Csv -Path $p -Delimiter "`t"
}

$levels   = Read-Tsv building_levels
$chains   = Read-Tsv building_chains
$cvars    = Read-Tsv building_culture_variants
$ups      = Read-Tsv building_upgrades_junction
$avail    = Read-Tsv building_chain_availabilities
$availSet = Read-Tsv building_chain_availability_sets
$perm     = Read-Tsv slot_template_permitted_building_chains
$slotTpl  = Read-Tsv slot_templates
$csets    = Read-Tsv building_chain_sets
$citems   = Read-Tsv building_chain_set_items
$bfx      = Read-Tsv building_effects_junction
$bunits   = Read-Tsv building_units_allowed
$effdef   = Read-Tsv effects

Write-Host ("[입력] levels={0} chains={1} perm={2} sets={3} items={4} fx={5} units={6}" -f `
  $levels.Count,$chains.Count,$perm.Count,$csets.Count,$citems.Count,$bfx.Count,$bunits.Count) -ForegroundColor Cyan

# --- 1) 체인 메타 · 슈퍼체인 역인덱스 ---
$chainMeta = @{}
$bySuper   = @{}
foreach ($c in $chains) {
  $chainMeta[$c.key] = $c
  if ($c.building_superchain) {
    if (-not $bySuper.ContainsKey($c.building_superchain)) { $bySuper[$c.building_superchain] = New-Object System.Collections.Generic.List[string] }
    $bySuper[$c.building_superchain].Add($c.key)
  }
}

# --- 2) 체인 세트 전개 (parent_set 상속 + items의 add/remove) ---
#   remove는 add를 전부 적용한 뒤에 뺀다. 표에 순서 의미가 있다는 근거를 못 찾았고,
#   순서 무관하게 두는 편이 재생성 결정성에도 낫다.
$setParent = @{}
foreach ($s in $csets) { $setParent[$s.key] = $s.parent_set }
$itemsBySet = @{}
foreach ($i in $citems) {
  if (-not $itemsBySet.ContainsKey($i.set)) { $itemsBySet[$i.set] = New-Object System.Collections.Generic.List[object] }
  $itemsBySet[$i.set].Add($i)
}

$setCache = @{}
function Resolve-Set([string]$set, [System.Collections.Generic.HashSet[string]]$guard) {
  if ([string]::IsNullOrEmpty($set)) { return @{} }
  if ($setCache.ContainsKey($set)) { return $setCache[$set] }
  if (-not $guard) { $guard = New-Object 'System.Collections.Generic.HashSet[string]' }
  if (-not $guard.Add($set)) { return @{} }        # 순환 방어

  $out = @{}
  $p = $setParent[$set]
  if ($p) { foreach ($k in (Resolve-Set $p $guard).Keys) { $out[$k] = $true } }

  $add = @{}; $rm = @{}
  # ※ @($list) 로 감싸지 말 것. PowerShell 7에서 List[object](PSCustomObject 담김)를
  #   배열 부분식으로 감싸면 "Argument types do not match"로 죽는다(실측). 직접 foreach는 멀쩡하고,
  #   $null에 대한 foreach는 0회 도는 것도 확인했다.
  foreach ($i in $itemsBySet[$set]) {
    if (-not $i) { continue }
    $targets = New-Object System.Collections.Generic.List[string]
    if ($i.chain)       { $targets.Add($i.chain) }
    if ($i.super_chain) { foreach ($k in $bySuper[$i.super_chain]) { if ($k) { $targets.Add($k) } } }
    $dst = if ($i.remove -eq 'True') { $rm } else { $add }
    foreach ($t in $targets) { $dst[$t] = $true }
  }
  foreach ($k in $add.Keys) { $out[$k] = $true }
  foreach ($k in $rm.Keys)  { [void]$out.Remove($k) }

  $setCache[$set] = $out
  return $out
}

# --- 3) 슬롯 템플릿 → 허용 체인 ---
$permByTpl = @{}
foreach ($r in $perm) {
  if (-not $permByTpl.ContainsKey($r.slot_template)) { $permByTpl[$r.slot_template] = New-Object System.Collections.Generic.List[object] }
  $permByTpl[$r.slot_template].Add($r)
}
$slotChains = @{}
foreach ($tpl in $permByTpl.Keys) {
  $add = @{}; $rm = @{}
  foreach ($r in $permByTpl[$tpl]) {
    $targets = New-Object System.Collections.Generic.List[string]
    if ($r.chain)       { $targets.Add($r.chain) }
    if ($r.chain_set)   { foreach ($k in (Resolve-Set $r.chain_set $null).Keys) { $targets.Add($k) } }
    if ($r.super_chain) { foreach ($k in $bySuper[$r.super_chain]) { if ($k) { $targets.Add($k) } } }
    $dst = if ($r.remove -eq 'True') { $rm } else { $add }
    foreach ($t in $targets) { $dst[$t] = $true }
  }
  foreach ($k in $rm.Keys) { [void]$add.Remove($k) }
  if ($add.Count -gt 0) { $slotChains[$tpl] = ($add.Keys | Sort-Object) }
}

# --- 4) 종족 가용성: 체인 → 세트 id, 세트 id → 조건행 ---
$chainAvail = @{}
foreach ($a in $availSet) {
  if (-not $chainAvail.ContainsKey($a.building_chain)) { $chainAvail[$a.building_chain] = New-Object 'System.Collections.Generic.HashSet[string]' }
  [void]$chainAvail[$a.building_chain].Add($a.id)
}
$availRules = @{}
foreach ($a in $avail) {
  if (-not $availRules.ContainsKey($a.set_id)) { $availRules[$a.set_id] = New-Object System.Collections.Generic.List[object] }
  $availRules[$a.set_id].Add($a)
}

# --- 5) 효과 버킷 ---
#   effect 키는 이름이 규칙적이라 분류가 된다. 순서가 곧 우선순위(먼저 걸리는 쪽).
#   ※ 값을 더해 "수입 +N"이라 말하지는 않는다. 같은 버킷 안에도 정액과 퍼센트가
#     섞여 있어서 합계가 거짓말이 된다. 여기서는 '무슨 계열인가'만 뽑는다.
$BUCKET = @(
  @{ rx = '_dummy$';                                  b = $null  }   # UI 더미 — 버린다
  @{ rx = 'economy_gdp|_income|treasury';             b = 'gdp'  }   # 수입
  @{ rx = 'public_order';                             b = 'po'   }   # 치안
  @{ rx = 'province_growth|_growth';                  b = 'grw'  }   # 성장
  @{ rx = 'corruption';                               b = 'cor'  }   # 타락
  @{ rx = 'research_points|technology';               b = 'res'  }   # 연구
  @{ rx = 'recruitment|recruit_';                     b = 'rec'  }   # 모병
  @{ rx = 'replenishment';                            b = 'rep'  }   # 충원
  @{ rx = 'walls|siege|fortif|garrison|_defence';     b = 'def'  }   # 방어
  @{ rx = 'winds_of_magic';                           b = 'mag'  }   # 마법
  @{ rx = 'supply_points';                            b = 'sup'  }   # 보급
  @{ rx = 'diplomat|attitude';                        b = 'dip'  }   # 외교
  @{ rx = 'attrition|casualt';                        b = 'att'  }   # 소모
  @{ rx = 'upkeep';                                   b = 'upk'  }   # 유지비
  @{ rx = 'movement|campaign_move';                   b = 'mov'  }   # 기동
)
function Get-Bucket([string]$eff) {
  foreach ($p in $BUCKET) { if ($eff -match $p.rx) { return $p.b } }
  return 'oth'
}
$effMeta = @{}
foreach ($e in $effdef) { $effMeta[$e.effect] = $e }

# 건물 레벨 → 버킷 집계(효과 개수 기준) → 태그 문자열
$tagOf = @{}
$bTally = @{}
foreach ($j in $bfx) {
  $b = Get-Bucket $j.effect
  if (-not $b) { continue }
  if (-not $bTally.ContainsKey($j.building)) { $bTally[$j.building] = @{} }
  $bTally[$j.building][$b] = ([int]$bTally[$j.building][$b]) + 1
}
foreach ($k in $bTally.Keys) {
  # 많이 나온 버킷 순, 동수면 이름 순(생성 결정성)
  $ordered = $bTally[$k].GetEnumerator() | Sort-Object @{e={-$_.Value}}, @{e={$_.Key}} | Select-Object -First 4 -ExpandProperty Key
  $tagOf[$k] = ($ordered -join ",")
}

# --- 6) 업그레이드 간선 · 해금 유닛 ---
$upOf = @{}
foreach ($u in $ups) { if (-not $upOf.ContainsKey($u.from)) { $upOf[$u.from] = $u.to } }
$unitsOf = @{}
foreach ($u in $bunits) {
  # ※ enabled / conditions 로 거르지 말 것. 6396행 '전부' enabled=False, conditions=0인
  #   죽은 필드다(technologies의 is_military와 같은 경우). 걸렀더니 해금 유닛이 0개가 됐다.
  #   데이터 자체는 멀쩡하다 — emp_barracks_1→검병, _2→석궁·미늘창, _3→대검병으로 실측 확인.
  if (-not $unitsOf.ContainsKey($u.building)) { $unitsOf[$u.building] = New-Object 'System.Collections.Generic.HashSet[string]' }
  [void]$unitsOf[$u.building].Add($u.unit)
}

# --- 7) 통계 ---
if ($Stats) {
  Write-Host ("[통계] 슬롯 템플릿 {0}개 (허용 체인 있음) · 평균 체인 {1:N1}개" -f `
    $slotChains.Count, (($slotChains.Values | ForEach-Object { $_.Count } | Measure-Object -Average).Average))
  Write-Host ("[통계] 체인 {0} · 레벨 {1} · 업그레이드 간선 {2} · 가용성 세트 {3}" -f `
    $chains.Count, $levels.Count, $upOf.Count, $availRules.Count)
  Write-Host "[통계] 버킷 분포:"
  $tagOf.Values | ForEach-Object { $_ -split "," } | Group-Object | Sort-Object Count -Descending |
    ForEach-Object { "   {0,-5} {1}개 건물" -f $_.Name, $_.Count }
  Write-Host "[통계] 체인 최다 슬롯 템플릿 상위 8:"
  $slotChains.GetEnumerator() | Sort-Object { -$_.Value.Count } | Select-Object -First 8 |
    ForEach-Object { "   {0,-55} {1}개" -f $_.Key, $_.Value.Count }
  return
}

# --- 8) Lua 출력 ---
function Q($s) { if ([string]::IsNullOrEmpty($s)) { return "nil" } return '"' + ($s -replace '\\','\\' -replace '"','\"') + '"' }
function N($s) { if ([string]::IsNullOrEmpty($s)) { return "0" } return ([string]([double]$s)) }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine(@'
--[[===========================================================================
  TW3 어드바이저 — 건물표 (게임 DB에서 생성 · 손으로 고치지 말 것)
  ---------------------------------------------------------------------------
  생성기: scripts/gen_building_data.ps1
  원본:   db.pack의 building_levels / building_chains / building_upgrades_junction /
          building_chain_availabilities(+sets) / slot_template_permitted_building_chains
          (RPFM 스키마로 파싱, pos==size 검증 통과)

  왜 필요한가: 런타임에 "이 슬롯에 뭘 지을 수 있나"를 묻는 API가 없다.
  슬롯이 알려주는 건 template_key / type / resource_key / 현재 건물뿐이라,
  후보를 좁히려면 이 표가 있어야 한다.

  구조:
    CA_BLD.slot[슬롯템플릿] = { {c=체인,s=체인세트,u=슈퍼체인,r=제외}, ... }
                              ↑ 전개하지 않은 '규칙'이다. 전개하면 166,789 엔트리(6 MB)가
                                되는데, 한 판에서 실제로 보는 템플릿은 수십 개뿐이고
                                종족 필터를 걸면 템플릿당 15~20개다(실측). 런타임이 편다.
    CA_BLD.cset[체인세트]   = { p=상속부모, i={ {c=,u=,r=}, ... } }
    CA_BLD.super[슈퍼체인]  = { 체인키, ... }      super_chain 전개용
    CA_BLD.av[체인]         = { 세트id, ... }      체인의 종족 가용성 세트
    CA_BLD.rule[세트id]     = { {c=,s=,f=,g=}, }   세트 조건(컬처/서브/팩션/캠페인)
                                                   전부 nil이면 모두 허용('everyone')
    CA_BLD.ch[체인]         = { cat=계열, sc=슈퍼체인, dis=철거가능 }
    CA_BLD.lv[레벨키]       = { ch=체인, l=단계, c=건설비, t=턴, u=유지비,
                                f=식량, d=개발점수, v=UI표시(false면 화면에 안 뜸) }
                              ※ only_in_capital·resource_requirement는 담지 않는다 —
                                각각 5259행 전부 False, 0행인 죽은 필드다(실측).
    CA_BLD.up[레벨키]       = 다음단계레벨키
    CA_BLD.tag[레벨키]      = "gdp,grw"            효과 계열(최대 4개, 많은 순)
    CA_BLD.un[레벨키]       = { 유닛키, ... }      해금 유닛
    CA_BLD.cv[레벨키]       = { {c=,s=,f=,x=}, }   문화 변형 — 한글 이름 키 조립 + 비활성 판정

  태그 약어: gdp수입 po치안 grw성장 cor타락 res연구 rec모병 rep충원 def방어
             mag마법 sup보급 dip외교 att소모 upk유지비 mov기동 oth기타
  ※ 태그는 '무슨 계열인가'만 말한다. 값을 합산하지 않는다 — 같은 버킷에
    정액과 퍼센트가 섞여 있어 합계가 거짓말이 되기 때문이다.
=============================================================================]]

CA_BLD = { slot = {}, av = {}, rule = {}, ch = {}, lv = {}, up = {}, tag = {}, un = {} }
local SL, AV, RU, CH, LV, UP, TG, UN =
  CA_BLD.slot, CA_BLD.av, CA_BLD.rule, CA_BLD.ch, CA_BLD.lv, CA_BLD.up, CA_BLD.tag, CA_BLD.un
'@)

# 8-1) 가용성 규칙
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 가용성 세트 조건")
foreach ($sid in ($availRules.Keys | Sort-Object)) {
  $parts = foreach ($r in ($availRules[$sid] | Sort-Object culture, sub_culture, faction, campaign)) {
    "{{c={0},s={1},f={2},g={3}}}" -f (Q $r.culture), (Q $r.sub_culture), (Q $r.faction), (Q $r.campaign)
  }
  [void]$sb.AppendLine(("RU[{0}]={{{1}}}" -f (Q $sid), ($parts -join ",")))
}

# 8-2) 체인 → 가용성 세트
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 체인 → 가용성 세트")
foreach ($c in ($chainAvail.Keys | Sort-Object)) {
  $ids = ($chainAvail[$c] | Sort-Object | ForEach-Object { Q $_ }) -join ","
  [void]$sb.AppendLine(("AV[{0}]={{{1}}}" -f (Q $c), $ids))
}

# 8-3) 체인 메타
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 체인 메타")
foreach ($k in ($chainMeta.Keys | Sort-Object)) {
  $c = $chainMeta[$k]
  $dis = if ($c.can_be_dismantled -eq 'True') { ",dis=true" } else { "" }
  [void]$sb.AppendLine(("CH[{0}]={{cat={1},sc={2}{3}}}" -f (Q $k), (Q $c.chain_category), (Q $c.building_superchain), $dis))
}

# 8-4) 건물 레벨
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 건물 레벨")
$nLv = 0
foreach ($l in ($levels | Sort-Object level_name)) {
  $nLv++
  $x = ""
  # ※ only_in_capital(5259행 전부 False)과 resource_requirement(0행)는 담지 않는다.
  #   둘 다 이 게임 버전에서 죽은 필드다 — enabled/conditions와 같은 경우.
  #   담아 두면 런타임에 '수도 전용을 거르는 가드'처럼 보이는 죽은 코드가 생긴다.
  #   되살릴 조건: 이 분포가 바뀌면(True가 하나라도 나오면) 다시 넣고
  #   CA_BLDQ.candidates에 수도 판정을 복구할 것.
  if ($l.food_cost -and [double]$l.food_cost -ne 0)                     { $x += (",f={0}" -f (N $l.food_cost)) }
  if ($l.development_point_cost -and [double]$l.development_point_cost -ne 0) { $x += (",d={0}" -f (N $l.development_point_cost)) }
  if ($l.visible_in_ui -ne 'True')     { $x += ",v=false" }
  [void]$sb.AppendLine(("LV[{0}]={{ch={1},l={2},c={3},t={4},u={5}{6}}}" -f `
    (Q $l.level_name), (Q $l.chain), (N $l.level), (N $l.create_cost), (N $l.create_time), (N $l.upkeep_cost), $x))
}

# 8-5) 업그레이드 간선
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 업그레이드 간선")
foreach ($k in ($upOf.Keys | Sort-Object)) {
  [void]$sb.AppendLine(("UP[{0}]={1}" -f (Q $k), (Q $upOf[$k])))
}

# 8-6) 효과 계열 태그
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 효과 계열 태그")
foreach ($k in ($tagOf.Keys | Sort-Object)) {
  [void]$sb.AppendLine(("TG[{0}]={1}" -f (Q $k), (Q $tagOf[$k])))
}

# 8-6b) 문화 변형 — 한글 이름 로컬 키 조립 + disables 판정에 쓴다.
#   로컬 키 규칙(실측 확정, 5368/5414 적중):
#     building_culture_variants_name_ + building + culture + subculture + faction
#     ↑ 구분자 없이 '빈 값을 뺀 기본키 컬럼'을 순서대로 이어붙인다.
#     예) wh_main_emp_barracks_3 + wh_main_emp_empire            → "병영"
#         wh_main_emp_worship_1 + culture + subculture           → "지그마 성소"
#         wh_main_talabec_worship_1 + wh_main_emp_talabecland    → "타알의 제단"
#         wh_main_emp_resource_iron_1 (전부 빈칸)                → "철 채굴장"
#   미적중 46개는 규칙이 틀린 게 아니라 CA가 번역을 안 넣은 항목이다.
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 문화 변형 (c/s/f = 컬처/서브컬처/팩션, x = 이 조합에서 비활성)")
$cvBy = @{}
foreach ($v in $cvars) {
  if (-not $cvBy.ContainsKey($v.building)) { $cvBy[$v.building] = New-Object System.Collections.Generic.List[object] }
  $cvBy[$v.building].Add($v)
}
[void]$sb.AppendLine("CA_BLD.cv = {}")
foreach ($k in ($cvBy.Keys | Sort-Object)) {
  $parts = foreach ($v in ($cvBy[$k] | Sort-Object culture, subculture, faction)) {
    $f = New-Object System.Collections.Generic.List[string]
    if ($v.culture)            { $f.Add("c=" + (Q $v.culture)) }
    if ($v.subculture)         { $f.Add("s=" + (Q $v.subculture)) }
    if ($v.faction)            { $f.Add("f=" + (Q $v.faction)) }
    if ($v.disables -eq 'True'){ $f.Add("x=true") }
    "{" + ($f -join ",") + "}"
  }
  [void]$sb.AppendLine(("CA_BLD.cv[{0}]={{{1}}}" -f (Q $k), ($parts -join ",")))
}

# 8-7) 해금 유닛
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 해금 유닛")
foreach ($k in ($unitsOf.Keys | Sort-Object)) {
  $us = ($unitsOf[$k] | Sort-Object | ForEach-Object { Q $_ }) -join ","
  [void]$sb.AppendLine(("UN[{0}]={{{1}}}" -f (Q $k), $us))
}

# 8-8) 슬롯 허용 규칙 — '전개하지 않고' 원본 규칙 그대로 담는다.
#   전개하면 642 템플릿 × 평균 260체인 = 166,789 엔트리(약 6 MB)가 된다.
#   그런데 한 판에서 실제로 마주치는 슬롯 템플릿은 수십 개뿐이고, 종족 필터를
#   걸면 템플릿당 15~20개로 줄어든다(엠파이어 뉼른 철광 슬롯 488→17 실측).
#   그래서 규칙(1,748행)과 세트 정의(2,428행)만 담고 런타임이 필요한 것만 편다.
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 슬롯 템플릿 허용 규칙 (c=체인 s=체인세트 u=슈퍼체인 r=제외)")
foreach ($tpl in ($permByTpl.Keys | Sort-Object)) {
  $parts = foreach ($r in ($permByTpl[$tpl] | Sort-Object chain, chain_set, super_chain, remove)) {
    $f = New-Object System.Collections.Generic.List[string]
    if ($r.chain)             { $f.Add("c=" + (Q $r.chain)) }
    if ($r.chain_set)         { $f.Add("s=" + (Q $r.chain_set)) }
    if ($r.super_chain)       { $f.Add("u=" + (Q $r.super_chain)) }
    if ($r.remove -eq 'True') { $f.Add("r=true") }
    "{" + ($f -join ",") + "}"
  }
  [void]$sb.AppendLine(("SL[{0}]={{{1}}}" -f (Q $tpl), ($parts -join ",")))
}

# 8-8b) 체인 세트 정의 (parent 상속 + add/remove 항목)
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 체인 세트 정의 (p=상속부모 i=항목)")
[void]$sb.AppendLine("CA_BLD.cset = {}")
$allSets = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($s in $csets)  { [void]$allSets.Add($s.key) }
foreach ($i in $citems) { [void]$allSets.Add($i.set) }
foreach ($set in ($allSets | Sort-Object)) {
  $parts = foreach ($i in ($itemsBySet[$set] | Sort-Object chain, super_chain, remove)) {
    if (-not $i) { continue }
    $f = New-Object System.Collections.Generic.List[string]
    if ($i.chain)             { $f.Add("c=" + (Q $i.chain)) }
    if ($i.super_chain)       { $f.Add("u=" + (Q $i.super_chain)) }
    if ($i.remove -eq 'True') { $f.Add("r=true") }
    "{" + ($f -join ",") + "}"
  }
  $pp = if ($setParent[$set]) { "p=" + (Q $setParent[$set]) + "," } else { "" }
  [void]$sb.AppendLine(("CA_BLD.cset[{0}]={{{1}i={{{2}}}}}" -f (Q $set), $pp, ($parts -join ",")))
}

# 8-8c) 슈퍼체인 → 체인 (super_chain 전개용)
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 슈퍼체인 → 체인")
[void]$sb.AppendLine("CA_BLD.super = {}")
foreach ($sc in ($bySuper.Keys | Sort-Object)) {
  $cs = ($bySuper[$sc] | Sort-Object | ForEach-Object { Q $_ }) -join ","
  [void]$sb.AppendLine(("CA_BLD.super[{0}]={{{1}}}" -f (Q $sc), $cs))
}

# 8-9) 슬롯 템플릿의 자원(있는 것만)
[void]$sb.AppendLine("")
[void]$sb.AppendLine("-- 슬롯 템플릿 자원 (있는 것만)")
[void]$sb.AppendLine("CA_BLD.sres = {}")
foreach ($t in ($slotTpl | Where-Object { $_.resource } | Sort-Object key)) {
  [void]$sb.AppendLine(("CA_BLD.sres[{0}]={1}" -f (Q $t.key), (Q $t.resource)))
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine(("-- 슬롯템플릿 {0}(규칙 {1}행) · 체인세트 {2} · 체인 {3} · 레벨 {4} · 업그레이드 {5} · 태그 {6} · 유닛해금 {7}" -f `
  $permByTpl.Count, $perm.Count, $allSets.Count, $chainMeta.Count, $nLv, $upOf.Count, $tagOf.Count, $unitsOf.Count))
[void]$sb.AppendLine(("-- 참고: 규칙을 전부 펴면 {0} 엔트리가 된다(생성 시 오프라인 검증치)." -f `
  (($slotChains.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum)))

$outMain = Join-Path $OutDir "advisor_db_building.lua"
[System.IO.File]::WriteAllText($outMain, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))

# --- 9) 원시 효과행 (별도 파일 — 지금은 안 쓰지만 보존) ---
$fb = New-Object System.Text.StringBuilder
[void]$fb.AppendLine(@'
--[[===========================================================================
  TW3 어드바이저 — 건물 원시 효과행 (생성 · 손대지 말 것)
  ---------------------------------------------------------------------------
  생성기: scripts/gen_building_data.ps1   원본: building_effects_junction
  본체(advisor_db_building.lua)는 계열 태그만 쓴다. 이 파일은 나중에
  "수입 +N" 같은 수치 조언을 할 때를 위한 원본이다. 지금 읽는 코드는 없다.
  무게가 문제되면 이 파일만 빼면 된다.
    CA_BLD_FX[레벨키] = { {e=효과키, s=적용범위, v=값, q=조건}, ... }
    CA_BLD_EF[효과키] = { b=계열, g=양수가좋음, c=campaign/battle/both }
=============================================================================]]

CA_BLD_FX = {}
CA_BLD_EF = {}
local FX, EF = CA_BLD_FX, CA_BLD_EF
'@)
$fxBy = @{}
foreach ($j in $bfx) {
  if (-not $fxBy.ContainsKey($j.building)) { $fxBy[$j.building] = New-Object System.Collections.Generic.List[object] }
  $fxBy[$j.building].Add($j)
}
$usedEff = @{}
foreach ($k in ($fxBy.Keys | Sort-Object)) {
  $parts = foreach ($j in ($fxBy[$k] | Sort-Object effect, effect_scope)) {
    $usedEff[$j.effect] = $true
    $q = if ($j.context_requirement) { ",q=" + (Q $j.context_requirement) } else { "" }
    "{{e={0},s={1},v={2}{3}}}" -f (Q $j.effect), (Q $j.effect_scope), (N $j.value), $q
  }
  [void]$fb.AppendLine(("FX[{0}]={{{1}}}" -f (Q $k), ($parts -join ",")))
}
[void]$fb.AppendLine("")
foreach ($e in ($usedEff.Keys | Sort-Object)) {
  $m = $effMeta[$e]
  $b = Get-Bucket $e
  $g = if ($m -and $m.is_positive_value_good -eq 'True') { "true" } else { "false" }
  $c = if ($m) { Q $m.category } else { "nil" }
  [void]$fb.AppendLine(("EF[{0}]={{b={1},g={2},c={3}}}" -f (Q $e), (Q $b), $g, $c))
}
[void]$fb.AppendLine("")
[void]$fb.AppendLine(("-- 건물 {0}개 · 효과행 {1} · 효과종류 {2}" -f $fxBy.Count, $bfx.Count, $usedEff.Count))

$outFx = Join-Path $OutDir "advisor_db_building_fx.lua"
[System.IO.File]::WriteAllText($outFx, $fb.ToString(), (New-Object System.Text.UTF8Encoding $false))

$kb1 = [math]::Round((Get-Item $outMain).Length / 1KB, 1)
$kb2 = [math]::Round((Get-Item $outFx).Length / 1KB, 1)
Write-Host ("[생성] {0}  {1} KB" -f $outMain, $kb1) -ForegroundColor Green
Write-Host ("[생성] {0}  {1} KB" -f $outFx, $kb2) -ForegroundColor Green
Write-Host ("[요약] 슬롯템플릿 {0} · 체인 {1} · 레벨 {2} · 업그레이드 {3} · 태그 {4} · 유닛해금 {5} · 효과행 {6}" -f `
  $slotChains.Count, $chainMeta.Count, $nLv, $upOf.Count, $tagOf.Count, $unitsOf.Count, $bfx.Count) -ForegroundColor Cyan
