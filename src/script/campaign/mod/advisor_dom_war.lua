--[[===========================================================================
  TW3 어드바이저 — 전쟁(War) 탭 · v48
  ---------------------------------------------------------------------------
  이 탭은 게임 API를 새로 부르지 않는다. 기반 수집(gather_threats /
  collect_strategic / gather_diplomacy / plan_revise)이 이미 모아 둔 것을
  전선 단위로 다시 엮을 뿐이다 — 같은 값을 두 번 읽지 않는다.
    S.war_set          전쟁 중 팩션 키 집합
    S.border_enemies   국경 접한 적(우선순위 순)
    S.strat.enemy[키]  { regions, rank, war_chest, strength }  (국경 적 최대 8)
    S.strat.my_strength 내 야전 전력 합
    S.threats.sieges     포위당한 내 지역 키 목록
    S.threats.threatened { region, faction, on_land, defended }
    S.threats.targets    { region, owner, my_border, suit, near }
    S.diplo.peace      화친이 성사되는 상대(CAI 예측)
    S.plan.steps       다턴 계획(kind=elim/peace/prov/prep/posture)
  ❌ 없는 것(정직):
    - '전선별' 전력. mf:strength()는 군단 단위, 팩션 합계만 낼 수 있어
      전력비는 전체 대 전체다 — 거리·배치를 반영하지 않는다고 밝힌다.
    - 적의 다음 수. CAI 스탠스·군비까지가 한계다.
    - 국경 밖(원거리) 전쟁 상대의 전력·영토. 스캔 대상이 아니라 수만 센다.
  로드 순서 무보장 → CA_U/CA_DOMAINS 접근은 전부 '호출 시점'에만.
=============================================================================]]

CA_DOMAINS = CA_DOMAINS or {}

local function U() return CA_U or {} end
local function comma(n) local u = U(); return u.comma and u.comma(n) or tostring(math.floor(tonumber(n) or 0)) end
local function fdisp(k) local u = U(); return (u.fname and u.fname(k)) or tostring(k) end
local function rdisp(k) local u = U(); return (u.region_disp and u.region_disp(k)) or tostring(k) end
local function say(msg) local u = U(); if u.proof then pcall(function() u.proof(msg, true) end) end end
local function J(s, withb, nob) local u = U(); return (u.josa and u.josa(s, withb, nob)) or withb end

local WAR_CHEST_LOW = 300      -- v36 실측 기준(본체 계획 엔진과 같은 값)
local RATIO_BAD, RATIO_GOOD = 0.8, 1.5

-- 전선 하나에 대한 한 줄 판정. 전력비를 모르면 모른다고 한다.
local function verdict(ratio, chest)
	if ratio == nil then
		return "전력 정보가 없어 승산은 따지지 않습니다."
	end
	local dry = (type(chest) == "number" and chest < WAR_CHEST_LOW)
	if ratio < RATIO_BAD then
		return "불리합니다. 방어를 굳히거나 화친을 검토하세요."
	elseif ratio >= RATIO_GOOD then
		return dry and "압도적이고 적은 군비가 말랐습니다 — 지금 몰아치세요."
		            or "우세합니다. 밀어붙일 수 있습니다."
	else
		return dry and "비등하지만 적 군비가 말랐습니다 — 소모전이면 우리가 이깁니다."
		            or "비등합니다. 증원 없이 정면 충돌은 도박입니다."
	end
end

-- ── 전선 엮기(순수 함수 — 게임 호출 없음) ───────────────────────────
local function fronts_of(S)
	local ST = (S and S.strat) or {}
	local mine = (type(ST.my_strength) == "number") and ST.my_strength or nil
	local border = {}
	for i, k in ipairs((S and S.border_enemies) or {}) do border[k] = i end

	local fronts, far = {}, 0
	local seen = {}
	local function push(k)
		if seen[k] then return end
		seen[k] = true
		local e = (type(ST.enemy) == "table" and ST.enemy[k]) or nil
		if not e and not border[k] then far = far + 1; return end   -- 국경 밖 = 상세 없음
		e = e or {}
		local ratio = nil
		if mine and type(e.strength) == "number" and e.strength > 0 then ratio = mine / e.strength end
		fronts[#fronts + 1] = {
			key = k, border = border[k] ~= nil, order = border[k] or 99,
			regions = e.regions, rank = e.rank, strength = e.strength,
			chest = e.war_chest, ratio = ratio,
		}
	end
	for _, k in ipairs((S and S.border_enemies) or {}) do push(k) end
	if type(S and S.war_set) == "table" then
		for k in pairs(S.war_set) do push(k) end
	end
	-- 정리하기 쉬운 순: 잔여 정착지 적은 쪽 먼저(계획 엔진과 같은 기준),
	-- 같으면 국경 우선순위. 정착지를 모르는 전선은 뒤로.
	table.sort(fronts, function(a, b)
		local ra = a.regions or 9999
		local rb = b.regions or 9999
		if ra ~= rb then return ra < rb end
		return a.order < b.order
	end)
	return fronts, far, mine
end

-- 계획이 지목한 제거 표적 / 화친 상대
local function plan_marks(S)
	local elim, peace = nil, nil
	pcall(function()
		for _, st in ipairs((S.plan and S.plan.steps) or {}) do
			if st.kind == "elim" and not elim then elim = st.key end
			if st.kind == "peace" and not peace then peace = st.key end
		end
	end)
	return elim, peace
end

-- ── 본문 ─────────────────────────────────────────────────────────────
local function build(S, B)
	S = S or {}
	local T = S.threats or {}
	local sieges = (type(T.sieges) == "table") and T.sieges or {}
	local threat = (type(T.threatened) == "table") and T.threatened or {}
	local targets = (type(T.targets) == "table") and T.targets or {}
	local peace_ok = (S.diplo and S.diplo.ok and S.diplo.peace) or {}
	local pset = {}
	for _, k in ipairs(peace_ok) do pset[k] = true end

	local fronts, far, mine = fronts_of(S)
	local elim_key, peace_key = plan_marks(S)

	say(string.format("[v48전쟁프로브] 전선=%s(국경밖 %s) 내전력=%s 포위=%s 위협=%s 표적=%s | 1전선: %s 잔여=%s 전력=%s 군비=%s",
		tostring(#fronts), tostring(far), tostring(mine), tostring(#sieges), tostring(#threat),
		tostring(#targets), tostring(fronts[1] and fronts[1].key),
		tostring(fronts[1] and fronts[1].regions), tostring(fronts[1] and fronts[1].strength),
		tostring(fronts[1] and fronts[1].chest)))

	-- 기반 수집이 통째로 실패했으면 빈 화면 대신 그 사실을 말한다(상세는 프루프로).
	if not (S.threats and S.threats.ok) and #fronts == 0 then
		say("[전쟁] 위협 수집 실패 + 전선 0 — 탭 보류")
		return { "⚠ 전쟁 정보를 읽지 못했습니다." }
	end

	local L = {}
	if #fronts == 0 and far == 0 then
		L[#L + 1] = "【전쟁】 전쟁 중인 상대가 없습니다."
		L[#L + 1] = ""
		if #threat > 0 or #sieges > 0 then
			L[#L + 1] = "다만 아래 위협이 잡혔습니다 — 확인하세요."
		else
			L[#L + 1] = "지금은 전장에서 할 일이 없습니다. 내정·확장에 집중할 때입니다."
			return L
		end
	else
		local head = { string.format("전선 %d", #fronts + far) }
		if #sieges > 0 then head[#head + 1] = string.format("포위당함 %d", #sieges) end
		if #threat > 0 then head[#head + 1] = string.format("위협받는 곳 %d", #threat) end
		L[#L + 1] = "【전쟁】 " .. table.concat(head, " · ")
	end

	-- 전선
	if #fronts > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 전선 (정리하기 쉬운 순)"
		for i = 1, math.min(#fronts, 5) do
			local w = fronts[i]
			local p = {}
			if w.border then p[#p + 1] = "국경" end
			if w.regions then p[#p + 1] = string.format("잔여 %d정착지", w.regions) end
			-- 전력의 절대값(인게임 실측: 백만 단위 내부값)은 대조할 데가 없어 숨기고
			-- 비율만 보여 준다. "전국 기준" = 거리·배치를 반영하지 않는 팩션 총합 대 총합
			-- (그 한계를 두 줄 강의하던 것을 세 글자 표기로 줄였다).
			if w.ratio then p[#p + 1] = string.format("전력비 %.2f배(전국 기준)", w.ratio)
			elseif w.strength then p[#p + 1] = "전력비 미상" end
			if w.rank then p[#p + 1] = string.format("국력 %d위", w.rank) end
			if type(w.chest) == "number" then p[#p + 1] = "군비 " .. comma(w.chest) end
			local mark = ""
			if w.key == elim_key then mark = " ◀ 계획상 1순위"
			elseif w.key == peace_key then mark = " ◀ 계획상 화친 대상" end
			L[#L + 1] = string.format("%d. %s%s", i, fdisp(w.key), mark)
			if #p > 0 then L[#L + 1] = "   " .. table.concat(p, " · ") end
			L[#L + 1] = "   " .. verdict(w.ratio, w.chest) ..
				(pset[w.key] and " (화친 가능)" or "")
		end
		if #fronts > 5 then L[#L + 1] = string.format("  … 외 %d전선", #fronts - 5) end
	end
	-- 국경 밖 전선은 머리줄의 "전선 N"에 이미 포함돼 있다. 상세를 안 읽었다는
	-- 각주는 화면에 내지 않는다(지시) — 수치는 프루프의 전쟁프로브에 있다.

	-- 방어
	if #sieges > 0 or #threat > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 방어"
		for i = 1, math.min(#sieges, 4) do
			L[#L + 1] = string.format("• 🛡 %s 포위 중 — 구원하지 않으면 함락됩니다.", rdisp(sieges[i]))
		end
		local shown = 0
		for _, a in ipairs(threat) do
			if shown >= 4 then break end
			shown = shown + 1
			L[#L + 1] = string.format("• ⚠ %s %s — %s%s", rdisp(a.region),
				a.on_land and "적군 진입" or "인접에 적군",
				a.defended and "근처에 아군 있음" or "무방비",
				a.faction and (" (" .. fdisp(a.faction) .. ")") or "")
		end
	end

	-- 칠 곳
	if #targets > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 칠 곳 (인접한 적 정착지)"
		for i = 1, math.min(#targets, 6) do
			local t = targets[i]
			local tag = {}
			if t.near then tag[#tag + 1] = "근접" end
			if t.suit == "suitability_verypoor" then tag[#tag + 1] = "기후 부적합" end
			L[#L + 1] = string.format("• %s(%s)%s", rdisp(t.region), fdisp(t.owner),
				(#tag > 0) and (" — " .. table.concat(tag, ", ")) or "")
		end
		if #targets > 6 then L[#L + 1] = string.format("  … 외 %d곳", #targets - 6) end
	end

	-- 지금 할 일 — 방어가 공격보다 먼저다
	local todo = {}
	local function add(t) if #todo < 5 then todo[#todo + 1] = t end end
	if #sieges > 0 then
		add(string.format("%s 포위를 먼저 풀어야 합니다 — 공세는 그 다음입니다.", rdisp(sieges[1])))
	end
	for _, a in ipairs(threat) do
		if not a.defended then
			add(string.format("%s 근처에 아군이 없습니다 — 수비대만으로 버텨야 합니다.", rdisp(a.region)))
			break
		end
	end
	local worst = nil
	for _, w in ipairs(fronts) do
		if w.ratio and w.ratio < RATIO_BAD and (not worst or w.ratio < worst.ratio) then worst = w end
	end
	if worst then
		local nm = fdisp(worst.key)
		if pset[worst.key] then
			add(string.format("%s%s 전력비 %.2f배로 불리합니다 — 화친이 성사되니 지금 접으세요.",
				nm, J(nm, "은", "는"), worst.ratio))
		else
			add(string.format("%s%s 전력비 %.2f배로 불리합니다 — 증원 전에는 방어에 머무세요.",
				nm, J(nm, "은", "는"), worst.ratio))
		end
	end
	local best = nil
	for _, w in ipairs(fronts) do
		if w.ratio and w.ratio >= RATIO_GOOD and w.regions and (not best or w.regions < best.regions) then best = w end
	end
	if best then
		local nm = fdisp(best.key)
		local near = nil
		for _, t in ipairs(targets) do if t.owner == best.key and t.near then near = t.region; break end end
		add(string.format("%s%s 잔여 %d정착지에 전력비 %.2f배 — 지금이 정리할 때입니다.%s",
			nm, J(nm, "은", "는"), best.regions, best.ratio,
			near and (" 다음 수: " .. rdisp(near) .. " 공략.") or ""))
	end
	if #fronts + far >= 3 and #peace_ok > 0 then
		add(string.format("전선이 %d개입니다 — 화친이 되는 곳부터 접어 전력을 모으세요.", #fronts + far))
	end

	L[#L + 1] = ""
	if #todo > 0 then
		L[#L + 1] = "─ 지금 할 일"
		for i, t in ipairs(todo) do L[#L + 1] = string.format("%d. %s", i, t) end
	else
		L[#L + 1] = "─ 지금 할 일: 특별히 급한 것이 없습니다."
	end
	-- 전력비 한계 강의 두 줄은 뺐다 — 각 줄의 "(전국 기준)" 표기로 충분하다.
	return L
end

CA_DOMAINS[#CA_DOMAINS + 1] = { id = "war", order = 60, title = "전쟁", build = build }

-- 오프라인 하니스용 노출(인게임에선 전역이 nil이라 no-op)
if ADVISOR_TEST_EXPORTS then
	CA_TEST_WAR = { build = build, fronts_of = fronts_of, verdict = verdict, plan_marks = plan_marks }
end
