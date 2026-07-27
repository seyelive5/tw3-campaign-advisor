--[[===========================================================================
  TW3 어드바이저 — 내정(Domestic) 탭 · v54
  ---------------------------------------------------------------------------
  실측 API (tw_autogen script_interfaces.lua / WH3 8.1.1):
    region:gdp() · public_order() · faction_province_growth_per_turn()
         · num_buildings() · slot_list() · is_province_capital()
         · has_development_points_to_upgrade() · province_name()
         · garrison_residence():is_under_siege()
    slot:active() · has_building() · template_key() · building():name()
    cm:num_regions_controlled_in_province_by_faction(province객체, faction)
    faction:tax_level() · total_food()/food_production()/food_consumption()
         · has_food_shortages() · num_faction_slaves()/max_faction_slaves()
  ❌ 없는 것(정직):
    - can_build류 API. "이 슬롯에 뭘 지을 수 있나"를 게임에 물을 수 없다.
      → v54부터 slot:template_key()를 읽어 CA_BLDQ(건물 DB)로 후보를 푼다.
        DB 모델은 오프라인 검증을 마쳤고(뉼른 철광 슬롯 488→17 등), 인게임
        일치는 probe_bld의 [v54요약] 줄로 확인한다.
    - 호드 군단 건물. MILITARY_FORCE_SLOT 인터페이스는 있으나 그것을 돌려주는
      접근자가 전수 검색 0건 → 읽을 수 없다고 명시한다.
    - 지역별 순수입(수입-지출). gdp()는 있으나 유지비 배분은 없다.
  로드 순서 무보장 → CA_U/CA_DOMAINS 접근은 전부 '호출 시점'에만.
=============================================================================]]

CA_DOMAINS = CA_DOMAINS or {}

local function U() return CA_U or {} end
local function rdisp(k) local u = U(); return (u.region_disp and u.region_disp(k)) or tostring(k) end
local function pdisp(k) local u = U(); return (u.province_disp and u.province_disp(k)) or tostring(k) end
local function fdisp(k) local u = U(); return (u.fname and u.fname(k)) or tostring(k) end
local function say(msg) local u = U(); if u.proof then pcall(function() u.proof(msg, true) end) end end

-- 천 단위 구분 / 부호. 구현은 CA_U에 하나만 두고 여기서는 호출 시점에 가져온다
-- (로드 순서상 이 파일이 먼저라 CA_U는 로드 시점엔 아직 없다).
local function comma(n) local u = U(); return u.comma and u.comma(n) or tostring(math.floor(tonumber(n) or 0)) end
local function signed(n) local u = U(); return u.signed and u.signed(n) or tostring(math.floor(tonumber(n) or 0)) end

-- ── 수집 (탭을 처음 열 때 1회. 전 호출 pcall — 실패는 nil로 남기고 말하지 않는다) ──
local function gather(f)
	local G = { regions = {}, faction = {}, n_regions = 0, capped = false, budget = 260 }
	G.ok = pcall(function()
		local rl = f:region_list()
		local rn = rl:num_items()
		G.n_regions = rn
		local LIMIT = 30                       -- 성능 상한(대제국에서도 클릭당 비용 고정)
		G.capped = rn > LIMIT
		for i = 0, math.min(rn, LIMIT) - 1 do
			local reg = rl:item_at(i)
			local r = {}
			pcall(function() r.key = reg:name() end)
			pcall(function() r.prov = reg:province_name() end)
			pcall(function() r.capital = reg:is_province_capital() end)
			pcall(function() r.gdp = reg:gdp() end)
			pcall(function() r.po = reg:public_order() end)
			pcall(function() r.growth = reg:faction_province_growth_per_turn() end)
			pcall(function() r.nbuild = reg:num_buildings() end)
			pcall(function() r.dev = reg:has_development_points_to_upgrade() end)
			pcall(function()
				local gr = reg:garrison_residence()
				if gr and not gr:is_null_interface() then r.siege = gr:is_under_siege() end
			end)
			-- 슬롯: '활성인데 건물 없음' = 지금 지을 수 있는 자리.
			-- v54부터 자리 개수만 세지 않고 슬롯 템플릿 키와 현재 건물 키까지 읽는다.
			-- 그게 있어야 DB에서 "여기 뭘 지을 수 있나 / 다음 단계가 뭔가"를 답할 수 있다.
			-- 상세 조회는 예산(G.budget)으로 묶는다 — 대제국에서 클릭당 비용이 터지지 않게.
			pcall(function()
				local sl = reg:slot_list()
				local sn = sl:num_items()
				local empty, total = 0, 0
				r.free, r.built = {}, {}
				for j = 0, math.min(sn, 24) - 1 do
					local s = sl:item_at(j)
					local act, has = nil, nil
					pcall(function() act = s:active() end)
					pcall(function() has = s:has_building() end)
					if act ~= false then
						total = total + 1
						if has == false then
							empty = empty + 1
							if G.budget > 0 then
								G.budget = G.budget - 1
								local tk = nil
								pcall(function() tk = s:template_key() end)
								if tk and tk ~= "" then r.free[#r.free + 1] = tk end
							end
						elseif G.budget > 0 then
							G.budget = G.budget - 1
							local bk = nil
							pcall(function()
								local b = s:building()
								if b and not b:is_null_interface() then bk = b:name() end
							end)
							if bk and bk ~= "" then r.built[#r.built + 1] = bk end
						end
					end
				end
				r.slots_empty, r.slots_total = empty, total
			end)
			if r.key then G.regions[#G.regions + 1] = r end
		end
	end)
	-- 팩션 단위(종족마다 없는 값은 nil로 남겨 두고 출력에서 뺀다)
	local F = G.faction
	pcall(function() F.tax = f:tax_level() end)
	pcall(function() F.complete = f:num_complete_provinces() end)
	pcall(function() F.provinces = f:num_provinces() end)
	pcall(function() F.food = f:total_food() end)
	pcall(function() F.food_prod = f:food_production() end)
	pcall(function() F.food_use = f:food_consumption() end)
	pcall(function() F.food_short = f:has_food_shortages() end)
	pcall(function() F.slaves = f:num_faction_slaves() end)
	pcall(function() F.slaves_max = f:max_faction_slaves() end)
	return G
end

-- ── 미검증 API 실측 프로브 — 값 형태를 프루프에 남겨 다음 배치에서 채택 판단 ──
local function probe(G)
	if #G.regions == 0 then return end
	local r = G.regions[1]
	say(string.format("[v41내정프로브] %s gdp=%s po=%s 성장/턴=%s 건물수=%s 빈칸=%s/%s 개발P=%s | 세율=%s 식량=%s(%s-%s) 노예=%s/%s",
		tostring(r.key), tostring(r.gdp), tostring(r.po), tostring(r.growth), tostring(r.nbuild),
		tostring(r.slots_empty), tostring(r.slots_total), tostring(r.dev),
		tostring(G.faction.tax), tostring(G.faction.food), tostring(G.faction.food_prod),
		tostring(G.faction.food_use), tostring(G.faction.slaves), tostring(G.faction.slaves_max)))
end

-- ── v54 건물 DB 대조 프루브 ────────────────────────────────────────────
--   DB 모델은 오프라인에서만 검증했다(엠파이어 뉼른 철광 슬롯 488→17 등).
--   인게임 슬롯이 정말 그 template_key를 돌려주는지, 서 있는 건물 키가 정말
--   building_levels에 있는지는 여기서 찍어봐야 안다. 어긋나면 조언을 접는다.
local function probe_bld(G)
	if not CA_BLDQ then say("[v54건물] CA_BLDQ 없음 — 질의기 로드 실패"); return end
	local m = CA_BLDQ.me()
	say(string.format("[v54건물] 나 = cul=%s sub=%s fac=%s camp=%s",
		tostring(m and m.cul), tostring(m and m.sub), tostring(m and m.fac), tostring(m and m.camp)))
	if not CA_BLD then say("[v54건물] CA_BLD 없음 — 데이터 파일 로드 실패"); return end

	local shown, unknown_tpl, unknown_lv = 0, 0, 0
	for _, r in ipairs(G.regions) do
		-- 빈 슬롯: 템플릿이 표에 있는가 · 후보가 몇 개 나오는가
		for _, tpl in ipairs(r.free or {}) do
			local known = (CA_BLD.slot and CA_BLD.slot[tpl]) ~= nil
			if not known then unknown_tpl = unknown_tpl + 1 end
			if shown < 6 then
				shown = shown + 1
				local all = CA_BLDQ.slot_chains(tpl)
				local na = 0; if all then for _ in pairs(all) do na = na + 1 end end
				local c = CA_BLDQ.candidates(tpl, { capital = r.capital })
				local top = {}
				for i = 1, math.min(#(c or {}), 3) do
					top[#top + 1] = string.format("%s(%d금)", CA_BLDQ.name(c[i].lv), c[i].cost)
				end
				say(string.format("[v54빈칸] %s tpl=%s 표에있음=%s 체인=%d 후보=%d :: %s",
					tostring(r.key), tostring(tpl), tostring(known), na, #(c or {}),
					(#top > 0) and table.concat(top, " · ") or "(없음)"))
			end
		end
		-- 서 있는 건물: 키가 표에 있는가 · 다음 단계가 잡히는가
		for _, lk in ipairs(r.built or {}) do
			local v = CA_BLDQ.lv(lk)
			if not v then unknown_lv = unknown_lv + 1 end
			if shown < 12 then
				shown = shown + 1
				local nx = CA_BLDQ.next(lk)
				say(string.format("[v54건물] %s %s 표에있음=%s 이름=%s 사슬=%s 단계=%s 다음=%s%s",
					tostring(r.key), tostring(lk), tostring(v ~= nil), tostring(CA_BLDQ.name(lk)),
					tostring(v and v.ch), tostring(v and v.l), tostring(nx),
					nx and string.format("(%d금 %d턴)", (CA_BLDQ.lv(nx) or {}).c or -1, (CA_BLDQ.lv(nx) or {}).t or -1) or ""))
			end
		end
	end
	say(string.format("[v54요약] 모르는 슬롯템플릿 %d개 · 표에 없는 건물키 %d개 (0이어야 정상)",
		unknown_tpl, unknown_lv))
end

-- ── 건설 조언 ─────────────────────────────────────────────────────────
--   무엇이 필요한 계열인가. 재정이 위태로우면 무조건 수입이 먼저고,
--   아니면 그 지역이 실제로 앓는 것(치안·성장)에 맞춘다.
local function want_of(r, D)
	if D and D.money_trouble then return "gdp", "국고" end
	if r.po and r.po <= -15 then return "po", "치안" end
	if r.growth and r.growth <= 0 then return "grw", "성장" end
	return "gdp", "수입"
end

-- 태그 안에서 want가 몇 번째인가. 없으면 nil.
-- 태그는 '효과가 많은 계열 순'이라 앞에 올수록 그 건물의 본업에 가깝다.
-- 치안이 1순위인 술집과 3순위인 야간보초를 같은 취급 하면 조언이 엉뚱해진다.
local function tag_rank(tag, want)
	if type(tag) ~= "string" then return nil end
	local i = 0
	for t in tag:gmatch("[^,]+") do
		i = i + 1
		if t == want then return i end
	end
	return nil
end
local function has_tag(tag, want) return tag_rank(tag, want) ~= nil end

-- 추천 점수: 필요 계열에 가까울수록 · 지금 돈이 되면 가산.
local function score_of(cost, tag, want, purse)
	local r = tag_rank(tag, want)
	local s = r and (5 - math.min(r, 4)) * 2 or 0        -- 1순위 8 · 2순위 6 · 3순위 4 · 그밖 2
	if purse and cost <= purse then s = s + 1 end
	return s
end

-- 후보 한 줄 표시: 이름(비용/턴, 계열).
-- 왜 권하는지가 안 보이면 조언이 아니다 — 매칭된 계열을 반드시 앞에 세운다.
local function label_of(lv, cost, turns, tag, want, purse)
	local nm = CA_BLDQ.name(lv) or lv
	local why = nil
	if want and tag_rank(tag, want) then
		local head = CA_BLDQ.tag_ko(want, 1)
		local rest = CA_BLDQ.tag_ko((tag:gsub("^" .. want .. ",?", ""):gsub(",?" .. want .. "$", "")), 1)
		why = head .. ((rest and rest ~= "") and ("·" .. rest) or "")
	else
		why = CA_BLDQ.tag_ko(tag, 2)
	end
	if not why then
		local u = CA_BLDQ.units(lv)
		if u and #u > 0 then why = string.format("유닛 %d종", #u) end
	end
	local short = (purse and cost > purse) and " ✗국고부족" or ""
	return string.format("%s(%s금 %d턴%s)%s", nm, comma(cost), turns, why and (" " .. why) or "", short)
end

local function build_construction(G, S, D)
	if not CA_BLDQ or not CA_BLD then
		return { "─ 건설: 건물표를 읽지 못했습니다 — 판단을 보류합니다." }
	end
	local purse = (S and tonumber(S.treasury)) or nil

	-- ① 빈 슬롯 추천 (빈칸 많은 지역 우선, 최대 3곳)
	local withfree = {}
	for _, r in ipairs(G.regions) do
		if r.free and #r.free > 0 then withfree[#withfree + 1] = r end
	end
	table.sort(withfree, function(a, b)
		if #a.free ~= #b.free then return #a.free > #b.free end
		return tostring(a.key) < tostring(b.key)
	end)

	-- ② 업그레이드 후보 전부 모으기
	local ups = {}
	for _, r in ipairs(G.regions) do
		for _, lk in ipairs(r.built or {}) do
			local nx = CA_BLDQ.next(lk)
			local nv = nx and CA_BLDQ.lv(nx)
			if nv and nv.v ~= false and not CA_BLDQ.disabled(nx) then
				ups[#ups + 1] = { region = r.key, from = lk, to = nx,
				                  cost = nv.c or 0, turns = nv.t or 0,
				                  tag = CA_BLDQ.tag(nx), want = select(1, want_of(r, D)) }
			end
		end
	end

	local L = {}
	local nfree = 0
	for _, r in ipairs(withfree) do nfree = nfree + #r.free end
	L[#L + 1] = string.format("─ 건설 (읽은 빈칸 %d · 업그레이드 가능 %d)", nfree, #ups)

	if #withfree == 0 and #ups == 0 then
		L[#L + 1] = "  지금 지을 자리도, 올릴 건물도 없습니다(읽은 범위 안에서)."
		return L
	end

	-- 지금 국고로 감당되는 게 하나도 없으면 그것부터 말한다. 못 짓는 걸 아는 채로
	-- 목록만 늘어놓으면 v53에서 잡았던 '장부만 보고 흑자라 하던' 실수와 같은 결이 된다.
	local cheapest = nil
	for _, r in ipairs(withfree) do
		for _, tpl in ipairs(r.free) do
			local c = CA_BLDQ.candidates(tpl, { capital = r.capital })
			if c and c[1] and (not cheapest or c[1].cost < cheapest) then cheapest = c[1].cost end
		end
	end
	for _, u in ipairs(ups) do
		if not cheapest or u.cost < cheapest then cheapest = u.cost end
	end
	local broke = (purse and cheapest and purse < cheapest)
	if broke then
		L[#L + 1] = string.format("  ※ 국고 %s — 가장 싼 %s금짜리도 지금은 못 짓습니다. 아래는 돈이 모인 뒤 순서입니다.",
			comma(purse), comma(cheapest))
	end

	for i = 1, math.min(#withfree, 3) do
		local r = withfree[i]
		local want, why = want_of(r, D)
		-- 이 지역 빈 슬롯들의 후보를 합치고, 필요 계열 → 저렴한 순으로 고른다.
		local pool, seen = {}, {}
		for _, tpl in ipairs(r.free) do
			for _, c in ipairs(CA_BLDQ.candidates(tpl, { capital = r.capital }) or {}) do
				if not seen[c.lv] then seen[c.lv] = true; pool[#pool + 1] = c end
			end
		end
		table.sort(pool, function(a, b)
			local sa, sb = score_of(a.cost, a.tag, want, purse), score_of(b.cost, b.tag, want, purse)
			if sa ~= sb then return sa > sb end
			if a.cost ~= b.cost then return a.cost < b.cost end
			return a.lv < b.lv
		end)
		if #pool == 0 then
			L[#L + 1] = string.format("• %s 빈칸 %d — 지을 수 있는 것이 없습니다(자원·수도 조건).",
				rdisp(r.key), #r.free)
		else
			local top = {}
			for j = 1, math.min(#pool, 2) do
				top[#top + 1] = label_of(pool[j].lv, pool[j].cost, pool[j].turns, pool[j].tag, want, purse)
			end
			L[#L + 1] = string.format("• %s 빈칸 %d · %s 우선 → %s%s",
				rdisp(r.key), #r.free, why, table.concat(top, " · "),
				(#pool > 2) and string.format(" 외 %d", #pool - 2) or "")
		end
	end
	if #withfree > 3 then L[#L + 1] = string.format("  … 빈칸 있는 곳 %d곳 더", #withfree - 3) end

	if #ups > 0 then
		table.sort(ups, function(a, b)
			local sa, sb = score_of(a.cost, a.tag, a.want, purse), score_of(b.cost, b.tag, b.want, purse)
			if sa ~= sb then return sa > sb end
			if a.cost ~= b.cost then return a.cost < b.cost end
			return tostring(a.to) < tostring(b.to)
		end)
		for i = 1, math.min(#ups, 2) do
			local u = ups[i]
			L[#L + 1] = string.format("• 올리기: %s → %s @ %s",
				CA_BLDQ.name(u.from) or u.from,
				label_of(u.to, u.cost, u.turns, u.tag, u.want, purse), rdisp(u.region))
		end
	end
	return L
end

-- ── 정착지가 없는 진영(호드 등) — 내정 대신 실상을 말한다 ────────────
local function build_horde(S)
	local L = { "【내정】 아직 정착지가 없습니다." }
	L[#L + 1] = "호드는 군단 자체가 내정이지만, 군단 건물은 스크립트로 읽을 수 없어"
	L[#L + 1] = "(해당 슬롯을 돌려주는 API가 없습니다) 여기서는 다루지 않습니다."
	local cand = S and S.threats and S.threats.settle
	if type(cand) == "table" and #cand > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 첫 정착지 후보 (인근)"
		for i = 1, math.min(#cand, 5) do
			local c = cand[i]
			local tag = {}
			if not c.at_war then tag[#tag + 1] = "선전포고 필요" end
			if c.suit == "suitability_verypoor" then tag[#tag + 1] = "기후 부적합" end
			L[#L + 1] = string.format("• %s — %s%s", rdisp(c.region), fdisp(c.owner),
				(#tag > 0) and (" (" .. table.concat(tag, ", ") .. ")") or "")
		end
	end
	return L
end

-- ── 본문 ─────────────────────────────────────────────────────────────
local function build(S, B)
	local f = nil
	pcall(function() f = cm:get_local_faction(true) end)
	if not f then
		return { "⚠ 팩션을 읽지 못했습니다 — 판단을 보류합니다(조용함≠안전)." }
	end

	local G = gather(f)
	probe(G)
	probe_bld(G)
	local D = B and B.D

	if not G.ok then
		return { "⚠ 내정 정보를 읽지 못했습니다 — 판단을 보류합니다.",
		         "(지역 목록 조회 실패. 조용한 '문제 없음'으로 위장하지 않습니다.)" }
	end
	if G.n_regions == 0 then return build_horde(S) end

	local L, F = {}, G.faction

	-- 머리줄: 규모 + 빈칸 총계
	local empty_all, siege_n, dev_n = 0, 0, 0
	for _, r in ipairs(G.regions) do
		empty_all = empty_all + (r.slots_empty or 0)
		if r.siege then siege_n = siege_n + 1 end
		if r.dev then dev_n = dev_n + 1 end
	end
	local head = { string.format("영토 %d", G.n_regions) }
	if F.provinces then
		head[#head + 1] = string.format("속주 %d%s", F.provinces,
			F.complete and (F.complete > 0) and string.format("(완성 %d)", F.complete) or "")
	end
	head[#head + 1] = string.format("빈 건설칸 %d", empty_all)
	-- tax_level()은 인게임 실측 결과 1~5 '단계'가 아니라 100(=기본)이 나왔다. 눈금의
	-- 의미를 모르는 채 "단계"로 부르면 거짓말이 되므로, 기본값에서 벗어났을 때만 날값으로 알린다.
	if F.tax and F.tax ~= 100 then head[#head + 1] = string.format("세율 %s", tostring(F.tax)) end
	L[#L + 1] = "【내정】 " .. table.concat(head, " · ")

	-- 종족 자원(있는 진영만): 식량·노예
	local extra = {}
	if (F.food_prod and F.food_prod ~= 0) or (F.food and F.food ~= 0) or F.food_short then
		extra[#extra + 1] = string.format("식량 %s(생산 %s/소비 %s)%s",
			tostring(F.food or "?"), tostring(F.food_prod or "?"), tostring(F.food_use or "?"),
			F.food_short and " ⚠부족" or "")
	end
	if (F.slaves and F.slaves > 0) or (F.slaves_max and F.slaves_max > 0) then
		extra[#extra + 1] = string.format("노예 %s/%s", comma(F.slaves or 0), comma(F.slaves_max or 0))
	end
	if #extra > 0 then L[#L + 1] = "　" .. table.concat(extra, " · ") end

	-- 지역 목록(GDP 내림차순, 상위 8 + 외 N)
	local rs = {}
	for _, r in ipairs(G.regions) do rs[#rs + 1] = r end
	table.sort(rs, function(a, b) return (a.gdp or -1) > (b.gdp or -1) end)
	L[#L + 1] = ""
	L[#L + 1] = "─ 지역 (GDP 순)"
	for i = 1, math.min(#rs, 8) do
		local r = rs[i]
		local p = {}
		if r.gdp then p[#p + 1] = "GDP " .. comma(r.gdp) end
		if r.po then p[#p + 1] = string.format("치안 %s%s", signed(r.po),
			(r.po <= -50) and " ⚠반란임박" or ((r.po <= -15) and " ⚠" or "")) end
		if r.slots_empty and r.slots_empty > 0 then p[#p + 1] = string.format("빈칸 %d", r.slots_empty) end
		if r.growth then p[#p + 1] = "성장 " .. signed(r.growth) end
		if r.dev then p[#p + 1] = "개발P" end
		if r.siege then p[#p + 1] = "🛡포위중" end
		L[#L + 1] = string.format("• %s%s %s", rdisp(r.key), r.capital and "(수도)" or "",
			(#p > 0) and table.concat(p, " · ") or "(수치 없음)")
	end
	if #rs > 8 then L[#L + 1] = string.format("  … 외 %d곳", #rs - 8) end
	if G.capped then L[#L + 1] = string.format("  ※ 성능 상한으로 앞 %d곳만 읽었습니다(전체 %d).", #G.regions, G.n_regions) end

	-- 속주 진행도 — collect_strategic이 이미 계산한 값 재사용(중복 조회 안 함)
	local provs = S and S.strat and S.strat.provinces
	if type(provs) == "table" and #provs > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "─ 속주 진행"
		local shown = 0
		for _, p in ipairs(provs) do
			if shown >= 6 then break end
			shown = shown + 1
			if p.owned and p.total and p.owned >= p.total then
				L[#L + 1] = string.format("• %s %d/%d 완성", pdisp(p.key), p.owned, p.total)
			elseif p.owned and p.total then
				local miss = p.miss_region and string.format(" — 남은 곳: %s(%s)", rdisp(p.miss_region),
					p.miss_owner and fdisp(p.miss_owner) or "주인 없음") or ""
				L[#L + 1] = string.format("• %s %d/%d%s", pdisp(p.key), p.owned, p.total, miss)
			end
		end
	end

	-- 건설 (v54: 슬롯 템플릿 + 건물 DB로 '무엇을'까지 말한다)
	L[#L + 1] = ""
	for _, line in ipairs(build_construction(G, S, D)) do L[#L + 1] = line end

	-- 지금 손볼 곳(심각도 순, 최대 5)
	local todo = {}
	local function add(t) if #todo < 5 then todo[#todo + 1] = t end end
	if siege_n > 0 then
		local names = {}
		for _, r in ipairs(rs) do if r.siege and #names < 3 then names[#names + 1] = rdisp(r.key) end end
		add(string.format("%s 포위 중 — 내정보다 방어가 먼저입니다.", table.concat(names, ", ")))
	end
	local worst = nil
	for _, r in ipairs(rs) do
		if r.po and (not worst or r.po < worst.po) then worst = r end
	end
	if worst and worst.po <= -50 then
		add(string.format("%s 치안 %s — 반란 임박. 주둔군·칙령으로 즉시 눌러야 합니다.", rdisp(worst.key), signed(worst.po)))
	elseif worst and worst.po <= -15 then
		add(string.format("%s 치안 %s — 불안. 방치하면 반란으로 갑니다.", rdisp(worst.key), signed(worst.po)))
	end
	if F.food_short then add("식량 부족 — 성장·유지에 벌점이 붙습니다. 식량 건물·정착지를 늘리세요.") end
	if empty_all > 0 then
		local most = nil
		for _, r in ipairs(rs) do
			if (r.slots_empty or 0) > 0 and (not most or (r.slots_empty or 0) > (most.slots_empty or 0)) then most = r end
		end
		if most then
			-- 구체적인 추천은 위 '건설' 절에 있다. 여기서는 급한 정도만 알린다.
			add(string.format("빈 건설칸 %d개 — 가장 많이 빈 곳은 %s(%d칸). 위 건설 항목 참고.",
				empty_all, rdisp(most.key), most.slots_empty or 0))
		end
	end
	if dev_n > 0 then
		local d = nil
		for _, r in ipairs(rs) do if r.dev then d = r; break end end
		add(string.format("%s%s 개발 포인트 보유 — 정착지 등급을 올릴 수 있습니다.",
			d and rdisp(d.key) or "", (dev_n > 1) and string.format(" 외 %d곳", dev_n - 1) or ""))
	end
	local stall = nil
	for _, r in ipairs(rs) do
		if r.growth and r.growth <= 0 and not stall then stall = r end
	end
	if stall then
		add(string.format("%s 성장 %s — 정체 상태입니다. 성장 건물·칙령을 검토하세요.", rdisp(stall.key), signed(stall.growth)))
	end
	if type(provs) == "table" then
		for _, p in ipairs(provs) do
			if p.owned and p.total and p.total - p.owned == 1 and p.miss_region then
				add(string.format("%s 속주는 %s 한 곳만 더 얻으면 완성됩니다(칙령 개방).",
					pdisp(p.key), rdisp(p.miss_region)))
				break
			end
		end
	end
	L[#L + 1] = ""
	if #todo > 0 then
		L[#L + 1] = "─ 지금 손볼 곳"
		for i, t in ipairs(todo) do L[#L + 1] = string.format("%d. %s", i, t) end
	else
		L[#L + 1] = "─ 지금 손볼 곳: 눈에 띄는 문제가 없습니다(읽은 범위 안에서)."
	end

	if G.budget <= 0 then
		L[#L + 1] = ""
		L[#L + 1] = "※ 슬롯 상세 조회 예산을 다 썼습니다 — 뒤쪽 지역의 건설 후보는 빠졌습니다."
	end
	return L
end

CA_DOMAINS[#CA_DOMAINS + 1] = { id = "internal", order = 20, title = "내정", build = build }

-- 오프라인 하니스용 노출(인게임에선 전역이 nil이라 no-op)
if ADVISOR_TEST_EXPORTS then
	CA_TEST_INTERNAL = { build = build, gather = gather, comma = comma, signed = signed,
	                     build_horde = build_horde, build_construction = build_construction,
	                     want_of = want_of, has_tag = has_tag, label_of = label_of,
	                     tag_rank = tag_rank, score_of = score_of }
end
