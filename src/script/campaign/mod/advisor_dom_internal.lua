--[[===========================================================================
  TW3 어드바이저 — 내정(Domestic) 탭 · v41
  ---------------------------------------------------------------------------
  실측 API (tw_autogen script_interfaces.lua / WH3 8.1.1):
    region:gdp() · public_order() · faction_province_growth_per_turn()
         · num_buildings() · slot_list() · is_province_capital()
         · has_development_points_to_upgrade() · province_name()
         · garrison_residence():is_under_siege()
    slot:active() · has_building() · building():building_level()
    cm:num_regions_controlled_in_province_by_faction(province객체, faction)
    faction:tax_level() · total_food()/food_production()/food_consumption()
         · has_food_shortages() · num_faction_slaves()/max_faction_slaves()
  ❌ 없는 것(정직):
    - 건설 가능 건물 목록. 런타임에 "무엇을 지을 수 있는가"를 묻는 API가 없다
      (db 추출 필요 → 다음 배치). 그래서 이 탭은 '무엇을 지어라' 대신
      '어디가 비었고 어디가 급한가'까지만 말한다.
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
	local G = { regions = {}, faction = {}, n_regions = 0, capped = false }
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
			-- 슬롯: '활성인데 건물 없음' = 지금 지을 수 있는 자리
			pcall(function()
				local sl = reg:slot_list()
				local sn = sl:num_items()
				local empty, total = 0, 0
				for j = 0, math.min(sn, 24) - 1 do
					local s = sl:item_at(j)
					local act, has = nil, nil
					pcall(function() act = s:active() end)
					pcall(function() has = s:has_building() end)
					if act ~= false then
						total = total + 1
						if has == false then empty = empty + 1 end
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
		-- '어디부터'는 말할 수 있다(빈칸 최다 지역). '무엇을'은 db 없이는 못 말한다.
		local most = nil
		for _, r in ipairs(rs) do
			if (r.slots_empty or 0) > 0 and (not most or (r.slots_empty or 0) > (most.slots_empty or 0)) then most = r end
		end
		if most then
			add(string.format("빈 건설칸 %d개 — 가장 많이 빈 곳은 %s(%d칸)입니다.",
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

	L[#L + 1] = ""
	L[#L + 1] = "※ 어떤 건물을 지을지는 아직 말하지 않습니다 — 건설 후보를 묻는 API가"
	L[#L + 1] = "   없어 게임 DB 추출이 필요합니다(다음 배치)."
	return L
end

CA_DOMAINS[#CA_DOMAINS + 1] = { id = "internal", order = 20, title = "내정", build = build }

-- 오프라인 하니스용 노출(인게임에선 전역이 nil이라 no-op)
if ADVISOR_TEST_EXPORTS then
	CA_TEST_INTERNAL = { build = build, gather = gather, comma = comma, signed = signed,
	                     build_horde = build_horde }
end
