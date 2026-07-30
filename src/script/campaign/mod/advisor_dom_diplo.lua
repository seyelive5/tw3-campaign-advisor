--[[===========================================================================
  TW3 어드바이저 — 외교(Diplomacy) 탭 · v47
  ---------------------------------------------------------------------------
  실측 API (tw_autogen script_interfaces.lua / WH3 8.1.1):
    faction:factions_at_war_with() · factions_military_allies_with()
      · num_allies() · at_war()
      · diplomatic_attitude_towards(팩션키:string):number
      · diplomatic_standing_with(팩션키:string):integer
      · military_allies_with(팩션객체) · defensive_allies_with(팩션객체)
      · trade_agreement_with(팩션객체) · is_vassal_of(팩션객체)
      · unused_international_trade_route() · trade_route_limit_reached()
      · trade_value() · trade_value_percent()
    cm:cai_evaluate_quick_deal_action(내팩션, 상대팩션, diplomatic_option_*)
      → score, can_issue   (v36에서 인게임 실측 완료. CA_U.eval_deal이 감싼다)
  diplomatic_option_* 값은 바닐라 스크립트에 실재하는 것만 쓴다(37종 중 5종).
  ❌ 없는 것 / 아직 모르는 것(정직):
    - attitude·standing의 눈금. 둘 다 숫자인 것만 확정 → 날값으로만 보여 주고
      "관계가 좋다/나쁘다" 같은 임계 판정은 하지 않는다. 프루브로 표본 수집 중.
    - 상대가 무엇을 요구할지(대가). quick_deal은 성사 가부만 답한다.
    - 제3자끼리의 관계. 우리 기준 값만 조회 가능.
  CAI 호출은 비싸다 → 예산(BUDGET)을 두고 초과하면 조회를 멈추고 그 사실을 밝힌다.
  로드 순서 무보장 → CA_U/CA_DOMAINS 접근은 전부 '호출 시점'에만.
=============================================================================]]

CA_DOMAINS = CA_DOMAINS or {}

local function U() return CA_U or {} end
local function comma(n) local u = U(); return u.comma and u.comma(n) or tostring(math.floor(tonumber(n) or 0)) end
local function signed(n) local u = U(); return u.signed and u.signed(n) or tostring(math.floor(tonumber(n) or 0)) end
local function fdisp(k) local u = U(); return (u.fname and u.fname(k)) or tostring(k) end
local function say(msg) local u = U(); if u.proof then pcall(function() u.proof(msg, true) end) end end
local function names(list, n)
	local out = {}
	for i = 1, math.min(#list, n or 3) do out[#out + 1] = fdisp(list[i]) end
	return table.concat(out, ", ")
end
-- 조사. 팩션 이름은 현지화 결과라 받침을 미리 알 수 없다 → 반드시 CA_U.josa를 거친다.
local function J(s, withb, nob) local u = U(); return (u.josa and u.josa(s, withb, nob)) or withb end

local MAX_WAR, MAX_ALLY, MAX_OTHER = 10, 8, 8
local BUDGET = 18          -- 이번 탭에서 새로 쓸 CAI 평가 호출 수 상한

-- ── 수집 ──────────────────────────────────────────────────────────────
local function key_list(fl, cap)
	local ks = {}
	pcall(function()
		local n = fl:num_items()
		for i = 0, math.min(n, cap) - 1 do
			local of = fl:item_at(i)
			pcall(function() ks[#ks + 1] = of:name() end)
		end
	end)
	return ks
end

local function gather(f, S)
	local G = { wars = {}, allies = {}, rel = {},
	            deals = { trade = {}, nap = {}, confed = {} },
	            spent = 0, budget_hit = false }
	G.ok = pcall(function()
		-- 필수 두 가지. 개별 pcall로 감싸지 않는다 — 이걸 못 읽으면 외교 상태를
		-- 모르는 것이고, 그때 '전쟁 0 · 동맹 0'을 보여 주면 평온으로 위장하는 셈이다.
		G.wars   = key_list(f:factions_at_war_with(), MAX_WAR)
		G.allies = key_list(f:factions_military_allies_with(), MAX_ALLY)
		-- 아래는 종족·상황에 따라 없을 수 있는 값 → 실패하면 그 항목만 빠진다.
		pcall(function() G.at_war = f:at_war() end)
		pcall(function() G.n_allies = f:num_allies() end)
		pcall(function() G.trade_free = f:unused_international_trade_route() end)
		pcall(function() G.trade_full = f:trade_route_limit_reached() end)
		pcall(function() G.trade_value = f:trade_value() end)
		pcall(function() G.trade_pct = f:trade_value_percent() end)
	end)

	-- 관계 수치(우리 기준). 키 문자열 인자 — 실측 시그니처 그대로.
	local function rel_of(k)
		if G.rel[k] then return G.rel[k] end
		local r = {}
		pcall(function() r.standing = f:diplomatic_standing_with(k) end)
		pcall(function() r.attitude = f:diplomatic_attitude_towards(k) end)
		pcall(function()
			local of = cm:get_faction(k, false)
			if of and not of:is_null_interface() then
				pcall(function() r.trade = f:trade_agreement_with(of) end)
				pcall(function() r.mil = f:military_allies_with(of) end)
				pcall(function() r.def = f:defensive_allies_with(of) end)
			end
		end)
		G.rel[k] = r
		return r
	end
	G.rel_of = rel_of

	local seen = {}
	for _, k in ipairs(G.wars) do seen[k] = true; rel_of(k) end
	for _, k in ipairs(G.allies) do seen[k] = true; rel_of(k) end
	-- 비적대 이웃(기반 수집분 재사용 — 이웃 판정을 다시 하지 않는다)
	G.others = {}
	local bo = S and S.border_others
	if type(bo) == "table" then
		for i = 1, math.min(#bo, MAX_OTHER) do
			local k = bo[i]
			if not seen[k] then seen[k] = true; G.others[#G.others + 1] = k; rel_of(k) end
		end
	end

	-- 성사 가능한 딜. 화친·군사동맹은 기반 수집(S.diplo)이 이미 평가해 뒀으니
	-- 다시 묻지 않는다. 여기서는 교역·불가침·연맹만 예산 안에서 새로 묻는다.
	local eval = U().eval_deal
	local function ask(k, option)
		if not eval then return false end
		if G.spent >= BUDGET then G.budget_hit = true; return false end
		G.spent = G.spent + 1
		local ok2 = false
		pcall(function() ok2 = eval(f, k, option) end)
		return ok2 == true
	end
	for _, k in ipairs(G.others) do
		local r = G.rel[k] or {}
		if r.trade ~= true and ask(k, "diplomatic_option_trade_agreement") then
			G.deals.trade[#G.deals.trade + 1] = k
		end
		if ask(k, "diplomatic_option_nonaggression_pact") then
			G.deals.nap[#G.deals.nap + 1] = k
		end
	end
	for i = 1, math.min(#G.allies, 4) do        -- 연맹은 이미 동맹인 상대에게만 현실적
		local k = G.allies[i]
		if ask(k, "diplomatic_option_confederation") then
			G.deals.confed[#G.deals.confed + 1] = k
		end
	end
	return G
end

local function probe(G)
	local k = G.wars[1] or G.allies[1] or (G.others or {})[1]
	local r = k and G.rel[k] or {}
	say(string.format("[v47외교프로브] 전쟁=%s 동맹=%s(num_allies %s) 교역여유=%s 한도참=%s 교역액=%s 교역%%=%s | 표본 %s: standing=%s attitude=%s 교역=%s 군사동맹=%s 방어동맹=%s | CAI호출 %s%s",
		tostring(#G.wars), tostring(#G.allies), tostring(G.n_allies),
		tostring(G.trade_free), tostring(G.trade_full), tostring(G.trade_value), tostring(G.trade_pct),
		tostring(k), tostring(r.standing), tostring(r.attitude),
		tostring(r.trade), tostring(r.mil), tostring(r.def),
		tostring(G.spent), G.budget_hit and "(예산 소진)" or ""))
end

-- 관계 꼬리표. v64부터 판정이 붙는다 — 짐작이 아니라 게임 자체의 눈금이다.
-- 출처: db.pack `diplomatic_relations_attitudes`(7행, pos==size 검증):
--   best_friends 230 · very_friendly 70 · friendly 30 · neutral 0 ·
--   unfriendly -30 · very_unfriendly -70 · hostile -230
-- 게임 UI의 태도 아이콘이 쓰는 바로 그 구간이다. attitude(실수)가 그 대상이고,
-- 없으면 standing(정수·같은 축, 42턴 실측 -62.96 vs -66)으로 같은 구간을 쓴다.
local function att_label(v)
	if type(v) ~= "number" then return nil end
	if v >= 230 then return "최상"
	elseif v >= 70 then return "매우 우호적"
	elseif v >= 30 then return "우호적"
	elseif v > -30 then return "중립"
	elseif v > -70 then return "비우호적"
	elseif v > -230 then return "매우 비우호적"
	else return "적대적" end
end
local function rel_tag(r)
	if not r then return nil end
	local v = (type(r.attitude) == "number") and r.attitude
	        or ((type(r.standing) == "number") and r.standing or nil)
	if v == nil then return nil end
	local n = (type(r.standing) == "number") and r.standing or math.floor(v + 0.5)
	return string.format("%s(%s)", att_label(v), signed(n))
end

-- ── 본문 ─────────────────────────────────────────────────────────────
local function build(S, B)
	local f = nil
	pcall(function() f = cm:get_local_faction(true) end)
	if not f then
		say("[외교] 팩션 조회 실패")
		return { "⚠ 외교 정보를 읽지 못했습니다." }
	end

	local G = gather(f, S)
	probe(G)

	if not G.ok then
		say("[외교] 관계 목록 조회 실패")
		return { "⚠ 외교 정보를 읽지 못했습니다." }
	end

	-- 기반 수집이 이미 평가한 화친·군사동맹
	local dip = S and S.diplo
	local peace = (dip and dip.ok and dip.peace) or {}
	local ally_ok = (dip and dip.ok and dip.ally) or {}
	local dip_failed = not (dip and dip.ok)

	local L = {}
	local head = { string.format("전쟁 %d", #G.wars) }
	head[#head + 1] = string.format("동맹 %d", G.n_allies or #G.allies)
	if G.trade_value and G.trade_value ~= 0 then
		head[#head + 1] = "교역수입 " .. comma(G.trade_value)
	end
	if G.trade_free == true then head[#head + 1] = "교역로 여유 있음"
	elseif G.trade_full == true then head[#head + 1] = "교역로 한도 도달" end
	L[#L + 1] = "【외교】 " .. table.concat(head, " · ")

	-- 전쟁 중
	if #G.wars > 0 then
		local border = {}
		for _, k in ipairs((S and S.border_enemies) or {}) do border[k] = true end
		local ws = {}
		for _, k in ipairs(G.wars) do ws[#ws + 1] = k end
		table.sort(ws, function(a, b)   -- 국경 먼저, 그 다음 관계 낮은 순
			local ba, bb = border[a] and 1 or 0, border[b] and 1 or 0
			if ba ~= bb then return ba > bb end
			local sa = (G.rel[a] or {}).standing or 0
			local sb = (G.rel[b] or {}).standing or 0
			return sa < sb
		end)
		L[#L + 1] = ""
		L[#L + 1] = "─ 전쟁 중"
		local pset = {}
		for _, k in ipairs(peace) do pset[k] = true end
		for i = 1, math.min(#ws, 6) do
			local k = ws[i]
			local p = {}
			if border[k] then p[#p + 1] = "국경" end
			local t = rel_tag(G.rel[k]); if t then p[#p + 1] = t end
			if pset[k] then p[#p + 1] = "화친 가능" end
			L[#L + 1] = string.format("• %s%s", fdisp(k),
				(#p > 0) and (" — " .. table.concat(p, " · ")) or "")
		end
		if #ws > 6 then L[#L + 1] = string.format("  … 외 %d곳", #ws - 6) end
	end

	-- 우호(동맹·교역)
	local friends = {}
	for _, k in ipairs(G.allies) do friends[#friends + 1] = k end
	for _, k in ipairs(G.others) do
		local r = G.rel[k] or {}
		if r.trade == true or r.def == true then friends[#friends + 1] = k end
	end
	if #friends > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 우호"
		for i = 1, math.min(#friends, 6) do
			local k = friends[i]
			local r = G.rel[k] or {}
			local p = {}
			if r.mil == true then p[#p + 1] = "군사동맹" end
			if r.def == true then p[#p + 1] = "방어동맹" end
			if r.trade == true then p[#p + 1] = "교역" end
			local t = rel_tag(r); if t then p[#p + 1] = t end
			L[#L + 1] = string.format("• %s%s", fdisp(k),
				(#p > 0) and (" — " .. table.concat(p, " · ")) or "")
		end
	end

	-- 성사되는 것
	local rows = {}
	if #peace > 0 then rows[#rows + 1] = "• 화친: " .. names(peace, 3) end
	if #ally_ok > 0 then rows[#rows + 1] = "• 군사동맹: " .. names(ally_ok, 3) end
	if #G.deals.trade > 0 then rows[#rows + 1] = "• 교역: " .. names(G.deals.trade, 3) end
	if #G.deals.nap > 0 then rows[#rows + 1] = "• 불가침: " .. names(G.deals.nap, 3) end
	if #G.deals.confed > 0 then rows[#rows + 1] = "• 연맹: " .. names(G.deals.confed, 3) end
	-- "없습니다(제안해도 거절당합니다)"는 전수를 확인했을 때만 할 수 있는 단정이다.
	-- 조회가 일부 실패/미완이면 그 단정 대신 섹션을 아예 내지 않는다 — 틀린 확신도,
	-- 한계 고백도 화면에 두지 않는다(지시). 사유는 프루프로.
	local sure = (not dip_failed) and (not G.budget_hit)
	if #rows > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 지금 성사되는 것 (AI 수락 예측)"
		for _, r in ipairs(rows) do L[#L + 1] = r end
	elseif sure then
		L[#L + 1] = ""
		L[#L + 1] = "─ 지금 성사되는 것: 없습니다(제안해도 거절당합니다)."
	end
	if dip_failed then say("[외교] 기반 화친·동맹 평가 실패 — 성사 섹션에서 해당 항목 제외") end
	if G.budget_hit then say(string.format("[외교] CAI 평가 예산 %d회 소진 — 일부 상대 미확인", BUDGET)) end

	-- 조심할 곳(v36 CAI 스탠스 — 전쟁 전인데 적대)
	local hostile = S and S.strat and S.strat.hostile
	if type(hostile) == "table" and #hostile > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 조심할 곳"
		for i = 1, math.min(#hostile, 4) do
			local h = hostile[i]
			L[#L + 1] = string.format("• %s — 전쟁 전인데 우리를 적대시합니다(CAI %s).",
				fdisp(h.key), tostring(h.stance))
		end
	end

	-- 지금 할 일
	local todo = {}
	local function add(t) if #todo < 5 then todo[#todo + 1] = t end end
	local aggro = (S and S.stance == "aggro")   -- v74: 전투가 성장 엔진인 종족 — 화친 권고 금지
	if aggro then
		if #G.wars >= 3 then
			add(string.format("전선이 %d개지만 이 종족은 싸울수록 강해집니다 — 화친 대신 가장 약한 전선부터 끝내세요.", #G.wars))
		end
	elseif #G.wars >= 3 and #peace > 0 then
		local nm = names(peace, 1)
		add(string.format("전선이 %d개입니다 — %s%s 화친해 줄이세요(성사 가능).", #G.wars, nm, J(nm, "과", "와")))
	elseif #peace > 0 then
		local nm = names(peace, 2)
		add(string.format("%s%s 화친이 성사됩니다 — 전선을 줄일 기회입니다.", nm, J(nm, "과", "와")))
	end
	if #G.deals.confed > 0 then
		local nm = names(G.deals.confed, 1)
		add(string.format("%s%s 연맹이 성사됩니다 — 영토·군단을 통째로 흡수합니다. 최우선으로 검토하세요.",
			nm, J(nm, "과", "와")))
	end
	if #G.deals.trade > 0 and G.trade_full ~= true then
		local nm = names(G.deals.trade, 2)
		add(string.format("교역 여유가 있고 %s%s 체결됩니다 — 즉시 수입이 늘어납니다.", nm, J(nm, "과", "와")))
	elseif #G.deals.trade > 0 and G.trade_full == true then
		add("교역이 성사될 상대는 있으나 교역로 한도가 찼습니다 — 기존 교역을 정리해야 늘릴 수 있습니다.")
	end
	if (G.n_allies or 0) == 0 and #ally_ok > 0 then
		local nm = names(ally_ok, 2)
		add(string.format("동맹이 하나도 없습니다 — %s%s 군사동맹이 성사됩니다.", nm, J(nm, "과", "와")))
	end
	if type(hostile) == "table" and #hostile > 0 then
		local h = hostile[1]
		local nm = fdisp(h.key)
		local napset = {}
		for _, k in ipairs(G.deals.nap) do napset[k] = true end
		if napset[h.key] then
			add(string.format("%s%s 적대적입니다 — 불가침이 성사되니 지금 묶어 두세요.", nm, J(nm, "이", "가")))
		else
			add(string.format("%s%s 적대적입니다 — 국경 방비나 선제 중 하나를 준비하세요.", nm, J(nm, "이", "가")))
		end
	end

	L[#L + 1] = ""
	if #todo > 0 then
		L[#L + 1] = "─ 지금 할 일"
		for i, t in ipairs(todo) do L[#L + 1] = string.format("%d. %s", i, t) end
	elseif G.at_war == false then
		L[#L + 1] = "─ 지금 할 일: 없습니다. 전쟁도 없고 성사될 제안도 없으니 그냥 두면 됩니다."
	else
		L[#L + 1] = "─ 지금 할 일: 외교로 풀 수 있는 게 없습니다. 전쟁은 전장에서 끝내야 합니다."
	end

	-- 관계 수치의 눈금 미실측·대가 미조회 같은 한계 설명은 화면에서 뺐다(사용자 지적:
	-- 개발자 메타 발언). 동작은 그대로 — 날값을 '좋다/나쁘다'로 옮기지 않는다.
	return L
end

CA_DOMAINS[#CA_DOMAINS + 1] = { id = "diplo", order = 30, title = "외교", build = build }

-- 오프라인 하니스용 노출(인게임에선 전역이 nil이라 no-op)
if ADVISOR_TEST_EXPORTS then
	CA_TEST_DIPLO = { build = build, gather = gather, rel_tag = rel_tag, BUDGET = BUDGET }
end
