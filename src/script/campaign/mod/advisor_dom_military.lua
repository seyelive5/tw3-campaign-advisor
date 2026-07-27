--[[===========================================================================
  TW3 어드바이저 — 군사(Military) 탭 · v46
  ---------------------------------------------------------------------------
  실측 API (tw_autogen script_interfaces.lua / WH3 8.1.1):
    faction:military_force_list()
    mf:has_general() · is_armed_citizenry() · is_navy() · general_character()
      · unit_list() · strength() · upkeep() · morale() · active_stance()
      · will_suffer_any_attrition() · contains_mercenaries()
      · can_recruit_unit_class(클래스키)
    unit:unit_class() · percentage_proportion_of_full_strength()
      · experience_level()
  unit_class 18종은 reference/db/unit_class.tsv 실측표 그대로 쓴다(추측 분류 금지).
  active_stance 값은 바닐라 스크립트에 실재하는 14종만 한글로 옮기고,
  모르는 값이 오면 접두사만 떼어 날값으로 보여 준다(지어내지 않는다).
  ❌ 없는 것(정직):
    - 모집 가능 '유닛 목록'. can_recruit_unit_class(클래스 가부)와
      can_recruit_unit(유닛키)뿐이라 유닛 키 목록이 없으면 이름을 못 댄다
      → 병종(클래스)까지만 말하고 구체 유닛명은 DB 추출 후로 미룬다.
    - morale() 눈금. 정수인 것만 확인됐고 범위·기준을 모른다
      → 프루브에만 남기고 조언에는 쓰지 않는다.
    - 호드 군단 건물(슬롯을 돌려주는 접근자가 없음).
  로드 순서 무보장 → CA_U/CA_DOMAINS 접근은 전부 '호출 시점'에만.
=============================================================================]]

CA_DOMAINS = CA_DOMAINS or {}

local function U() return CA_U or {} end
local function comma(n) local u = U(); return u.comma and u.comma(n) or tostring(math.floor(tonumber(n) or 0)) end
local function fdisp(k) local u = U(); return (u.fname and u.fname(k)) or tostring(k) end
local function say(msg) local u = U(); if u.proof then pcall(function() u.proof(msg, true) end) end end

-- unit_class.tsv 18종 → 화면에 쓸 6묶음. com(지휘)은 전투 편제에서 뺀다.
local GROUP = {
	inf_mel = "보병", inf_spr = "보병", inf_pik = "보병",
	inf_mis = "사격", cav_mis = "사격",
	cav_mel = "기병", cav_shk = "기병",
	chariot = "전차·괴수", elph = "전차·괴수",
	art_fld = "포병", art_fix = "포병", art_siege = "포병",
	spcl = "특수",
	com = "지휘",
	shp_art = "함선", shp_mel = "함선", shp_mis = "함선", shp_trn = "함선",
}
local GROUP_ORDER = { "보병", "사격", "기병", "전차·괴수", "포병", "특수" }

-- 이 병종이 없을 때 "뽑을 수 있는지" 물어볼 가치가 있는 것들(전 18종을 다 묻지
-- 않는 이유: can_recruit_unit_class 호출 비용이 군단 수만큼 곱해진다).
local ASK = {
	{ cls = "art_fld", name = "야포" },
	{ cls = "inf_mis", name = "사격보병" },
	{ cls = "cav_shk", name = "충격기병" },
	{ cls = "inf_spr", name = "창병" },
}

local STANCE = {
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_DEFAULT         = "기본",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_MARCH           = "행군",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_DOUBLE_TIME     = "강행군",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_AMBUSH          = "매복",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_SET_CAMP        = "야영",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_SET_CAMP_RAIDING= "약탈 야영",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_FIXED_CAMP      = "고정 야영",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_LAND_RAID       = "약탈",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_MUSTER          = "소집",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_SETTLE          = "정착",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_STALKING        = "잠행",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_CHANNELING      = "마력 집중",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_ASTROMANCY      = "점성",
	MILITARY_FORCE_ACTIVE_STANCE_TYPE_TUNNELING       = "지하 이동",
}
local function stance_disp(s)
	if type(s) ~= "string" or s == "" then return nil end
	if STANCE[s] then return STANCE[s] end
	return (s:gsub("^MILITARY_FORCE_ACTIVE_STANCE_TYPE_", ""))   -- 모르는 값은 날것으로
end

-- ── 수집 (탭을 처음 열 때 1회. 전 호출 pcall) ─────────────────────────
local MAX_FORCE, MAX_UNIT = 12, 25         -- 클릭당 비용 상한(대제국에서도 고정)

local function gather(f)
	local G = { armies = {}, navies = 0, n_forces = 0, capped = false,
	            upkeep = 0, units = 0, strength = 0, fill_sum = 0, fill_n = 0 }
	G.ok = pcall(function()
		local ml = f:military_force_list()
		local mn = ml:num_items()
		G.n_forces = mn
		G.capped = mn > MAX_FORCE
		for i = 0, math.min(mn, MAX_FORCE) - 1 do
			local mf = ml:item_at(i)
			local field = false
			pcall(function() field = mf:has_general() and not mf:is_armed_citizenry() end)
			local navy = false
			pcall(function() navy = mf:is_navy() end)
			if navy then G.navies = G.navies + 1 end
			if field and not navy then
				local a = { grp = {}, units = 0, combat = 0 }
				pcall(function()
					local loc = common.get_localised_string(mf:general_character():get_forename())
					if loc and loc ~= "" then a.name = loc end
				end)
				pcall(function() a.str = mf:strength() end)
				pcall(function() a.upkeep = mf:upkeep() end)
				pcall(function() a.morale = mf:morale() end)
				pcall(function() a.stance = mf:active_stance() end)
				pcall(function() a.attrition = mf:will_suffer_any_attrition() end)
				pcall(function() a.merc = mf:contains_mercenaries() end)
				pcall(function()
					local ul = mf:unit_list()
					local un = ul:num_items()
					a.units = un
					local psum, pcnt, xsum, xcnt = 0, 0, 0, 0
					for j = 0, math.min(un, MAX_UNIT) - 1 do
						local u = ul:item_at(j)
						pcall(function()
							local g = GROUP[u:unit_class()]
							if g then
								a.grp[g] = (a.grp[g] or 0) + 1
								if g ~= "지휘" then a.combat = a.combat + 1 end
							end
						end)
						pcall(function()
							local p = u:percentage_proportion_of_full_strength()
							if p then psum = psum + p; pcnt = pcnt + 1 end
						end)
						pcall(function()
							local x = u:experience_level()
							if x then xsum = xsum + x; xcnt = xcnt + 1 end
						end)
					end
					if pcnt > 0 then a.fill = math.floor(psum / pcnt + 0.5) end
					if xcnt > 0 then a.exp = xsum / xcnt end
					G.fill_sum, G.fill_n = G.fill_sum + psum, G.fill_n + pcnt   -- 전체 평균용(유닛 가중)
				end)
				-- 없는 병종 중 '지금 이 군단에서 뽑을 수 있는' 것만 추린다.
				a.canrec = {}
				for _, q in ipairs(ASK) do
					if (a.grp[GROUP[q.cls]] or 0) == 0 then
						local ok2 = nil
						pcall(function() ok2 = mf:can_recruit_unit_class(q.cls) end)
						if ok2 == true then a.canrec[#a.canrec + 1] = q.name end
					end
				end
				G.units    = G.units + (a.units or 0)
				G.upkeep   = G.upkeep + (a.upkeep or 0)
				G.strength = G.strength + (a.str or 0)
				G.armies[#G.armies + 1] = a
			end
		end
	end)
	return G
end

local function probe(G)
	local a = G.armies[1]
	if not a then return end
	say(string.format("[v46군사프로브] 군단수=%s(전체 %s) 유닛=%s 전력=%s 유지비=%s | 1군단: 사기=%s 태세=%s 소모=%s 용병=%s 충원=%s 경험=%s 모집가능=%s",
		tostring(#G.armies), tostring(G.n_forces), tostring(a.units), tostring(a.str),
		tostring(a.upkeep), tostring(a.morale), tostring(a.stance), tostring(a.attrition),
		tostring(a.merc), tostring(a.fill), tostring(a.exp),
		(#a.canrec > 0) and table.concat(a.canrec, "/") or "없음"))
end

-- 구성 한 줄: "보병 8 · 사격 5 · 기병 3 · 포병 0"
local function comp_line(a)
	local p = {}
	for _, g in ipairs(GROUP_ORDER) do
		local n = a.grp[g] or 0
		if n > 0 then p[#p + 1] = string.format("%s %d", g, n) end
	end
	if #p == 0 then return nil end
	return "   구성: " .. table.concat(p, " · ")
end

-- ── 본문 ─────────────────────────────────────────────────────────────
local function build(S, B)
	local f = nil
	pcall(function() f = cm:get_local_faction(true) end)
	if not f then
		say("[군사] 팩션 조회 실패")
		return { "⚠ 군사 정보를 읽지 못했습니다." }
	end

	local G = gather(f)
	probe(G)

	if not G.ok then
		say("[군사] 군단 목록 조회 실패")
		return { "⚠ 군사 정보를 읽지 못했습니다." }
	end

	local L = {}
	local n = #G.armies
	if n == 0 then
		L[#L + 1] = "【군사】 야전군이 없습니다."
		if G.navies > 0 then L[#L + 1] = string.format("함대 %d개는 있습니다(육상 조언 대상이 아닙니다).", G.navies) end
		L[#L + 1] = ""
		L[#L + 1] = "장군이 이끄는 군단이 하나도 없습니다. 방어는 주둔군에만 의존하는 상태입니다."
		L[#L + 1] = "군주·장군을 세우고 군단을 편성하는 것이 최우선입니다."
		return L
	end

	-- 머리줄
	local regions = (U().num and U().num(S and S.regions, 0)) or (S and S.regions) or 0
	if type(regions) ~= "number" then regions = 0 end
	local income = (S and type(S.income) == "number") and S.income or nil
	-- 충원율은 군단 평균의 평균이 아니라 유닛 전체 평균으로 낸다(4유닛 군단과
	-- 20유닛 군단을 같은 무게로 세면 실제 병력 상태와 어긋난다).
	local avg_fill = (G.fill_n > 0) and math.floor(G.fill_sum / G.fill_n + 0.5) or nil
	-- 표시와 임계 판정이 어긋나지 않도록 백분율은 한 번만 반올림해 둘 다 쓴다
	-- (69.6%를 "70%"로 보여 주면서 70% 임계엔 안 걸리는 일이 없게).
	local up_pct = (income and income > 0 and G.upkeep > 0)
		and math.floor(G.upkeep / income * 100 + 0.5) or nil

	local head = { string.format("야전군 %d", n), string.format("유닛 %d", G.units) }
	if avg_fill then head[#head + 1] = string.format("평균 충원 %d%%", avg_fill) end
	if G.upkeep > 0 then
		head[#head + 1] = string.format("유지비 %s%s", comma(G.upkeep),
			up_pct and string.format("(수입의 %d%%)", up_pct) or "")
	end
	if regions > 0 then head[#head + 1] = string.format("군대밀도 %.2f", n / regions) end
	L[#L + 1] = "【군사】 " .. table.concat(head, " · ")
	if G.capped then
		say(string.format("[군사] 부대 %d개 중 %d개만 스캔(상한)", G.n_forces, MAX_FORCE))
	end

	-- 군단 목록(전력 내림차순)
	local as = {}
	for _, a in ipairs(G.armies) do as[#as + 1] = a end
	table.sort(as, function(x, y) return (x.str or -1) > (y.str or -1) end)
	L[#L + 1] = ""
	L[#L + 1] = "─ 군단 (전력 순)"
	for i = 1, math.min(#as, 6) do
		local a = as[i]
		local p = {}
		if a.fill then p[#p + 1] = string.format("충원 %d%%", a.fill) end
		-- mf:strength()는 인게임 실측 결과 백만 단위 내부값이다(1군단 2,160,200).
		-- 그 절대값은 플레이어가 어디에도 대조할 수 없으니, 우리 총전력 대비
		-- 비중으로 바꿔 보여 준다 — 군단끼리 비교하는 데는 그게 필요한 값이다.
		if a.str and G.strength > 0 then
			p[#p + 1] = string.format("전력 비중 %d%%", math.floor(a.str / G.strength * 100 + 0.5))
		end
		if a.upkeep then p[#p + 1] = "유지 " .. comma(a.upkeep) end
		if a.exp then p[#p + 1] = string.format("경험 %.1f", a.exp) end
		local st = stance_disp(a.stance)
		if st and st ~= "기본" then p[#p + 1] = "태세 " .. st end
		if a.attrition then p[#p + 1] = "⚠소모" end
		if a.merc then p[#p + 1] = "용병" end
		L[#L + 1] = string.format("%d. %s (%d유닛) %s", i,
			a.name or "지휘관", a.units or 0,
			(#p > 0) and table.concat(p, " · ") or "")
		local c = comp_line(a)
		if c then L[#L + 1] = c end
	end
	if #as > 6 then L[#L + 1] = string.format("  … 외 %d개 군단", #as - 6) end

	-- 뽑을 수 있는데 없는 병종
	local recs = {}
	for _, a in ipairs(as) do
		if #a.canrec > 0 and #recs < 4 then
			recs[#recs + 1] = string.format("• %s: %s", a.name or "지휘관", table.concat(a.canrec, ", "))
		end
	end
	if #recs > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 지금 뽑을 수 있는데 빠진 병종"
		for _, r in ipairs(recs) do L[#L + 1] = r end
	end

	-- 지금 손볼 곳
	local todo = {}
	local function add(t) if #todo < 5 then todo[#todo + 1] = t end end

	local thin = nil
	for _, a in ipairs(as) do
		if a.fill and a.fill < 60 and (not thin or a.fill < thin.fill) then thin = a end
	end
	if thin then
		add(string.format("%s 충원 %d%% — 전투 전에 보충하세요(주둔·모병).",
			thin.name or "한 군단", thin.fill))
	end
	for _, a in ipairs(as) do
		if a.attrition then
			add(string.format("%s 소모 지역에 있습니다 — 이동하거나 태세를 바꾸세요.", a.name or "한 군단"))
			break
		end
	end
	local no_art, no_ranged = 0, 0
	for _, a in ipairs(as) do
		if (a.grp["포병"] or 0) == 0 then no_art = no_art + 1 end
		if (a.grp["사격"] or 0) == 0 then no_ranged = no_ranged + 1 end
	end
	if no_art == n then
		add("전 군단에 야포가 없습니다 — 성벽을 낀 공성이 길어집니다.")
	end
	if no_ranged == n and not (S and S.melee_race) then
		add("전 군단에 원거리가 없습니다 — 사격전에서 일방적으로 맞습니다.")
	end
	if regions > 0 and (n / regions) < 1 then
		add(string.format("영토 %d에 군단 %d — 방어선이 얇습니다. 증편을 검토하세요.", regions, n))
	end
	if up_pct and up_pct >= 70 then
		add(string.format("유지비가 수입의 %d%% — 재정이 군대에 묶여 있습니다.", up_pct))
	end
	local small = nil   -- 가장 작은 군단을 짚는다(먼저 나온 것이 아니라 — 충원율과 같은 기준)
	for _, a in ipairs(as) do
		local u = a.units or 0
		if u > 0 and u <= 12 and (not small or u < small.units) then small = a end
	end
	if small then
		add(string.format("%s 편제 %d유닛 — 정원에 못 미칩니다. 단독 교전은 피하세요.",
			small.name or "한 군단", small.units))
	end

	-- 국경 최강 적과의 전력비(전략 수집분 재사용 — 다시 조회하지 않는다)
	local en = S and S.strat and S.strat.enemy
	if type(en) == "table" and G.strength > 0 then
		local bk, bs = nil, 0
		for k, e in pairs(en) do
			if type(e) == "table" and type(e.strength) == "number" and e.strength > bs then bk, bs = k, e.strength end
		end
		if bk then
			local ratio = G.strength / bs
			L[#L + 1] = ""
			L[#L + 1] = string.format("─ 전력비: %s 대비 %.2f배(전국 기준)", fdisp(bk), ratio)
			if ratio < 0.8 then
				add(string.format("%s와의 야전 전력비가 %.2f배입니다 — 정면 충돌은 불리합니다.", fdisp(bk), ratio))
			end
		end
	end

	L[#L + 1] = ""
	if #todo > 0 then
		L[#L + 1] = "─ 지금 손볼 곳"
		for i, t in ipairs(todo) do L[#L + 1] = string.format("%d. %s", i, t) end
	else
		L[#L + 1] = "─ 지금 손볼 곳: 특별한 문제가 없습니다."
	end
	-- 모집 가능 유닛 '목록' API는 없다(can_recruit_unit_class로 병종 가부만) — 그래서
	-- 이 탭은 유닛 이름을 대지 않는다. 그 한계 설명을 화면에 쓰던 것은 뺐다(사용자 지적:
	-- 개발자 메타 발언). 유닛 이름은 내정 탭 건설 항목(건물→해금 유닛)이 맡는다.
	return L
end

CA_DOMAINS[#CA_DOMAINS + 1] = { id = "army", order = 50, title = "군사", build = build }

-- 오프라인 하니스용 노출(인게임에선 전역이 nil이라 no-op)
if ADVISOR_TEST_EXPORTS then
	CA_TEST_MILITARY = { build = build, gather = gather, stance_disp = stance_disp,
	                     comp_line = comp_line, GROUP = GROUP }
end
