--[[===========================================================================
  TW3 어드바이저 — 건물 질의기 (advisor_db_building.lua를 읽어 답하는 쪽)
  ---------------------------------------------------------------------------
  왜 있는가: 런타임에 "이 슬롯에 뭘 지을 수 있나"를 묻는 API가 없다.
  게임이 알려주는 건 슬롯의 template_key / type / resource_key / 현재 건물뿐이다.
  그래서 DB에서 뽑아둔 규칙을 여기서 편다.

  실측으로 확인한 것(오프라인 검증):
    엠파이어 · 뉼른 철광 부차 슬롯(wh3_main_special_nuln_secondary_iron)
      허용 체인 488개 → 종족 필터 후 17개
      = 병영·농장·대장간·공업·마구간·주점·성벽·마법사탑·신전 ·
        미덴하임/탈라베크 신전 · 철 자원 · 뉼른 포병학교 · 도로 · 사격장 …
    젬 슬롯에서는 철 대신 보석 건물이 나오고, horde_primary는 엠파이어에 0개.
    체인 1943개 전부 '최저 레벨이 하나뿐' → 진입 건물이 모호하지 않다.

  로드 순서는 파일명 순이라 이 파일이 advisor_db_building.lua보다 먼저 뜬다.
  → CA_BLD 접근은 전부 '호출 시점'에만. 로드 시점에 만지면 nil이다.
=============================================================================]]

CA_BLDQ = {}

-- ── 내 진영 (한 판 동안 안 바뀐다 — 성공하면 한 번만 읽는다) ──────────
local me = nil
local function my_ctx()
	if me then return me end
	local f
	pcall(function() f = cm:get_local_faction(true) end)
	if not f then return nil end
	local c, s, n, g
	pcall(function() c = f:culture() end)
	pcall(function() s = f:subculture() end)
	pcall(function() n = f:name() end)
	-- 실측: 불멸의 제국에서 "main_warhammer"를 돌려준다(wh3_main_combi가 아니다).
	-- availability 표의 campaign 값은 ''(39행)와 'wh3_main_prologue'(5행)뿐이라
	-- 결과적으로 프롤로그 전용 세트만 걸러진다 — 의도한 동작이다.
	pcall(function() g = cm:get_campaign_name() end)
	if not c and not s and not n then return nil end   -- 하나도 못 읽었으면 보류(캐시하지 않음)
	me = { cul = c, sub = s, fac = n, camp = g }
	return me
end
function CA_BLDQ.me() return my_ctx() end

-- ── 체인 세트 전개 ────────────────────────────────────────────────────
--   cset[키] = { p = 상속부모, i = { {c=체인, u=슈퍼체인, r=제외}, ... } }
--   제외(r)는 추가를 전부 적용한 뒤에 뺀다. 표에 순서 의미가 있다는 근거를
--   못 찾았고, 순서 무관하게 두는 편이 결과가 안정적이다(생성기도 같은 규칙).
local set_cache = {}

local function apply_items(items, add, rm)
	if type(items) ~= "table" then return end
	local sup = CA_BLD and CA_BLD.super
	for _, it in ipairs(items) do
		local dst = it.r and rm or add
		if it.c then dst[it.c] = true end
		if it.u and sup then
			local lst = sup[it.u]
			if lst then for _, ck in ipairs(lst) do dst[ck] = true end end
		end
	end
end

-- guard는 순환 방어. 실제 데이터(세트 312개, 상속 최대 4단)에는 순환이 없지만,
-- 있더라도 무한재귀 대신 그 가지만 비우고 넘어간다.
local function resolve_set(key, guard)
	local hit = set_cache[key]
	if hit then return hit end
	local db = CA_BLD
	if not db or not db.cset then return {} end
	guard = guard or {}
	if guard[key] then return {} end
	guard[key] = true

	local out = {}
	local def = db.cset[key]
	if def then
		if def.p then
			for k in pairs(resolve_set(def.p, guard)) do out[k] = true end
		end
		local add, rm = {}, {}
		apply_items(def.i, add, rm)
		for k in pairs(add) do out[k] = true end
		for k in pairs(rm) do out[k] = nil end
	end
	set_cache[key] = out
	return out
end

-- ── 슬롯 템플릿 → 허용 체인 집합 ──────────────────────────────────────
--   전개 결과를 캐시한다. 한 판에서 마주치는 템플릿은 수십 개뿐이라
--   전부 펴도 부담이 없다(전체 642개를 미리 펴면 16만 엔트리라 안 한다).
local slot_cache = {}
function CA_BLDQ.slot_chains(tpl)
	if type(tpl) ~= "string" or tpl == "" then return nil end
	local hit = slot_cache[tpl]
	if hit then return hit end
	local db = CA_BLD
	if not db or not db.slot then return nil end

	local out = {}
	local rules = db.slot[tpl]
	if rules then
		local add, rm = {}, {}
		for _, r in ipairs(rules) do
			local dst = r.r and rm or add
			if r.c then dst[r.c] = true end
			if r.s then for k in pairs(resolve_set(r.s)) do dst[k] = true end end
			if r.u and db.super then
				local lst = db.super[r.u]
				if lst then for _, ck in ipairs(lst) do dst[ck] = true end end
			end
		end
		for k in pairs(rm) do add[k] = nil end
		out = add
	end
	slot_cache[tpl] = out
	return out
end

-- ── 종족 가용성 ───────────────────────────────────────────────────────
local ok_cache = {}
function CA_BLDQ.chain_ok(chain)
	local v = ok_cache[chain]
	if v ~= nil then return v end
	local db, m = CA_BLD, my_ctx()
	if not db or not db.av or not m then return false end

	local r = false
	local ids = db.av[chain]
	if ids then
		for _, id in ipairs(ids) do
			for _, rule in ipairs((db.rule and db.rule[id]) or {}) do
				if (rule.c == nil or rule.c == m.cul)
					and (rule.s == nil or rule.s == m.sub)
					and (rule.f == nil or rule.f == m.fac)
					and (rule.g == nil or rule.g == m.camp) then
					r = true
					break
				end
			end
			if r then break end
		end
	end
	-- 가용성 행이 아예 없는 체인 122개는 제외한다. dummy_nuclear_ruins,
	-- 잘려나간 기능(wh2_main_EMPIRE_academy), 폐기된 특수건물이 대부분이라
	-- '지을 수 없는 걸 권하는' 쪽이 '못 권하는' 쪽보다 나쁘다.
	ok_cache[chain] = r
	return r
end

-- ── 체인의 진입(최저) 레벨 ────────────────────────────────────────────
local entry_idx = nil
local function entries()
	if entry_idx then return entry_idx end
	entry_idx = {}
	local db = CA_BLD
	if not db or not db.lv then return entry_idx end
	for lk, v in pairs(db.lv) do
		local cur = entry_idx[v.ch]
		if cur == nil then
			entry_idx[v.ch] = lk
		else
			local cv = db.lv[cur]
			-- 동률이면 키 순 — 재실행마다 답이 달라지면 안 된다.
			if v.l < cv.l or (v.l == cv.l and lk < cur) then entry_idx[v.ch] = lk end
		end
	end
	return entry_idx
end
function CA_BLDQ.entry(chain) return entries()[chain] end
function CA_BLDQ.next(level_key)
	local db = CA_BLD
	return db and db.up and db.up[level_key] or nil
end
function CA_BLDQ.lv(level_key)
	local db = CA_BLD
	return db and db.lv and db.lv[level_key] or nil
end
function CA_BLDQ.tag(level_key)
	local db = CA_BLD
	return db and db.tag and db.tag[level_key] or nil
end
function CA_BLDQ.units(level_key)
	local db = CA_BLD
	return db and db.un and db.un[level_key] or nil
end

-- ── 한글 이름 ─────────────────────────────────────────────────────────
--   로컬 키 = "building_culture_variants_name_" + 레벨키 + 컬처 + 서브컬처 + 팩션
--   (구분자 없이 이어붙임. 빈 값은 뺀다. 5368/5414 적중 실측 확인)
--   여러 변형이 있으면 나에게 가장 구체적으로 맞는 행을 고른다:
--     팩션 일치 > 서브컬처 일치 > 컬처 일치 > 전부 빈칸.
--   나와 어긋나는 값이 하나라도 있으면 그 행은 후보에서 뺀다.
local function pick_variant(level_key)
	local db, m = CA_BLD, my_ctx()
	if not db or not db.cv then return nil end
	local rows = db.cv[level_key]
	if not rows then return nil end
	local best, bestScore = nil, -1
	for _, r in ipairs(rows) do
		local score, ok = 0, true
		if r.f then if m and r.f == m.fac then score = score + 4 else ok = false end end
		if ok and r.s then if m and r.s == m.sub then score = score + 2 else ok = false end end
		if ok and r.c then if m and r.c == m.cul then score = score + 1 else ok = false end end
		if ok and score > bestScore then best, bestScore = r, score end
	end
	return best
end

local name_cache = {}
function CA_BLDQ.name(level_key)
	if type(level_key) ~= "string" then return nil end
	local hit = name_cache[level_key]
	if hit then return hit end
	local disp = nil
	local v = pick_variant(level_key)
	if v then
		local suffix = level_key .. (v.c or "") .. (v.s or "") .. (v.f or "")
		pcall(function()
			local loc = common.get_localised_string("building_culture_variants_name_" .. suffix)
			if loc and loc ~= "" then disp = loc end
		end)
	end
	if not disp then
		-- 폴백: 키 꼬리에서 사람이 알아볼 만한 조각. 거짓 한글을 지어내지 않는다.
		disp = (level_key:gsub("^wh%d?_[%w]+_", ""):gsub("_", " "))
	end
	name_cache[level_key] = disp
	return disp
end

-- 이 조합에서 아예 꺼져 있는 건물인가 (culture_variants.disables)
function CA_BLDQ.disabled(level_key)
	local v = pick_variant(level_key)
	return (v and v.x) == true
end

-- ── 이 슬롯에 지금 지을 수 있는 후보 ──────────────────────────────────
--   반환: { {lv=레벨키, ch=체인, cost=, turns=, tag=, cat=}, ... } 비용 오름차순
--   ※ '수도 전용' 판정은 두지 않는다. only_in_capital이 5259행 전부 False라
--     거를 대상이 하나도 없다(실측). 죽은 가드는 없는 가드보다 나쁘다 —
--     읽는 사람이 그 경우가 처리됐다고 믿게 된다. resource_requirement(0행)도 같다.
--     되살릴 조건: 그 분포가 바뀌면 생성기에서 필드를 다시 담고 여기에 판정을 넣을 것.
--   결과는 템플릿 단위로 캐시한다. 한 지역의 빈 슬롯이 여러 개면 같은 템플릿을
--   반복해서 묻고, build_construction은 '가장 싼 것'을 찾느라 한 번 더 묻는다.
local cand_cache = {}
function CA_BLDQ.candidates(tpl)
	if type(tpl) ~= "string" then return nil end
	local hit = cand_cache[tpl]
	if hit then return hit end
	local db = CA_BLD
	local chains = CA_BLDQ.slot_chains(tpl)
	if not db or not chains then return nil end

	local out = {}
	for ch in pairs(chains) do
		if CA_BLDQ.chain_ok(ch) then
			local lk = CA_BLDQ.entry(ch)
			local v = lk and db.lv[lk]
			-- 문화 변형 행이 나와 맞아야 후보다. 근거: 556개 건물이 '팩션 지정 행만'
			-- 가진다(우드엘프 관청 = sisters_of_twilight·wood_elves 전용 등). 변형이
			-- 아예 없는 81개는 나가쉬 부유 피라미드 같은 스크립트 전용이라 역시 제외.
			local vr = lk and pick_variant(lk)
			if v and v.v ~= false and vr and not vr.x then
				out[#out + 1] = {
					lv = lk, ch = ch, cost = v.c or 0, turns = v.t or 0,
					upkeep = v.u or 0, food = v.f, dev = v.d,
					tag = db.tag and db.tag[lk] or nil,
					cat = db.ch and db.ch[ch] and db.ch[ch].cat or nil,
				}
			end
		end
	end
	table.sort(out, function(a, b)
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.lv < b.lv                                  -- 동률이면 키 순(결정적)
	end)
	cand_cache[tpl] = out
	return out
end

-- ── GDP 수익 추정 (v65 — fx 표 실사용) ────────────────────────────────
--   "수입 우선"일 때 후보를 계열 태그가 아니라 '얼마나 버는가'로 세우기 위한 값.
--   데이터: advisor_db_building_fx.lua(building_effects_junction 21,613행 — db 실측).
--   계산 규칙(보수적 — 실측 안 된 환산은 하지 않는다):
--     · 키에 economy_gdp 포함 + _mod 없음 → 정액 GDP/턴 (예: 직물공장 manufacture 250)
--     · economy_gdp_mod_all              → 지역 GDP의 v% (게임 표기와 같은 축)
--     · 그 밖의 _mod(카테고리 %)         → 제외 — 그 카테고리의 기반값을 모르면 과대평가다
--     · raid/sack/razing income 류        → economy_gdp 필터에 걸리지 않아 자동 제외
--     · scope는 '_own' 계열만, force 대상 제외
--   반환은 GDP/턴이다. 골드 환산(세율 반영)은 실측 전이라 하지 않는다 —
--   정렬(비용÷증가량)은 후보끼리의 비교라 단위가 약분돼 그대로 유효하다.
local fxsum_cache = {}
local function fx_gdp(level_key)
	local hit = fxsum_cache[level_key]
	if hit then return hit end
	local out = { flat = 0, pct = 0, skipped = 0 }
	local FX = CA_BLD_FX
	for _, r in ipairs((FX and FX[level_key]) or {}) do
		local e, s = r.e or "", r.s or ""
		if e:find("economy_gdp", 1, true)
			and (s == "this_building" or s:find("own", 1, true))
			and not s:find("force", 1, true) then
			if not e:find("_mod", 1, true) then
				out.flat = out.flat + (tonumber(r.v) or 0)
			elseif e:find("gdp_mod_all", 1, true) then
				out.pct = out.pct + (tonumber(r.v) or 0)
			else
				out.skipped = out.skipped + 1
			end
		end
	end
	fxsum_cache[level_key] = out
	return out
end

-- 이 건물이 서면 늘어나는 GDP/턴. 둘째 반환값 = 보수적으로 제외한 효과 수(프루프용).
function CA_BLDQ.gdp_gain(level_key, region_gdp)
	if type(level_key) ~= "string" then return 0, 0 end
	local x = fx_gdp(level_key)
	local g = x.flat
	if x.pct ~= 0 and type(region_gdp) == "number" and region_gdp > 0 then
		g = g + region_gdp * x.pct / 100
	end
	return math.floor(g + 0.5), x.skipped
end

-- 업그레이드의 GDP 증가분(다음 단계 − 현 단계).
function CA_BLDQ.gdp_delta(from_key, to_key, region_gdp)
	local a = CA_BLDQ.gdp_gain(to_key, region_gdp)
	local b = CA_BLDQ.gdp_gain(from_key, region_gdp)
	return a - b
end

-- ── 표시용 ────────────────────────────────────────────────────────────
local TAG_KO = {
	gdp = "수입", po = "치안", grw = "성장", cor = "타락", res = "연구",
	rec = "모병", rep = "충원", def = "방어", mag = "마법", sup = "보급",
	dip = "외교", att = "소모", upk = "유지비", mov = "기동", oth = "기타",
}
function CA_BLDQ.tag_ko(tag, max)
	if type(tag) ~= "string" or tag == "" then return nil end
	local out = {}
	for t in tag:gmatch("[^,]+") do
		out[#out + 1] = TAG_KO[t] or t
		if max and #out >= max then break end
	end
	if #out == 0 then return nil end
	return table.concat(out, "·")
end

-- 캐시 비우기(진영이 바뀌면 가용성·이름·후보가 전부 달라진다).
-- ※ 진영에 의존하는 캐시를 하나라도 빠뜨리면 남의 종족 답이 남는다.
--   name_cache는 pick_variant → my_ctx에 의존하고, cand_cache는 chain_ok에 의존한다.
--   (인게임에서는 세이브를 불러올 때 Lua 상태가 새로 뜨므로 호출자가 없다.
--    하니스가 픽스처마다 진영을 갈아 끼우며 쓴다.)
function CA_BLDQ.reset()
	me, entry_idx = nil, nil
	set_cache, slot_cache, ok_cache = {}, {}, {}
	name_cache, cand_cache, fxsum_cache = {}, {}, {}
end

if ADVISOR_TEST_EXPORTS then
	CA_TEST_BLD = {
		resolve_set = function(k) return resolve_set(k, nil) end,
		entries = entries,
		set_me = function(t) me = t end,
		TAG_KO = TAG_KO,
	}
end
