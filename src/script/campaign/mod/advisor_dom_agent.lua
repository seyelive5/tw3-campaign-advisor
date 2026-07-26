--[[===========================================================================
  TW3 어드바이저 — 기타(요원·첩보) 탭 · v49
  ---------------------------------------------------------------------------
  실측 API (tw_autogen script_interfaces.lua / WH3 8.1.1):
    faction:character_list() · get_foreign_visible_characters_for_player()
      · agent_cap(요원키) · agent_cap_remaining(요원키)
    character:character_type_key() · character_subtype_key() · rank()
      · is_wounded() · is_faction_leader() · has_region() · region()
      · action_points_remaining_percent() · get_forename()
    region:owning_faction():name()
  요원 타입 키는 바닐라 스크립트 실사용분만 쓴다(character_type("colonel"),
  agent_cap_remaining("wizard") 등에서 확인된 것). 목록에 없는 종족 고유
  요원은 우리가 실제로 보유한 인물의 character_type_key()로 알아낸다 —
  즉 '아는 키'와 '게임이 알려준 키'를 합쳐서 쓰고, 지어내지 않는다.
  ❌ 없는 것(정직):
    - 요원 행동(암살·방해 등)의 성공률. 조회 API가 없다.
    - 적 요원이 무엇을 하려는지. 위치와 정체까지가 한계다.
    - 우리 시야 밖의 적 인물. 보이는 것만 셀 수 있다.
  로드 순서 무보장 → CA_U/CA_DOMAINS 접근은 전부 '호출 시점'에만.
=============================================================================]]

CA_DOMAINS = CA_DOMAINS or {}

local function U() return CA_U or {} end
local function fdisp(k) local u = U(); return (u.fname and u.fname(k)) or tostring(k) end
local function rdisp(k) local u = U(); return (u.region_disp and u.region_disp(k)) or tostring(k) end
local function say(msg) local u = U(); if u.proof then pcall(function() u.proof(msg, true) end) end end
local function J(s, withb, nob) local u = U(); return (u.josa and u.josa(s, withb, nob)) or withb end

-- 바닐라 실사용에서 확인된 타입 키 → 한글. general/colonel은 요원이 아니라 군단 지휘.
local TYPE_KO = {
	general = "군주·장군", colonel = "부관",
	wizard = "마법사", champion = "용사", dignitary = "고관",
	spy = "첩자", engineer = "기술자", runesmith = "룬장인", minister = "대신",
}
local LEADERS = { general = true, colonel = true }
-- 정원을 물어볼 요원 타입(보유 0이어도 '뽑을 자리'를 알려면 물어봐야 한다).
local ASK_CAP = { "wizard", "champion", "dignitary", "spy", "engineer", "runesmith", "minister" }

local function tdisp(k) return TYPE_KO[k] or tostring(k) end

local MAX_MINE, MAX_FOREIGN = 40, 30

-- ── 수집 ──────────────────────────────────────────────────────────────
local function gather(f, my_key)
	local G = { agents = {}, order = {}, leaders = 0, cap = {},
	            foreign = {}, foreign_n = 0, foreign_capped = false,
	            wounded = {}, idle = {} }
	G.ok = pcall(function()
		-- 내 인물. 실패를 개별 pcall로 숨기지 않는다 — 이걸 못 읽으면 아무 말도 할 수 없다.
		local cl = f:character_list()
		local n = cl:num_items()
		G.n_chars = n
		for i = 0, math.min(n, MAX_MINE) - 1 do
			local ch = cl:item_at(i)
			local tk = nil
			pcall(function() tk = ch:character_type_key() end)
			if tk then
				if LEADERS[tk] then
					G.leaders = G.leaders + 1
				else
					local a = G.agents[tk]
					if not a then a = { n = 0, rank = 0, rank_n = 0 }; G.agents[tk] = a; G.order[#G.order + 1] = tk end
					a.n = a.n + 1
					pcall(function()
						local r = ch:rank()
						if r then a.rank = a.rank + r; a.rank_n = a.rank_n + 1 end
					end)
					local nm = nil
					pcall(function()
						local loc = common.get_localised_string(ch:get_forename())
						if loc and loc ~= "" then nm = loc end
					end)
					nm = nm or "이름 미상"
					local hurt = nil
					pcall(function() hurt = ch:is_wounded() end)
					if hurt == true and #G.wounded < 5 then
						G.wounded[#G.wounded + 1] = { name = nm, tk = tk }
					elseif #G.idle < 5 then
						local ap = nil
						pcall(function() ap = ch:action_points_remaining_percent() end)
						if type(ap) == "number" and ap >= 100 then
							G.idle[#G.idle + 1] = { name = nm, tk = tk }
						end
					end
				end
			end
		end
	end)

	-- 정원. 종족에 없는 요원은 0이 나오거나 조회가 실패한다 → 그 항목만 빠진다.
	local asked = {}
	local function cap_of(k)
		if asked[k] then return end
		asked[k] = true
		local total, rest = nil, nil
		pcall(function() total = f:agent_cap(k) end)
		pcall(function() rest = f:agent_cap_remaining(k) end)
		if type(total) == "number" or type(rest) == "number" then
			G.cap[k] = { total = total, rest = rest }
		end
	end
	for _, k in ipairs(ASK_CAP) do cap_of(k) end
	for _, k in ipairs(G.order) do cap_of(k) end   -- 종족 고유 요원(게임이 알려준 키)

	-- 우리 눈에 보이는 외국 인물. 팩션별로 묶고, 우리 땅에 서 있는 것만 따로 센다.
	pcall(function()
		local fl = f:get_foreign_visible_characters_for_player()
		local n = fl:num_items()
		G.foreign_n = n
		G.foreign_capped = n > MAX_FOREIGN
		local byf = {}
		for i = 0, math.min(n, MAX_FOREIGN) - 1 do
			local ch = fl:item_at(i)
			local fk, tk, on_mine, rk = nil, nil, false, nil
			pcall(function() fk = ch:faction():name() end)
			pcall(function() tk = ch:character_type_key() end)
			pcall(function()
				if ch:has_region() then
					local reg = ch:region()
					rk = reg:name()
					local of = reg:owning_faction()
					if of and not of:is_null_interface() and of:name() == my_key then on_mine = true end
				end
			end)
			if fk then
				local e = byf[fk]
				if not e then e = { key = fk, n = 0, agents = 0, inside = 0, where = nil }; byf[fk] = e; G.foreign[#G.foreign + 1] = e end
				e.n = e.n + 1
				if tk and not LEADERS[tk] then e.agents = e.agents + 1 end
				if on_mine then e.inside = e.inside + 1; e.where = e.where or rk end
			end
		end
	end)
	return G
end

local function probe(G)
	local first = G.order[1]
	local caps = {}
	for _, k in ipairs(ASK_CAP) do
		local c = G.cap[k]
		if c then caps[#caps + 1] = string.format("%s=%s/%s", k, tostring(c.rest), tostring(c.total)) end
	end
	-- 보유 요원의 타입 키를 전부 남긴다 — 종족 고유 요원의 실제 키를 알아야
	-- 다음 배치에서 한글 라벨을 채울 수 있다(지금은 날값으로 나간다).
	local kinds = {}
	for _, k in ipairs(G.order) do kinds[#kinds + 1] = k .. "x" .. tostring(G.agents[k].n) end
	say(string.format("[v49기타프로브] 인물=%s 지휘=%s 요원종류=%s[%s] 부상=%s 유휴=%s | 정원 %s | 외국인물=%s(팩션 %s)%s",
		tostring(G.n_chars), tostring(G.leaders), tostring(#G.order),
		(#kinds > 0) and table.concat(kinds, ",") or tostring(first),
		tostring(#G.wounded), tostring(#G.idle),
		(#caps > 0) and table.concat(caps, " ") or "없음",
		tostring(G.foreign_n), tostring(#G.foreign),
		G.foreign_capped and "(상한 초과)" or ""))
end

-- ── 본문 ─────────────────────────────────────────────────────────────
local function build(S, B)
	local f, my_key = nil, (S and S.faction) or nil
	pcall(function() f = cm:get_local_faction(true) end)
	if not f then
		return { "⚠ 팩션을 읽지 못했습니다 — 판단을 보류합니다(조용함≠안전)." }
	end
	if not my_key then pcall(function() my_key = f:name() end) end

	local G = gather(f, my_key)
	probe(G)

	if not G.ok then
		return { "⚠ 인물 정보를 읽지 못했습니다 — 판단을 보류합니다.",
		         "(인물 목록 조회 실패. 조용한 '문제 없음'으로 위장하지 않습니다.)" }
	end

	local L = {}
	local total_agents, free_slots = 0, 0
	for _, k in ipairs(G.order) do total_agents = total_agents + G.agents[k].n end
	for _, c in pairs(G.cap) do if type(c.rest) == "number" and c.rest > 0 then free_slots = free_slots + c.rest end end

	local head = { string.format("요원 %d명", total_agents) }
	if free_slots > 0 then head[#head + 1] = string.format("빈 자리 %d", free_slots) end
	if G.leaders > 0 then head[#head + 1] = string.format("군주·장군 %d", G.leaders) end
	if G.foreign_n > 0 then head[#head + 1] = string.format("포착된 외국 인물 %d", G.foreign_n) end
	L[#L + 1] = "【기타 · 요원】 " .. table.concat(head, " · ")

	-- 보유 요원
	if #G.order > 0 then
		table.sort(G.order, function(a, b) return G.agents[a].n > G.agents[b].n end)
		L[#L + 1] = ""
		L[#L + 1] = "─ 보유 요원"
		for _, k in ipairs(G.order) do
			local a = G.agents[k]
			local p = {}
			local c = G.cap[k]
			if c and type(c.rest) == "number" then
				p[#p + 1] = (c.rest > 0) and string.format("정원 여유 %d", c.rest) or "정원 참"
			end
			if a.rank_n > 0 then p[#p + 1] = string.format("평균 등급 %.1f", a.rank / a.rank_n) end
			L[#L + 1] = string.format("• %s %d명%s", tdisp(k), a.n,
				(#p > 0) and (" — " .. table.concat(p, " · ")) or "")
		end
	else
		L[#L + 1] = ""
		L[#L + 1] = "─ 보유 요원: 없습니다."
	end

	-- 뽑을 수 있는 빈 자리(보유 0인 종류까지 포함 — 여기가 이 탭의 핵심)
	local slots = {}
	for _, k in ipairs(ASK_CAP) do
		local c = G.cap[k]
		if c and type(c.rest) == "number" and c.rest > 0 then
			slots[#slots + 1] = string.format("%s %d자리", tdisp(k), c.rest)
		end
	end
	for _, k in ipairs(G.order) do          -- 종족 고유 요원도 빠뜨리지 않는다
		local c = G.cap[k]
		local known = false
		for _, a in ipairs(ASK_CAP) do if a == k then known = true end end
		if not known and c and type(c.rest) == "number" and c.rest > 0 then
			slots[#slots + 1] = string.format("%s %d자리", tdisp(k), c.rest)
		end
	end
	if #slots > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 지금 뽑을 수 있는 자리"
		L[#L + 1] = "  " .. table.concat(slots, " · ")
	end

	-- 부상·유휴
	if #G.wounded > 0 or #G.idle > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 손볼 인물"
		for _, w in ipairs(G.wounded) do
			L[#L + 1] = string.format("• %s(%s) 부상 — 회복까지 쓸 수 없습니다.", w.name, tdisp(w.tk))
		end
		for _, w in ipairs(G.idle) do
			L[#L + 1] = string.format("• %s(%s) 이번 턴 아직 움직이지 않았습니다.", w.name, tdisp(w.tk))
		end
	end

	-- 외국 인물
	if #G.foreign > 0 then
		table.sort(G.foreign, function(a, b)
			if a.inside ~= b.inside then return a.inside > b.inside end
			return a.n > b.n
		end)
		L[#L + 1] = ""
		L[#L + 1] = "─ 우리 눈에 보이는 외국 인물"
		for i = 1, math.min(#G.foreign, 5) do
			local e = G.foreign[i]
			local p = { string.format("%d명", e.n) }
			if e.agents > 0 then p[#p + 1] = string.format("요원 %d", e.agents) end
			if e.inside > 0 then
				p[#p + 1] = string.format("우리 땅에 %d%s", e.inside,
					e.where and ("(" .. rdisp(e.where) .. ")") or "")
			end
			L[#L + 1] = string.format("• %s — %s", fdisp(e.key), table.concat(p, " · "))
		end
		if #G.foreign > 5 then L[#L + 1] = string.format("  … 외 %d팩션", #G.foreign - 5) end
		if G.foreign_capped then
			L[#L + 1] = string.format("  ※ 성능 상한으로 앞 %d명만 셌습니다(전체 %d).", MAX_FOREIGN, G.foreign_n)
		end
	end

	-- 지금 할 일
	local todo = {}
	local function add(t) if #todo < 5 then todo[#todo + 1] = t end end
	local intruder = nil
	for _, e in ipairs(G.foreign) do if e.inside > 0 and e.agents > 0 then intruder = e; break end end
	if intruder then
		local nm = fdisp(intruder.key)
		add(string.format("%s%s 요원이 우리 땅에 있습니다%s — 우리 요원으로 막거나 군단을 붙이세요.",
			nm, J(nm, "의", "의"), intruder.where and (" (" .. rdisp(intruder.where) .. ")") or ""))
	end
	if #G.wounded > 0 then
		add(string.format("%s%s 부상 중입니다 — 회복 전에는 전력에서 빼고 계산하세요.",
			G.wounded[1].name, J(G.wounded[1].name, "이", "가")))
	end
	if #slots > 0 then
		-- 목록은 위 섹션에 이미 다 있다. 조언 줄은 앞 셋까지만(한 줄이 화면을 먹지 않게).
		local short = {}
		for i = 1, math.min(#slots, 3) do short[#short + 1] = slots[i] end
		add(string.format("빈 자리가 있습니다(%s%s) — 유지비만 감당되면 바로 뽑는 편이 이득입니다.",
			table.concat(short, ", "), (#slots > 3) and string.format(" 외 %d종", #slots - 3) or ""))
	end
	if #G.idle > 0 then
		add(string.format("%s%s 이번 턴 아직 안 움직였습니다 — 턴을 넘기기 전에 쓰세요.",
			G.idle[1].name, J(G.idle[1].name, "은", "는")))
	end

	L[#L + 1] = ""
	if #todo > 0 then
		L[#L + 1] = "─ 지금 할 일"
		for i, t in ipairs(todo) do L[#L + 1] = string.format("%d. %s", i, t) end
	else
		L[#L + 1] = "─ 지금 할 일: 요원 쪽에 급한 것이 없습니다(읽은 범위 안에서)."
	end

	L[#L + 1] = ""
	L[#L + 1] = "※ 요원 행동의 성공률과 적 요원의 의도는 조회할 방법이 없습니다."
	L[#L + 1] = "   보이지 않는 곳의 적 인물도 셀 수 없습니다 — 여기 없다고 없는 게 아닙니다."
	return L
end

CA_DOMAINS[#CA_DOMAINS + 1] = { id = "agent", order = 70, title = "기타", build = build }

-- 오프라인 하니스용 노출(인게임에선 전역이 nil이라 no-op)
if ADVISOR_TEST_EXPORTS then
	CA_TEST_AGENT = { build = build, gather = gather, tdisp = tdisp, TYPE_KO = TYPE_KO, ASK_CAP = ASK_CAP }
end
