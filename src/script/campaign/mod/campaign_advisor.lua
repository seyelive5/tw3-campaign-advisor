--[[===========================================================================
  TW3 캠페인 어드바이저 — Phase 2 / 2a (v6: 분석 두뇌 + 조언 생성)
  ---------------------------------------------------------------------------
  로더 계약: NewSession 때 top-level 실행 → first tick 때 전역 campaign_advisor().
  버튼/클릭(Step3/4)은 유지. 클릭 시:
    상태수집 → 파생지표 → 2축 스코어링(CA 시드) → 다양한 한국어 브리핑 → 파일.

  설계 근거(실측, docs/cai_seed_data.md):
    - 경제축: 예산 default = army 55 / construction 40. rogue80~tombking95 스펙트럼.
    - 지출규율: 순수입 ~90% 재투자, 흑자 5턴 / 적자 10턴 생존버퍼.
    - 전략축: defensive ↔ default ↔ aggressive ↔ opportunistic.
  범위: 읽기 전용. 화면 텍스트는 영어 툴팁만(한글 글리프 미보장) → 조언은 파일(UTF-8).
  이 두뇌의 "구조화 결과"는 Phase3에서 LLM에 넘겨 자연어화할 것.
=============================================================================]]

local BUTTON_ID       = "advisor_recommend_button"
local BUTTON_TEMPLATE = "ui/templates/round_medium_button"

-- 디버그 파일: ★개발·검증 중에는 true(프루프 파일로 계산 내역 전부 확인).
--   배포 직전 단계(F5)에서만 false로 내리면 유저 디스크에 파일 안 남김.
--   경로는 개발자(veria) 기준; 배포 시엔 off라 무관.
local DEBUG_FILE = true
local PROOF_PATH = "C:/Users/veria/tw3_advisor_proof.txt"

-- CA 실측 시드 상수
local SEED = {
	army_base = 55, cons_base = 40,   -- default 예산배분(%)
	reinvest  = 0.9,                  -- 순수입 재투자 비율
	buffer_target = 5,                -- 흑자시 목표 재정버퍼(턴)
}

-- out()으로 스크립트 로그 기록. DEBUG_FILE일 때만 파일도. 둘 다 pcall 보호.
local function proof(msg, append)
	pcall(function() out("[CAMPAIGN_ADVISOR] " .. msg) end)
	if DEBUG_FILE then
		pcall(function()
			if io and io.open then
				local f = io.open(PROOF_PATH, append and "a" or "w")
				if f then f:write(msg .. "\n"); f:close() end
			end
		end)
	end
end

proof("STEP5(2a) 파일 로드됨 (NewSession/top-level).", false)
-- 히스토리는 cm:set_saved_value(세이브 귀속)로 저장 → 파일 wipe 불필요.
--   새 캠페인=빈 값이라 캠페인 간 오염 자동 방지 + 세이브/로드 지속.

local g_done  = false
local g_click = 0

-- ── 유틸 ──────────────────────────────────────────────────────────────
local function num(x, d) if x == nil then return d or 0 else return x end end
local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi else return x end end
local function sev(s) if s >= 70 then return "높음" elseif s >= 45 then return "중간" else return "낮음" end end

-- 팩션 키 → 표시명(자주 보는 것만; 없으면 키 그대로). 파일 출력이라 한글 OK.
local FACTION_NAME = {
	wh_main_emp_empire = "제국(라이클란트)",
	wh_main_emp_empire_separatists = "제국 분리주의자",
	wh_dlc03_bst_beastmen = "비스트맨",
	wh_main_grn_greenskins = "그린스킨",
	wh_main_vmp_vampire_counts = "뱀파이어 카운트",
	wh_main_dwf_dwarfs = "드워프",
	wh_main_brt_bretonnia = "브레토니아",
}
-- 팩션 키 → 표시명. 우선순위: 큐레이션 테이블 → 게임 로컬라이즈(한글, factions_screen_name_) → 키.
-- 게임 locale가 한국어라 common.get_localised_string이 한글 팩션명을 돌려줌(바닐라 lib_campaign_ui:413 근거). 캐시.
local g_fname_cache = {}
local function fname(key)
	if key == nil then return "(알수없음)" end
	local c = g_fname_cache[key]
	if c then return c end
	local disp = FACTION_NAME[key]
	if not disp then
		pcall(function()
			local loc = common.get_localised_string("factions_screen_name_" .. key)
			if loc and loc ~= "" then disp = loc end
		end)
	end
	disp = disp or key
	g_fname_cache[key] = disp
	return disp
end

-- 팩션 키 리스트 → 앞 n개 표시명 문자열(", " 결합)
local function first_names(keys, n)
	local t = {}
	for i = 1, math.min(#keys, n or 2) do t[#t + 1] = fname(keys[i]) end
	return table.concat(t, ", ")
end

-- 진영 전략 프로필 조회 (subculture→culture→기본). 전역표는 za_faction_profiles.lua 에서 설정.
local function get_profile(S)
	local P
	pcall(function()
		if CA_FACTION_PROFILES then P = CA_FACTION_PROFILES[S.subculture] or CA_FACTION_PROFILES[S.culture] end
	end)
	if not P then pcall(function() P = CA_FACTION_DEFAULT end) end
	if not P then P = { race = "(일반)", identity = "", pr = {}, tips = {} } end
	return P
end

-- 팩션 리스트 → 키 집합(set) {key=true}
local function key_set(list_getter, cap)
	local set, cnt = {}, 0
	pcall(function()
		local l = list_getter(); local n = l:num_items()
		for i = 0, math.min(n, cap or 200) - 1 do set[l:item_at(i):name()] = true; cnt = cnt + 1 end
	end)
	return set, cnt
end

-- 실제 국경 인접: 내 지역들의 인접 지역 소유주 → 이웃 팩션 키 집합.
-- (adjacency 폭주 방지 위해 총 검사 횟수 상한.)
local function gather_neighbors(f, my_key)
	local nb = {}
	pcall(function()
		local regions = f:region_list(); local rn = regions:num_items()
		local checks = 0
		for i = 0, rn - 1 do
			if checks > 600 then break end
			local reg = regions:item_at(i)
			local adj = reg:adjacent_region_list(); local an = adj:num_items()
			for j = 0, an - 1 do
				checks = checks + 1
				local a = adj:item_at(j)
				local abandoned = false
				pcall(function() abandoned = a:is_abandoned() end)
				if not abandoned then
					local ok = nil
					pcall(function()
						local o = a:owning_faction()
						if o and not o:is_null_interface() then ok = o:name() end
					end)
					if ok and ok ~= my_key then nb[ok] = true end
				end
			end
		end
	end)
	return nb
end

-- 팩션 강도 근사 = 소유 영토 수 (없으면 nil). 이웃 강약 평가용.
local function faction_strength(key)
	local r = nil
	pcall(function()
		local ff = cm:get_faction(key, false)
		if ff and not ff:is_null_interface() then r = ff:region_list():num_items() end
	end)
	return r
end

-- ── 위협·방어 탐지 (모듈1) — 포위·접근 적군·무방비 정착지 ─────────────
-- API(바닐라 실측): region:garrison_residence():is_under_siege(),
--   mf:has_general()/is_armed_citizenry()/general_character()/strength(),
--   character:has_region()/region():name(). 캠페인 거리함수 없음 → 인접(adjacency)으로 근사.

-- 지역 키 → 표시명. 게임 로컬라이즈(한글, regions_onscreen_) 우선 → 실패 시 키 마지막 세그먼트(영문) 폴백.
-- 근거: 바닐라 다수가 "regions_onscreen_"..key 를 로컬 키로 사용. 캐시.
local g_region_cache = {}
local function region_disp(key)
	if type(key) ~= "string" then return "(지역?)" end
	local c = g_region_cache[key]
	if c then return c end
	local disp = nil
	pcall(function()
		local loc = common.get_localised_string("regions_onscreen_" .. key)
		if loc and loc ~= "" then disp = loc end
	end)
	if not disp then
		local tail = key:match("([^_]+)$") or key
		disp = tail:sub(1, 1):upper() .. tail:sub(2)
	end
	g_region_cache[key] = disp
	return disp
end

-- 속주 키 → 표시명. "provinces_onscreen_" 로컬 키는 스크립트 실측 없음(loc DB 추정) —
-- pcall+빈문자열 체크라 실패해도 무해, 성공하면 한글. 폴백=키 꼬리 정리.
local g_prov_cache = {}
local function province_disp(key)
	if type(key) ~= "string" then return "(속주?)" end
	local c = g_prov_cache[key]
	if c then return c end
	local disp = nil
	pcall(function()
		local loc = common.get_localised_string("provinces_onscreen_" .. key)
		if loc and loc ~= "" then disp = loc end
	end)
	if not disp then
		local tail = key:match("([^_]+)$") or key
		disp = tail:sub(1, 1):upper() .. tail:sub(2)
	end
	g_prov_cache[key] = disp
	return disp
end

-- 야전군이면 그 군대가 선 지역 키, 아니면 nil(수비대·무장시민 제외).
local function army_region_name(mf)
	local rn = nil
	pcall(function()
		if mf:has_general() and not mf:is_armed_citizenry() then
			local ch = mf:general_character()
			if ch and ch:has_region() and not ch:region():is_null_interface() then rn = ch:region():name() end
		end
	end)
	return rn
end

-- 위협 수집: 내 지역별 포위 여부 + 전쟁 팩션 야전군이 내 땅/인접에 있는가 + 아군 야전군 근접 여부.
-- 반환 T = { sieges={지역키...}, threatened={ {region, on_land, faction, defended}... }, my_field={지역키=true} }
local function gather_threats(f, war_set, border_enemies)
	local T = { sieges = {}, threatened = {}, targets = {}, my_field = {} }
	pcall(function()
		local mine, my_adj, adj_to_mine, tgt_seen = {}, {}, {}, {}
		local regions = f:region_list(); local rn = regions:num_items()
		local checks = 0
		for i = 0, rn - 1 do
			local reg = regions:item_at(i)
			local nm = reg:name()
			mine[nm] = true
			pcall(function()
				local gr = reg:garrison_residence()
				if gr and not gr:is_null_interface() and gr:is_under_siege() then T.sieges[#T.sieges + 1] = nm end
			end)
			local al = {}
			pcall(function()
				local adj = reg:adjacent_region_list(); local an = adj:num_items()
				for j = 0, an - 1 do
					if checks > 800 then break end
					checks = checks + 1
					local areg = adj:item_at(j)
					local anm = areg:name()
					al[#al + 1] = anm
					if not adj_to_mine[anm] then adj_to_mine[anm] = nm end
					-- 확장 표적(모듈3): 인접한 '전쟁 중 적' 소유 정착지
					if not mine[anm] and not tgt_seen[anm] then
						local ok = nil
						pcall(function()
							local of = areg:owning_faction()
							if of and not of:is_null_interface() then ok = of:name() end
						end)
						if ok and war_set[ok] then
							tgt_seen[anm] = true
							T.targets[#T.targets + 1] = { region = anm, owner = ok, my_border = nm }
						end
					end
				end
			end)
			my_adj[nm] = al
		end
		-- 내 야전군 위치(방어 가용성 판단용)
		pcall(function()
			local myf = f:military_force_list(); local mn = myf:num_items()
			for i = 0, math.min(mn, 40) - 1 do
				local r = army_region_name(myf:item_at(i))
				if r then T.my_field[r] = true end
			end
		end)
		local function friendly_near(target)
			if T.my_field[target] then return true end
			local a = my_adj[target]
			if a then for _, n in ipairs(a) do if T.my_field[n] then return true end end end
			return false
		end
		-- 적 야전군 → 내 땅/인접 위협 집계(지역별 1건). 국경 접한 적 우선 스캔(비결정적 순서로 놓치지 않게).
		local agg = {}
		local scan, seen = {}, {}
		if border_enemies then for _, k in ipairs(border_enemies) do if war_set[k] and not seen[k] then seen[k] = true; scan[#scan + 1] = k end end end
		for k in pairs(war_set) do if not seen[k] then seen[k] = true; scan[#scan + 1] = k end end
		for idx = 1, math.min(#scan, 12) do
			local ekey = scan[idx]
			pcall(function()
				local ef = cm:get_faction(ekey, false)
				if not ef or ef:is_null_interface() then return end
				local el = ef:military_force_list(); local en = el:num_items()
				for i = 0, math.min(en, 25) - 1 do
					local mf = el:item_at(i)
					local r = army_region_name(mf)
					if r then
						local target = mine[r] and r or adj_to_mine[r]
						if target then
							local a = agg[target]
							if not a then a = { region = target, on_land = false, faction = ekey }; agg[target] = a; T.threatened[#T.threatened + 1] = a end
							if mine[r] then a.on_land = true end
						end
					end
				end
			end)
		end
		for _, a in ipairs(T.threatened) do a.defended = friendly_near(a.region) end
		for _, t in ipairs(T.targets) do t.near = friendly_near(t.my_border) end
	end)
	return T
end

-- ── 외교 기회 조회 (모듈4) — 성사 가능한 화친/동맹 ────────────────────
-- API(바닐라 실측): cm:cai_evaluate_quick_deal_action(faction_obj, other_obj, option) → score, can_issue.
--   faction:military_allies_with(other)로 이미 동맹은 제외. 옵션은 diplomatic_option_*(peace/military_alliance).
local function eval_deal(f, other_key, option)
	local can = false
	pcall(function()
		local of = cm:get_faction(other_key, false)
		if of and not of:is_null_interface() then
			local _, ci = cm:cai_evaluate_quick_deal_action(f, of, option)
			if ci then can = true end
		end
	end)
	return can
end

local function gather_diplomacy(f, war_set, border_enemies, border_others)
	local D = { peace = {}, ally = {} }
	pcall(function()
		-- 화친 가능(전쟁 중): 국경 접한 적 우선, 최대 8
		local scan, seen = {}, {}
		if border_enemies then for _, k in ipairs(border_enemies) do if not seen[k] then seen[k] = true; scan[#scan + 1] = k end end end
		for k in pairs(war_set) do if not seen[k] then seen[k] = true; scan[#scan + 1] = k end end
		for idx = 1, math.min(#scan, 8) do
			if eval_deal(f, scan[idx], "diplomatic_option_peace") then D.peace[#D.peace + 1] = scan[idx] end
		end
		-- 동맹 가능(비적대 이웃): 이미 동맹 아닌 경우, 최대 8
		if border_others then
			for idx = 1, math.min(#border_others, 8) do
				local ok = border_others[idx]
				local already = false
				pcall(function()
					local of = cm:get_faction(ok, false)
					if of and not of:is_null_interface() and f:military_allies_with(of) then already = true end
				end)
				if not already and eval_deal(f, ok, "diplomatic_option_military_alliance") then D.ally[#D.ally + 1] = ok end
			end
		end
	end)
	return D
end

-- 타락 종류(④) — 속주 pooled_resource로 조회(키는 바닐라 실측 wh3_main_corruption_*). label=표시용.
local CORR_TYPES = {
	{ key = "wh3_main_corruption_chaos",    label = "카오스" },
	{ key = "wh3_main_corruption_khorne",   label = "코른" },
	{ key = "wh3_main_corruption_nurgle",   label = "너글" },
	{ key = "wh3_main_corruption_tzeentch", label = "젠취" },
	{ key = "wh3_main_corruption_slaanesh", label = "슬라네쉬" },
	{ key = "wh3_main_corruption_skaven",   label = "스케이븐" },
	{ key = "wh3_main_corruption_vampiric", label = "뱀파이어" },
}
-- 타락을 스스로 퍼뜨리는(신경 안 쓰는) subculture — 이들에겐 타락 경고 생략.
local CORR_IGNORE = {
	["wh3_main_sc_kho_khorne"] = true, ["wh3_main_sc_nur_nurgle"] = true, ["wh3_main_sc_tze_tzeentch"] = true,
	["wh3_main_sc_sla_slaanesh"] = true, ["wh3_main_sc_dae_daemons"] = true, ["wh_main_sc_chs_chaos"] = true,
	["wh_dlc08_sc_nor_norsca"] = true, ["wh_main_sc_vmp_vampire_counts"] = true, ["wh2_dlc11_sc_cst_vampire_coast"] = true,
	["wh2_main_sc_skv_skaven"] = true, ["wh_dlc03_sc_bst_beastmen"] = true, ["wh2_main_sc_def_dark_elves"] = true,
}

-- ── 속주 내부(④) — 공공질서 위기 + 적대 타락 감지 ────────────────────
-- API(바닐라 실측): region:public_order()(음수=불안, <=-50 반란 임박),
--   region:province():pooled_resource_manager():resource("wh3_main_corruption_*"):value().
local function gather_province_issues(f, subculture)
	local PV = { unrest = {} }   -- PV.corruption = {region,label,value} (내 땅 최악, >=50만)
	local skip_corr = subculture and CORR_IGNORE[subculture]
	pcall(function()
		local regions = f:region_list(); local rn = regions:num_items()
		local seen, corr_seen = {}, {}
		for i = 0, math.min(rn, 50) - 1 do
			local reg = regions:item_at(i)
			local pn = reg:name(); pcall(function() pn = reg:province_name() end)
			-- 공공질서
			local po = nil
			pcall(function() po = reg:public_order() end)
			if po and po <= -15 then
				local a = seen[pn]
				if not a then a = { region = reg:name(), po = po }; seen[pn] = a; PV.unrest[#PV.unrest + 1] = a
				elseif po < a.po then a.po = po; a.region = reg:name() end
			end
			-- 적대 타락(속주별 1회, 내 땅 전체 최악만; 타락 활용 종족은 스킵)
			if not skip_corr and not corr_seen[pn] then
				corr_seen[pn] = true
				pcall(function()
					local prm = reg:province():pooled_resource_manager()
					if prm then
						for _, ct in ipairs(CORR_TYPES) do
							local res = nil; pcall(function() res = prm:resource(ct.key) end)
							if res and not res:is_null_interface() then
								local v = nil; pcall(function() v = res:value() end)
								if v and v >= 50 and (not PV.corruption or v > PV.corruption.value) then
									PV.corruption = { region = reg:name(), label = ct.label, value = v }
								end
							end
						end
					end
				end)
			end
		end
	end)
	return PV
end

-- ── 스노우볼 감시(⑥) — 내가 만난 비동맹 세력 중 압도적으로 큰 팩션 ────
-- API(바닐라 실측): faction:factions_met(), faction:military_allies_with(obj), region_list():num_items().
-- 성장률 추적(히스토리) 없이 정적 '우세' 감지 — 런어웨이 AI 조기 경고.
local function gather_snowball(f, my_regions)
	local top = nil
	pcall(function()
		local met = f:factions_met(); local n = met:num_items()
		for i = 0, math.min(n, 60) - 1 do
			local of = met:item_at(i)
			if of and not of:is_null_interface() then
				local allied = false
				pcall(function() allied = f:military_allies_with(of) end)
				if not allied then
					local rc = 0
					pcall(function() rc = of:region_list():num_items() end)
					if (not top) or rc > top.regions then top = { key = of:name(), regions = rc } end
				end
			end
		end
	end)
	if not top then return nil end
	top.dominant = top.regions >= math.max(12, num(my_regions, 0) * 2)   -- 압도적이면 즉시 경고, 아니면 성장률 추적용
	return top
end

-- ── 상태 수집 (getter마다 개별 pcall) ────────────────────────────────
local function gather_state()
	local f = nil
	pcall(function() f = cm:get_local_faction(true) end)
	local function V(fn)  local ok, v = pcall(fn); if ok then return v end return nil end
	local function LN(fn) local ok, l = pcall(fn); if ok and l then return l:num_items() end return nil end
	local S = {}
	S.faction      = V(function() return f:name() end)
	S.subculture   = V(function() return f:subculture() end)
	S.culture      = V(function() return f:culture() end)
	S.leader_name  = V(function() return f:faction_leader():get_forename() end)
	S.leader_key   = V(function() return f:faction_leader():character_subtype_key() end)
	S.turn         = V(function() return cm:turn_number() end)
	S.treasury     = V(function() return f:treasury() end)
	S.income       = V(function() return f:income() end)
	S.net          = V(function() return f:net_income() end)
	S.losing       = V(function() return f:losing_money() end)
	S.regions      = LN(function() return f:region_list() end)
	S.provinces    = V(function() return f:num_provinces() end)
	S.armies       = LN(function() return f:military_force_list() end)  -- 수비대 포함
	S.generals     = V(function() return f:num_generals() end)          -- ≈ 필드군
	S.research_idle= V(function() return f:research_queue_idle() end)

	-- 전쟁 집합 + 국경 인접 → 즉각/먼 위협, 비적대 이웃 구분
	local war_set, war_count = key_set(function() return f:factions_at_war_with() end, 60)
	S.war_count = war_count
	S.war_set = war_set   -- 전략 2.0: 계획 엔진의 "아직 전쟁 중인가" 판정용
	local neighbors = gather_neighbors(f, S.faction)
	S.border_enemies, S.border_others = {}, {}
	for k in pairs(neighbors) do
		if war_set[k] then S.border_enemies[#S.border_enemies + 1] = k
		else S.border_others[#S.border_others + 1] = k end
	end
	S.immediate = #S.border_enemies                      -- 바로 옆 적
	S.distant   = math.max(0, war_count - S.immediate)   -- 국경 밖 전쟁(근사)
	-- 이웃 강약 평가: 비적대 이웃 중 최약(확장 표적), 국경 접한 적 중 최강(방어 경고)
	S.my_regions = num(S.regions, 0)
	S.weak_target, S.weak_target_r = nil, 9999
	for i = 1, math.min(#S.border_others, 12) do
		local r = faction_strength(S.border_others[i])
		if r and r < S.weak_target_r then S.weak_target_r = r; S.weak_target = S.border_others[i] end
	end
	S.strong_enemy, S.strong_enemy_r = nil, -1
	for i = 1, math.min(#S.border_enemies, 8) do
		local r = faction_strength(S.border_enemies[i])
		if r and r > S.strong_enemy_r then S.strong_enemy_r = r; S.strong_enemy = S.border_enemies[i] end
	end
	-- 표시용 이름(캡)
	S.war_names = {}
	for i = 1, math.min(#S.border_enemies, 3) do S.war_names[#S.war_names + 1] = fname(S.border_enemies[i]) end
	-- 위협·방어(모듈1): 포위·접근 적군·무방비 정착지
	S.threats = gather_threats(f, war_set, S.border_enemies)
	-- 외교 기회(모듈4): 성사 가능한 화친/동맹
	S.diplo = gather_diplomacy(f, war_set, S.border_enemies, S.border_others)
	-- 속주 내부(④): 공공질서 위기
	S.province = gather_province_issues(f, S.subculture)
	-- 스노우볼 감시(⑥): 압도적으로 큰 비동맹 세력
	S.snowball = gather_snowball(f, S.regions)
	return S
end

-- ── 파생지표 + 2축 스코어링 ──────────────────────────────────────────
local function analyze(S, prof)
	local regions  = num(S.regions, 0)
	local field    = num(S.generals, 0)
	local net      = num(S.net, 0)
	local treasury = num(S.treasury, 0)
	local income   = num(S.income, 0)
	local immediate= num(S.immediate, 0)   -- 바로 옆 적(국경 접촉)
	local distant  = num(S.distant, 0)     -- 국경 밖 전쟁
	local wars     = immediate + distant
	local others   = S.border_others and #S.border_others or 0  -- 비적대 이웃
	local deficit  = (S.losing == true) or (net < 0)
	local density  = (regions > 0) and (field / regions) or 0
	local buffer   = (income > 0) and (treasury / income) or 999

	local D = { density = density, buffer = buffer, immediate = immediate, distant = distant,
	            wars = wars, others = others, deficit = deficit, net = net }
	local cand = {}

	-- 군사 (모집/증원) — 즉각 위협을 먼 전쟁보다 크게 가중
	do
		local sc, rs = SEED.army_base, {}
		if immediate > 0 then sc = sc + immediate * 12; rs[#rs+1] = string.format("국경 접한 적 %d개(즉각 위협)", immediate) end
		if distant  > 0 then sc = sc + distant * 3;   rs[#rs+1] = string.format("국경 밖 전쟁 %d개", distant) end
		if regions > 0 and density < 1 then sc = sc + 20; rs[#rs+1] = string.format("영토 %d 대비 필드군 %d로 얇음", regions, field) end
		if deficit then sc = sc - 15; rs[#rs+1] = "적자라 모집 여력 제한" end
		if net > 0 then sc = sc + 8; rs[#rs+1] = string.format("순수입 +%d로 모집 여력", net) end
		cand[#cand+1] = { key = "military", label = "군사", score = clamp(sc, 0, 100), reasons = rs }
	end
	-- 경제 (건설/수입기반)
	do
		local sc, rs = SEED.cons_base, {}
		if deficit then sc = sc + 30; rs[#rs+1] = "적자 — 수입 기반 확충 시급" end
		if buffer < SEED.buffer_target then sc = sc + 15; rs[#rs+1] = string.format("재정 버퍼 %.1f턴(CA 권장 %d턴 미만)", buffer, SEED.buffer_target) end
		if buffer > 15 and not deficit then sc = sc + 10; rs[#rs+1] = string.format("금고 과다 적재(%.0f턴치) — 재투자 권장", buffer) end
		if immediate == 0 then sc = sc + 12; rs[#rs+1] = "국경 평온 — 성장 적기" end
		if immediate >= 2 then sc = sc - immediate * 4; rs[#rs+1] = "다전선 압박으로 건설 우선순위 하락" end
		cand[#cand+1] = { key = "economy", label = "경제", score = clamp(sc, 0, 100), reasons = rs }
	end
	-- 방어 (전선 방어) — 포위/위협 정착지 + 국경 접한 적 중심
	do
		local sc, rs = 0, {}
		local Tt = S.threats or {}
		local nsiege = Tt.sieges and #Tt.sieges or 0
		local nthreat, nundef = 0, 0
		if Tt.threatened then
			nthreat = #Tt.threatened
			for _, a in ipairs(Tt.threatened) do if not a.defended then nundef = nundef + 1 end end
		end
		if nsiege > 0 then sc = sc + 45 + nsiege * 10; rs[#rs+1] = string.format("정착지 %d곳 포위 중 — 즉시 구원", nsiege) end
		if nundef > 0 then sc = sc + 20 + nundef * 8; rs[#rs+1] = string.format("무방비 위협 %d곳(근처 아군 없음)", nundef) end
		if nthreat > nundef then sc = sc + 8; rs[#rs+1] = string.format("적 야전군이 %d개 지역 위협", nthreat) end
		local nunrest = (S.province and #S.province.unrest) or 0
		if nunrest > 0 then sc = sc + 8 + nunrest * 5; rs[#rs+1] = string.format("공공질서 위기 속주 %d곳(반란 위험)", nunrest) end
		if immediate > 0 then sc = sc + immediate * 15; rs[#rs+1] = string.format("국경 접한 적 %d개", immediate) end
		if regions > 0 and density < 0.5 then sc = sc + 25; rs[#rs+1] = "군대 밀도 매우 낮음 — 방어 취약" end
		if S.strong_enemy and num(S.strong_enemy_r, 0) > num(S.my_regions, 0) then
			sc = sc + 15
			rs[#rs+1] = string.format("%s(영토 %d)가 우리(%d)보다 커 방어 강화 필요", fname(S.strong_enemy), num(S.strong_enemy_r, 0), num(S.my_regions, 0))
		end
		if sc > 0 then cand[#cand+1] = { key = "defense", label = "방어", score = clamp(sc, 0, 100), reasons = rs } end
	end
	-- 확장 (선제/영토) — 국경 평온 + 흑자 + 비적대 이웃 존재. 약한 이웃을 표적으로 지목.
	if immediate == 0 and net > 0 and buffer >= SEED.buffer_target and others > 0 then
		local sc = 35 + ((density >= 1) and 15 or 0)
		local reason
		if S.weak_target then
			reason = string.format("국경 평온+흑자, 약한 이웃 %s(영토 %d)를 선제 확장 표적으로 검토", fname(S.weak_target), num(S.weak_target_r, 0))
		else
			reason = string.format("국경 평온+흑자, 인접 세력 %d개 — 확장/선제 검토", others)
		end
		cand[#cand+1] = { key = "expansion", label = "확장", score = clamp(sc, 0, 100), reasons = { reason } }
	end
	-- 확장(모듈3): 내 군대 인근 공격 가능 적 정착지 → 전시에도 공세 기회
	do
		local nt = 0
		if S.threats and S.threats.targets then for _, t in ipairs(S.threats.targets) do if t.near then nt = nt + 1 end end end
		if nt > 0 then
			local reason = string.format("내 군대 인근에 공격 가능한 적 정착지 %d곳", nt)
			local ex
			for i = 1, #cand do if cand[i].key == "expansion" then ex = cand[i]; break end end
			if ex then ex.score = clamp(ex.score + 18, 0, 100); ex.reasons[#ex.reasons + 1] = reason
			else cand[#cand + 1] = { key = "expansion", label = "확장", score = 45, reasons = { reason } } end
		end
	end
	-- 기술 (연구)
	if S.research_idle == true then
		cand[#cand+1] = { key = "tech", label = "기술", score = 45, reasons = { "연구가 미가동 상태 — 즉시 착수 권장" } }
	end
	-- 외교 (동맹/화친) — 다전선 + 성사 가능한 화친/동맹(모듈4)
	do
		local sc, rs = 0, {}
		if wars >= 2 then sc = sc + 30 + wars * 6; rs[#rs + 1] = string.format("%d개 세력과 동시 전쟁 — 전선 축소 검토", wars) end
		if S.diplo and #S.diplo.peace > 0 then sc = sc + 22; rs[#rs + 1] = string.format("화친 성사 가능: %s", first_names(S.diplo.peace, 2)) end
		if S.diplo and #S.diplo.ally > 0 then sc = sc + 12; rs[#rs + 1] = string.format("동맹 성사 가능: %s", first_names(S.diplo.ally, 2)) end
		if sc > 0 then cand[#cand + 1] = { key = "diplomacy", label = "외교", score = clamp(sc, 0, 100), reasons = rs } end
	end

	-- 진영 시그니처 액션(프로필 정의). 같은 차원 후보가 이미 있으면 흡수(라벨 승격+근거 추가+가중),
	-- 없으면 새 후보로 추가 → 같은 축이 top-3를 중복 점유하는 문제 방지(③).
	if prof and prof.sig and prof.sig.dim then
		local existing
		for i = 1, #cand do if cand[i].key == prof.sig.dim then existing = cand[i]; break end end
		if existing then
			existing.label = prof.sig.label or existing.label
			if prof.sig.note and prof.sig.note ~= "" then existing.reasons[#existing.reasons + 1] = prof.sig.note end
			existing.score = existing.score + 6   -- 시그니처 강조 보너스(재가중 전 base 스케일)
		else
			cand[#cand + 1] = { key = prof.sig.dim, label = prof.sig.label or "진영", score = 52, reasons = { prof.sig.note or "" } }
		end
	end
	-- 진영 프로필로 6차원 재가중 (상황 base 점수 × 진영 성향 가중치)
	for i = 1, #cand do
		local w = (prof and prof.pr and prof.pr[cand[i].key]) or 0.6
		cand[i].score = clamp(math.floor(cand[i].score * w + 0.5), 0, 100)
	end
	table.sort(cand, function(a, b) return a.score > b.score end)
	return D, cand
end

-- ── 종합 판단 한 줄 ──────────────────────────────────────────────────
local function overall(S, D)
	local p = {}
	if num(S.turn, 99) <= 10 then p[#p+1] = "초반 확장기" end
	if D.deficit then p[#p+1] = "적자 운영" elseif D.net > 0 then p[#p+1] = "흑자 운영" end
	if D.immediate >= 2 then p[#p+1] = "국경 다전선 압박"
	elseif D.immediate == 1 then p[#p+1] = "국경 교전"
	elseif D.wars > 0 then p[#p+1] = "원거리 전쟁만"
	else p[#p+1] = "국경 평온" end
	if D.density < 1 then p[#p+1] = "군대 얇음" end
	return table.concat(p, " · ")
end

-- ── 전략 국면 진단(②) — 기존 지표로 상위 archetype 한 줄 ─────────────
-- 관찰의 나열이 아니라 "지금 어떤 국면인가"라는 상위 판단을 우선순위대로 하나 고른다.
local function diagnose(S, D)
	local regions = num(S.regions, 0)
	local field   = num(S.generals, 0)
	local nsiege  = (S.threats and #S.threats.sieges) or 0
	local buffer  = D.buffer or 999
	if nsiege > 0 or D.immediate >= 3 then
		return { label = "궁지", note = "포위·다전선으로 수세에 몰렸습니다. 전선을 줄이고 핵심 영토 사수에 집중하세요" }
	end
	if regions >= 5 and field > 0 and (regions / field) >= 4 and D.immediate >= 2 then
		return { label = "과확장", note = "영토에 비해 군대가 얇고 다전선입니다. 확장을 멈추고 통합·방어를 우선하세요" }
	end
	if D.deficit and buffer < 4 then
		return { label = "재정 위기", note = "적자로 곧 자금이 바닥납니다. 군대 감축이나 수입 확충이 시급합니다" }
	end
	if D.immediate == 0 and D.net > 0 then
		if buffer > 12 then return { label = "성장 정체", note = "평온하나 금고만 쌓였습니다. 재투자·확장으로 우위를 굴리세요" } end
		return { label = "성장기", note = "평온+흑자, 우위를 확보할 적기입니다. 경제와 영토를 키우세요" }
	end
	if num(S.turn, 99) <= 10 then
		return { label = "초반 정착", note = "기반을 다지는 시기입니다. 인접 약체 흡수와 경제 기틀을 우선하세요" }
	end
	if D.wars > 0 then
		return { label = "소모전", note = "전쟁이 이어지나 전선은 관리되고 있습니다. 결정적 지점에 전력을 모으세요" }
	end
	return { label = "안정", note = "큰 위협은 없습니다. 다음 목표를 정해 주도적으로 움직이세요" }
end

-- ── 브리핑 조립(다양한 오프너 + 랭킹 조언) ──────────────────────────
local OPENERS = { "전략 브리핑", "현황 분석", "참모 보고", "정세 판단" }

local function build_briefing(S, D, cand, prof)
	g_click = g_click + 1
	local opener = OPENERS[(g_click - 1) % #OPENERS + 1]
	local buffer_str = (D.buffer >= 999) and "충분" or string.format("%.1f턴", D.buffer)
	local wars = (#S.war_names > 0) and table.concat(S.war_names, ", ") or "없음"

	local L = {}
	L[#L+1] = string.format("========== 📊 %s #%d ==========", opener, g_click)
	L[#L+1] = string.format("팩션 %s · %s턴", fname(S.faction), tostring(num(S.turn, "?")))
	L[#L+1] = string.format("재정 %s (수입 %s, 순 %s) · 영토 %s · 필드군 %s · 총군대 %s",
		tostring(num(S.treasury,"?")), tostring(num(S.income,"?")),
		(S.net == nil and "?" or ((S.net >= 0) and ("+"..S.net) or tostring(S.net))),
		tostring(num(S.regions,"?")), tostring(num(S.generals,"?")), tostring(num(S.armies,"?")))
	L[#L+1] = string.format("파생: 군대밀도 %.2f · 재정버퍼 %s · 국경적 %d(%s) · 원거리전 %d · 비적대이웃 %d",
		D.density, buffer_str, D.immediate, wars, D.distant, D.others)
	if S.trend then
		L[#L+1] = string.format("📈 추세(%d턴 전 대비): 재정 %+d · 영토 %+d · 수입 %+d",
			S.trend.dt, S.trend.treasury, S.trend.regions, S.trend.income)
	end
	L[#L+1] = "▶ 종합: " .. overall(S, D)
	do local dg = diagnose(S, D); if dg then L[#L+1] = "◆ 국면: " .. dg.label .. " — " .. dg.note end end
	if S.threats and (#S.threats.sieges > 0 or #S.threats.threatened > 0 or #S.threats.targets > 0) then
		local parts = {}
		if #S.threats.sieges > 0 then
			local ns = {}; for _, k in ipairs(S.threats.sieges) do ns[#ns+1] = region_disp(k) end
			parts[#parts+1] = "포위=" .. table.concat(ns, ",")
		end
		if #S.threats.threatened > 0 then
			local ts = {}; for _, a in ipairs(S.threats.threatened) do ts[#ts+1] = region_disp(a.region) .. (a.defended and "(방어됨)" or "(무방비)") end
			parts[#parts+1] = "위협=" .. table.concat(ts, ",")
		end
		if #S.threats.targets > 0 then
			local gs = {}; for _, t in ipairs(S.threats.targets) do gs[#gs+1] = region_disp(t.region) .. (t.near and "(근접)" or "") end
			parts[#parts+1] = "표적=" .. table.concat(gs, ",")
		end
		L[#L+1] = "⚔ 지도: " .. table.concat(parts, " · ")
	end
	if S.diplo and (#S.diplo.peace > 0 or #S.diplo.ally > 0) then
		local dp = {}
		if #S.diplo.peace > 0 then dp[#dp+1] = "화친가능=" .. first_names(S.diplo.peace, 3) end
		if #S.diplo.ally > 0 then dp[#dp+1] = "동맹가능=" .. first_names(S.diplo.ally, 3) end
		L[#L+1] = "🤝 외교: " .. table.concat(dp, " · ")
	end
	if S.province and #S.province.unrest > 0 then
		local us = {}; for _, u in ipairs(S.province.unrest) do us[#us+1] = region_disp(u.region) .. "(" .. u.po .. ")" end
		L[#L+1] = "🏛 공공질서: " .. table.concat(us, ", ")
	end
	if S.province and S.province.corruption then L[#L+1] = string.format("☣ 타락: %s %s %d%%", region_disp(S.province.corruption.region), S.province.corruption.label, math.floor(S.province.corruption.value)) end
	if S.snowball then
		local g = S.rival_growth
		local mark = (S.snowball.dominant and ",압도" or "") .. ((g and g.growth) and string.format(",%d턴%+d", g.dt, g.growth) or "")
		L[#L+1] = string.format("🌩 최강라이벌: %s(영토 %d%s)", fname(S.snowball.key), S.snowball.regions, mark)
	end
	if S.resource then L[#L+1] = string.format("⚙ 종족자원 %s: %d", S.resource.label, math.floor(S.resource.value)) end
	if S.strat then
		L[#L+1] = string.format("⚑ 전략상태: 국력%s · 속주%d · 군단%d · 위기[무장:%s 활성:%d] · 승리[%s/%s]",
			tostring(S.strat.my_rank or "?"), #(S.strat.provinces or {}), #(S.strat.armies or {}),
			(S.strat.endgame and S.strat.endgame.armed) and tostring(S.strat.endgame.armed.scenario) or "-",
			(S.strat.endgame and #(S.strat.endgame.active or {})) or 0,
			tostring((S.strat.victory and S.strat.victory.vtype) or "-"), tostring((S.strat.victory and S.strat.victory.total) or "-"))
	end
	if S.plan and S.plan.steps and #S.plan.steps > 0 then
		local ps = {}
		for _, s in ipairs(S.plan.steps) do
			ps[#ps+1] = string.format("%s:%s(%s/%s)", s.kind, tostring(s.key), tostring(s.last), tostring(s.base))
		end
		L[#L+1] = "⚑ 계획: " .. table.concat(ps, " → ")
	end
	if prof and prof.race and prof.race ~= "(일반)" then
		L[#L+1] = string.format("🏰 %s — %s", prof.race, tostring(prof.identity or ""))
	end
	if S.leader_key then
		local lord = prof and prof.lords and prof.lords[S.leader_key]
		if lord then
			L[#L+1] = "👑 군주: " .. tostring(lord.name or S.leader_key)
			if lord.note then L[#L+1] = "   ↳ " .. tostring(lord.note) end
		else
			L[#L+1] = "👑 군주(미등록 키): " .. tostring(S.leader_key)   -- 실제 키 수집용
		end
	end
	if prof and prof.tips and #prof.tips > 0 then
		L[#L+1] = "💡 진영 팁: " .. prof.tips[(g_click - 1) % #prof.tips + 1]
	end
	L[#L+1] = "── 권장 행동 (점수 순) ──"
	local shown = math.min(#cand, 3)
	for i = 1, shown do
		local c = cand[i]
		L[#L+1] = string.format("%d. [%s·%s] 점수 %d", i, c.label, sev(c.score), c.score)
		L[#L+1] = "   근거: " .. ((#c.reasons > 0) and table.concat(c.reasons, "; ") or "(기본 가중치)")
	end
	if shown == 0 then L[#L+1] = "(권장 후보 없음 — 상태 조회 실패 가능)" end
	L[#L+1] = "======================================"
	return table.concat(L, "\n")
end

-- (build_tooltip 제거 — 현재 툴팁은 build_prose 산문을 사용. 데드코드 정리.)

-- ── 자연어 산문 생성 (v9c) — 문구 풀 회전으로 다양화 ──
local PROSE_OPEN = { "정세를 보면", "현 상황을 정리하면", "참모의 판단으로는", "전황을 짚어보면", "보고드리자면", "냉정히 보면", "지금 국면은" }
local PROSE_CONN = { "한편", "또한", "동시에", "이와 함께", "아울러", "그다음으로" }
local function urgency(s)
	if s >= 70 then return "가장 시급합니다" elseif s >= 45 then return "중요합니다" else return "고려할 만합니다" end
end

-- 한국어 조사 자동 선택: 마지막 한글 음절의 받침 유무로 결정 (Lua 5.1 산술만 사용).
local function has_batchim(word)
	local n = #word
	if n < 3 then return nil end
	local b1, b2, b3 = word:byte(n - 2), word:byte(n - 1), word:byte(n)
	if not (b1 and b2 and b3) then return nil end
	if b1 < 0xE0 or b1 > 0xEF then return nil end                 -- 3바이트 UTF-8(한글) 아님
	local cp = (b1 % 0x10) * 4096 + (b2 % 0x40) * 64 + (b3 % 0x40)
	if cp < 0xAC00 or cp > 0xD7A3 then return nil end             -- 한글 음절 범위 아님
	return ((cp - 0xAC00) % 28) ~= 0                              -- 받침 있으면 true
end
-- 조사 선택: 받침 있으면 withB, 없으면(또는 비한글) without.
-- ※ WH3 Lua의 string.sub은 문자 단위라 pair 분리가 깨짐 → 조사를 개별 인자로 받는다(실측 버그 회피).
local function josa(word, withB, without)
	if has_batchim(word) == true then return withB else return without end
end

local plan_prose_lines   -- 전방 선언(전략 2.0 — 실제 정의는 아래 계획 엔진 섹션; upvalue 바인딩)

local function build_prose(S, D, cand, prof)
	local race = (prof and prof.race and prof.race ~= "(일반)") and prof.race or fname(S.faction)
	local rot = function(t) return t[(g_click - 1) % #t + 1] end
	local P = {}
	-- 전략 계획(2.0) — 최상단: "앞으로 무엇을"의 직답
	for _, l in ipairs(plan_prose_lines(S)) do P[#P+1] = l end
	-- 전략 국면(②) — 상위 판단
	do
		local dg = diagnose(S, D)
		if dg then P[#P+1] = string.format("【국면 · %s】 %s.", dg.label, dg.note) end
	end
	-- 정세 도입
	local eco = D.deficit and "재정은 적자라 주의가 필요하고"
		or (D.net > 0 and string.format("재정은 순 +%d로 흑자이며", num(S.net, 0)) or "재정은 대체로 균형이고")
	local threat
	if D.immediate >= 2 then threat = "국경에서 여러 세력의 압박을 받고 있습니다"
	elseif D.immediate == 1 then threat = string.format("국경에서 %s의 압박을 받고 있습니다", tostring(S.war_names[1] or "적"))
	elseif D.wars > 0 then threat = "전쟁 중이나 국경은 아직 평온합니다"
	else threat = "국경은 평온합니다" end
	P[#P+1] = string.format("%s, %s%s %s턴 현재 %s, %s.", rot(PROSE_OPEN), race, josa(race, "은", "는"), tostring(num(S.turn, "?")), eco, threat)
	-- 긴급 위협(모듈1) — 포위/무방비 우선 (가장 시급하므로 앞에 배치)
	if S.threats then
		local Tt = S.threats
		if Tt.sieges and #Tt.sieges > 0 then
			local ns = {}
			for _, k in ipairs(Tt.sieges) do ns[#ns + 1] = region_disp(k) end
			P[#P+1] = string.format("긴급 — 포위된 정착지: %s. 구원군을 급파하거나 농성으로 버티세요.", table.concat(ns, ", "))
		end
		local sset = {}
		if Tt.sieges then for _, k in ipairs(Tt.sieges) do sset[k] = true end end
		local undef, defo = {}, {}
		if Tt.threatened then
			for _, a in ipairs(Tt.threatened) do
				if not sset[a.region] then
					if a.defended then defo[#defo + 1] = a else undef[#undef + 1] = a end
				end
			end
		end
		if #undef > 0 then
			P[#P+1] = string.format("위협 — %s 인근에 %s 야전군이 있는데 근처 아군이 없습니다. 회군하거나 증원하세요.", region_disp(undef[1].region), fname(undef[1].faction))
		elseif #defo > 0 then
			P[#P+1] = string.format("위협 — %s 인근에 %s 야전군이 있으나 아군이 대응 가능한 위치입니다. 요격을 검토하세요.", region_disp(defo[1].region), fname(defo[1].faction))
		end
	end
	-- 스노우볼 경계(⑥) — 압도적이거나 급성장 중인 AI
	if S.snowball then
		local g = S.rival_growth
		local fastgrow = g and g.dt >= 2 and g.growth >= 3
		if S.snowball.dominant then
			local extra = fastgrow and string.format(" 게다가 최근 %d턴간 영토 +%d로 급성장 중입니다.", g.dt, g.growth) or ""
			P[#P+1] = string.format("경계 — %s가 압도적으로 커졌습니다(영토 %d).%s 방치하면 손쓸 수 없습니다. 견제하거나 대항 동맹을 규합하세요.", fname(S.snowball.key), S.snowball.regions, extra)
		elseif fastgrow then
			P[#P+1] = string.format("주시 — %s가 최근 %d턴간 영토 +%d로 급성장 중입니다(현재 %d). 커지기 전에 견제를 고려하세요.", fname(S.snowball.key), g.dt, g.growth, S.snowball.regions)
		end
	end
	-- 추세 한마디
	if S.trend then
		local tp = {}
		if S.trend.regions > 0 then tp[#tp+1] = "영토가 늘고" elseif S.trend.regions < 0 then tp[#tp+1] = "영토가 줄고" end
		if S.trend.income > 0 then tp[#tp+1] = "수입이 오르는 추세입니다"
		elseif S.trend.income < 0 then tp[#tp+1] = "수입이 꺾이는 추세입니다"
		else tp[#tp+1] = "수입은 정체 상태입니다" end
		if #tp > 0 then P[#P+1] = string.format("최근 %d턴 사이 %s.", S.trend.dt, table.concat(tp, ", ")) end
	end
	-- 최우선 조언 (근거 없으면 대시 생략)
	if cand[1] then
		local r1 = cand[1].reasons[1]
		if r1 and r1 ~= "" then
			r1 = (tostring(r1):gsub(" — ", ", "))   -- 템플릿의 —와 근거 안의 — 중복(이중대시) 방지
			P[#P+1] = string.format("무엇보다 %s%s %s — %s.", cand[1].label, josa(cand[1].label, "이", "가"), urgency(cand[1].score), r1)
		else
			P[#P+1] = string.format("무엇보다 %s%s %s.", cand[1].label, josa(cand[1].label, "이", "가"), urgency(cand[1].score))
		end
	end
	-- 차선 조언 (근거 없으면 괄호 생략)
	if cand[2] then
		local r2 = cand[2].reasons[1]
		if r2 and r2 ~= "" then
			P[#P+1] = string.format("%s %s도 챙기세요(%s).", rot(PROSE_CONN), cand[2].label, tostring(r2))
		else
			P[#P+1] = string.format("%s %s도 챙기세요.", rot(PROSE_CONN), cand[2].label)
		end
	end
	-- 확장 기회(모듈3) — 내 군대 인근 공격 가능 적 정착지
	if S.threats and S.threats.targets then
		local nt
		for _, t in ipairs(S.threats.targets) do if t.near then nt = t; break end end
		if nt then
			P[#P+1] = string.format("확장 기회 — 내 군대 인근의 공격 가능 정착지: %s(%s). 여력이 되면 공략을 검토하세요.", region_disp(nt.region), fname(nt.owner))
		end
	end
	-- 외교 기회(모듈4) — 성사 가능한 화친/동맹. 계획의 '제거 표적'과 모순되지 않게 분리(일관성).
	if S.diplo then
		if #S.diplo.peace > 0 then
			local elim_key = nil
			if S.plan then for _, st in ipairs(S.plan.steps or {}) do if st.kind == "elim" then elim_key = st.key; break end end end
			local show = {}
			for _, k in ipairs(S.diplo.peace) do if k ~= elim_key then show[#show + 1] = k end end
			if #show > 0 then
				P[#P+1] = string.format("외교 — 화친이 성사 가능한 상대: %s. 전선을 줄이려면 제안하세요.", first_names(show, 2))
			elseif elim_key then
				P[#P+1] = string.format("외교 — %s와의 화친도 성사 가능하나, 계획상 제거가 우선입니다. 전황이 급하면 화친으로 전선을 줄이는 선택도 유효합니다.", fname(elim_key))
			end
		end
		if #S.diplo.ally > 0 then
			P[#P+1] = string.format("외교 — 군사동맹이 가능한 상대: %s. 제안을 검토하세요.", first_names(S.diplo.ally, 2))
		end
	end
	-- 유휴 자원(모듈2) — 연구 미지정
	if S.research_idle == true then
		P[#P+1] = "연구가 지정되지 않았습니다. 기술을 골라 착수하세요."
	end
	-- 속주 내부(④) — 공공질서 위기(최악 속주)
	if S.province and #S.province.unrest > 0 then
		local worst = S.province.unrest[1]
		for _, u in ipairs(S.province.unrest) do if u.po < worst.po then worst = u end end
		if worst.po <= -50 then
			P[#P+1] = string.format("반란 위험 — %s의 공공질서가 %d로 붕괴 직전입니다. 주둔군 강화나 억압으로 진정시키세요.", region_disp(worst.region), worst.po)
		else
			P[#P+1] = string.format("내정 주의 — %s의 공공질서가 %d로 낮습니다. 방치하면 반란으로 이어집니다.", region_disp(worst.region), worst.po)
		end
	end
	-- 적대 타락(④) — 타락 활용 종족은 gather 단계에서 이미 스킵됨
	if S.province and S.province.corruption then
		local c = S.province.corruption
		P[#P+1] = string.format("타락 주의 — %s에 %s 타락이 %d%%입니다. 통제·수입에 악영향이니 정화를 고려하세요.", region_disp(c.region), c.label, math.floor(c.value))
	end
	-- 종족 메커니즘(①) — 팩션 고유 자원(현재 값 + 종족별 프레이밍/긴급)
	if S.resource then
		P[#P+1] = string.format("%s %d — %s.", S.resource.label, math.floor(S.resource.value), S.resource.note)
	end
	-- 진영 특색 (팁 우선; 시그니처는 이미 후보로 등장할 수 있어 중복 회피. 오프셋으로 다른 팁 선택)
	if prof and prof.tips and #prof.tips > 0 then
		P[#P+1] = string.format("%s답게, %s.", race, tostring(prof.tips[g_click % #prof.tips + 1]))
	elseif prof and prof.sig and prof.sig.note then
		P[#P+1] = string.format("%s답게, %s.", race, prof.sig.note)
	end
	-- 군주 한마디
	if S.leader_key and prof and prof.lords and prof.lords[S.leader_key] then
		local lord = prof.lords[S.leader_key]
		P[#P+1] = string.format("%s: %s.", tostring(lord.name or "군주"), tostring(lord.note or ""))
	end
	return table.concat(P, "\n")   -- 문장별 줄바꿈(툴팁 표시 안정)
end

-- ── 턴별 추세 (세이브값 스냅샷 비교) ─────────────────────────────────
-- cm:set_saved_value("advisor_history", 문자열)에 저장(세이브 귀속 → 로드 지속, 캠페인 간 격리).
-- 각 줄: faction|turn|treasury|regions|armies|income|rival_key|rival_regions (8필드).
local function read_history()
	local list = {}
	pcall(function()
		local raw = cm:get_saved_value("advisor_history")
		if type(raw) ~= "string" then return end
		for line in raw:gmatch("[^\n]+") do
			local fac, t, tr, rg, ar, inc, rk, rr = line:match("([^|]*)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|([^|]*)|(%-?%d+)")
			if fac then
				list[#list + 1] = { faction = fac, turn = tonumber(t), treasury = tonumber(tr),
					regions = tonumber(rg), armies = tonumber(ar), income = tonumber(inc),
					rival_key = (rk ~= "" and rk ~= "-") and rk or nil, rival_regions = tonumber(rr) }
			end
		end
	end)
	return list
end

-- 같은 팩션, 현재보다 이전 턴 중 최신 스냅샷과 비교 → 델타. 없으면 nil.
local function compute_trend(S, hist)
	local cur = num(S.turn, 0)
	local prev = nil
	for _, h in ipairs(hist) do
		if h.faction == S.faction and h.turn and h.turn < cur then
			if (not prev) or (h.turn > prev.turn) then prev = h end
		end
	end
	if not prev then return nil end
	return { dt = cur - prev.turn,
		treasury = num(S.treasury, 0) - (prev.treasury or 0),
		regions  = num(S.regions, 0)  - (prev.regions or 0),
		income   = num(S.income, 0)   - (prev.income or 0) }
end

-- 최강 라이벌 성장률(⑥) — 히스토리에서 같은 라이벌의 가장 이른 기록 vs 현재 크기.
local function compute_rival_growth(S, hist)
	if not S.snowball then return nil end
	local key = S.snowball.key
	local earliest = nil
	for _, h in ipairs(hist) do
		if h.rival_key == key and h.rival_regions and h.turn then
			if (not earliest) or h.turn < earliest.turn then earliest = h end
		end
	end
	if not earliest then return nil end
	local dt = num(S.turn, 0) - earliest.turn
	if dt <= 0 then return nil end
	return { dt = dt, growth = num(S.snowball.regions, 0) - num(earliest.rival_regions, 0) }
end

-- 현재 턴 스냅샷 기록(같은 팩션·턴 갱신, 최근 12줄 유지).
local function record_snapshot(S, hist)
	pcall(function()
		if not S.faction then return end
		local kept = {}
		for _, h in ipairs(hist) do
			if not (h.faction == S.faction and h.turn == num(S.turn, 0)) then kept[#kept + 1] = h end
		end
		kept[#kept + 1] = { faction = S.faction, turn = num(S.turn, 0), treasury = num(S.treasury, 0),
			regions = num(S.regions, 0), armies = num(S.generals, 0), income = num(S.income, 0),
			rival_key = (S.snowball and S.snowball.key) or "-", rival_regions = (S.snowball and S.snowball.regions) or 0 }
		while #kept > 12 do table.remove(kept, 1) end
		local lines = {}
		for _, h in ipairs(kept) do
			lines[#lines + 1] = string.format("%s|%d|%d|%d|%d|%d|%s|%d", tostring(h.faction), h.turn or 0,
				h.treasury or 0, h.regions or 0, h.armies or 0, h.income or 0,
				tostring(h.rival_key or "-"), h.rival_regions or 0)
		end
		cm:set_saved_value("advisor_history", table.concat(lines, "\n"))
	end)
end

--[[═════════════════════════════════════════════════════════════════════
  전략 2.0 (v29) — 다턴 계획 엔진: "신호 나열"이 아니라 "지속되는 계획"
  ------------------------------------------------------------------------
  근거 API 전부 바닐라 실측(docs/strategic_api_catalog.md):
    국력순위 world:faction_strength_rank / 속주 num_regions_controlled_in_
    province_by_faction→(보유,전체) / 부대 unit_class·percentage_proportion_
    of_full_strength / 엔드게임 get_saved_value("endgame_scenario_data") /
    승리조건 victory_objectives_ie 전역.
  계획은 cm:set_saved_value("advisor_plan")로 세이브에 지속 → 매 클릭
  진행도 추적(시작 N → 현재 M, 순항/정체/역전) 후 자가 갱신.
═══════════════════════════════════════════════════════════════════════]]

-- 엔드게임 시나리오 키 → 표시명(로컬라이즈 키 미확보 → 키 정리 폴백)
local function endgame_disp(name)
	return (tostring(name):gsub("^endgame_", ""):gsub("_", " "))
end

-- ── 전략 상태 수집(API 경계, 전부 pcall) ─────────────────────────────
-- ST = { my_rank, provinces={{key,owned,total,miss_region,miss_owner}..},
--        enemy={[fkey]={regions,rank}}, armies={{name,units,art,avg}..},
--        endgame={armed={scenario,turn}|nil, active={이름..}}, victory={vtype,total}|nil }
local function collect_strategic(S)
	local ST = { provinces = {}, enemy = {}, armies = {}, endgame = { active = {} } }
	pcall(function()
		local f = cm:get_local_faction(true)
		if not f then return end
		pcall(function() ST.my_rank = cm:model():world():faction_strength_rank(f) end)
		-- 속주 완성 현황(내 지역 기준 속주 dedupe)
		pcall(function()
			local regions = f:region_list(); local rn = regions:num_items()
			local seen = {}
			for i = 0, math.min(rn, 40) - 1 do
				local reg = regions:item_at(i)
				local pn = nil; pcall(function() pn = reg:province_name() end)
				if pn and not seen[pn] then
					seen[pn] = true
					pcall(function()
						local prov = reg:province()
						local owned, total = cm:num_regions_controlled_in_province_by_faction(prov, f)
						local e = { key = pn, owned = owned, total = total }
						if S.faction and owned and total and owned < total then
							pcall(function()   -- 미보유 지역 1곳(표시용)
								local pl = prov:regions(); local pn2 = pl:num_items()
								for j = 0, pn2 - 1 do
									local r2 = pl:item_at(j)
									local of = r2:owning_faction()
									local oname = (of and not of:is_null_interface()) and of:name() or nil
									if oname ~= S.faction then
										e.miss_region = r2:name(); e.miss_owner = oname
										break
									end
								end
							end)
						end
						if owned and total then ST.provinces[#ST.provinces + 1] = e end
					end)
				end
			end
		end)
		-- 국경 전쟁적 상세(잔여 영토·국력순위) — 제거 표적 랭킹용
		for i = 1, math.min(#(S.border_enemies or {}), 8) do
			local k = S.border_enemies[i]
			if k and not ST.enemy[k] then
				pcall(function()
					local ef = cm:get_faction(k, false)
					if ef and not ef:is_null_interface() then
						local e = { regions = ef:region_list():num_items() }
						pcall(function() e.rank = cm:model():world():faction_strength_rank(ef) end)
						ST.enemy[k] = e
					end
				end)
			end
		end
		-- 군단 점검(야전군: 유닛수·야포(art_fld)·평균 충원율)
		pcall(function()
			local ml = f:military_force_list(); local mn = ml:num_items()
			for i = 0, math.min(mn, 12) - 1 do
				local mf = ml:item_at(i)
				local okmf = false
				pcall(function() okmf = mf:has_general() and not mf:is_armed_citizenry() end)
				if okmf then
					local a = { units = 0, art = 0 }
					pcall(function()
						local ul = mf:unit_list(); local un = ul:num_items()
						a.units = un
						local sum, cnt = 0, 0
						for j = 0, math.min(un, 25) - 1 do
							local u = ul:item_at(j)
							pcall(function() if u:unit_class() == "art_fld" then a.art = a.art + 1 end end)
							pcall(function()
								local p = u:percentage_proportion_of_full_strength()
								if p then sum = sum + p; cnt = cnt + 1 end
							end)
						end
						if cnt > 0 then a.avg = math.floor(sum / cnt + 0.5) end
					end)
					pcall(function()
						local loc = common.get_localised_string(mf:general_character():get_forename())
						if loc and loc ~= "" then a.name = loc end
					end)
					ST.armies[#ST.armies + 1] = a
				end
			end
		end)
		-- 엔드게임: 무장(예고)된 위기 + 이미 발동한 위기
		pcall(function()
			local sd = cm:get_saved_value("endgame_scenario_data")
			if type(sd) == "table" and sd.scenario then
				ST.endgame.armed = { scenario = tostring(sd.scenario), turn = tonumber(sd.turn) }
			end
		end)
		pcall(function()
			if type(endgame) == "table" and type(endgame.scenarios) == "table" then
				for _, name in ipairs(endgame.scenarios) do
					if cm:get_saved_value("endgame_" .. tostring(name) .. "_saved_data") then
						ST.endgame.active[#ST.endgame.active + 1] = tostring(name)
					end
				end
			end
		end)
		-- 승리조건(장기): 팩션 오버라이드 → subculture 오버라이드(실측 :334) → alignment 기본.
		-- 전 objectives 스캔: DESTROY_FACTION 대상("faction X") / "total N" / "province X" 개수.
		pcall(function()
			local vo = victory_objectives_ie
			if type(vo) ~= "table" then return end
			local objs = nil
			pcall(function()
				local fo = vo.factions and vo.factions[S.faction]
				if fo and fo.objectives then objs = fo.objectives end
			end)
			if not objs then pcall(function()
				local so = vo.subcultures[S.subculture]
				if so and so.objectives then objs = so.objectives end
			end) end
			if not objs then
				local align = nil
				pcall(function() align = vo.subcultures[S.subculture].alignment end)
				if align then pcall(function() objs = vo.alignments[align]["wh_main_long_victory"].objectives end) end
			end
			if type(objs) ~= "table" or not objs[1] then return end
			local V = { vtype = tostring(objs[1].type or "?") }
			for oi = 1, math.min(#objs, 4) do
				local o = objs[oi]
				for _, c in ipairs(o.conditions or {}) do
					local cs = tostring(c)
					local t = cs:match("^total%s+(%d+)$")
					if t and not V.total then V.total = tonumber(t) end
					local fk = cs:match("^faction%s+(%S+)$")
					if fk and tostring(o.type) == "DESTROY_FACTION" then
						V.targets = V.targets or {}
						if #V.targets < 4 then V.targets[#V.targets + 1] = fk end
					end
					if cs:match("^province%s+%S+") then V.prov_need = (V.prov_need or 0) + 1 end
				end
			end
			ST.victory = V
		end)
	end)
	return ST
end

-- ── 계획 직렬화(세이브값) — 줄당 kind|key|base|last|created|status ────
local function plan_serialize(plan)
	local L = {}
	for _, s in ipairs((plan and plan.steps) or {}) do
		L[#L + 1] = string.format("%s|%s|%d|%d|%d|%s",
			s.kind, s.key or "-", s.base or 0, s.last or 0, s.created or 0, s.status or "active")
	end
	return table.concat(L, "\n")
end
local function plan_deserialize(raw)
	local plan = { steps = {} }
	if type(raw) ~= "string" then return plan end
	for line in raw:gmatch("[^\n]+") do
		local kind, key, base, last, created, status = line:match("([^|]+)|([^|]*)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%a+)")
		if kind then
			plan.steps[#plan.steps + 1] = { kind = kind, key = (key ~= "-" and key or nil),
				base = tonumber(base), last = tonumber(last), created = tonumber(created), status = status }
		end
	end
	return plan
end

-- ── 계획 생성(순수) — ①제거 표적 ②속주 완성 ③대비/자세, 최대 3단계 ──
local function plan_generate(S, dglabel)
	local steps, ST = {}, S.strat or {}
	-- ① 군사: 국경 전쟁적 중 잔여 영토 최소(가장 빨리 끝낼 전선)
	local best
	for i = 1, #(S.border_enemies or {}) do
		local k = S.border_enemies[i]
		local e = ST.enemy and ST.enemy[k]
		if e and e.regions and e.regions > 0 then
			if not best or e.regions < best.regions then best = { key = k, regions = e.regions } end
		end
	end
	if best then
		steps[#steps + 1] = { kind = "elim", key = best.key, base = best.regions, last = best.regions, created = num(S.turn, 0) }
	end
	-- ② 내정: 미완 속주 중 남은 칸(gap) 최소 → 완성 임박 우선(CA 자체 넛지와 동일 설계)
	local bp
	for _, p in ipairs(ST.provinces or {}) do
		if p.owned and p.total and p.owned < p.total then
			local gap = p.total - p.owned
			if not bp or gap < bp.gap or (gap == bp.gap and p.owned > bp.owned) then
				bp = { key = p.key, gap = gap, owned = p.owned, total = p.total }
			end
		end
	end
	if bp then
		steps[#steps + 1] = { kind = "prov", key = bp.key, base = bp.total, last = bp.owned, created = num(S.turn, 0) }
	end
	-- ③ 대비/자세
	if ST.endgame and ST.endgame.armed then
		steps[#steps + 1] = { kind = "prep", key = ST.endgame.armed.scenario, base = ST.endgame.armed.turn or 0, last = 0, created = num(S.turn, 0) }
	elseif dglabel == "과확장" then
		steps[#steps + 1] = { kind = "posture", key = "consolidate", base = 0, last = 0, created = num(S.turn, 0) }
	elseif #steps == 0 then
		steps[#steps + 1] = { kind = "posture", key = (S.weak_target and "expand" or "tech"), base = 0, last = 0, created = num(S.turn, 0) }
	end
	return { steps = steps }
end

-- ── 계획 갱신(순수) — 완료 감지 후 재생성 + 기존 단계의 기준선 승계 ──
local function plan_revise(S, dglabel, old)
	local events, ST = {}, S.strat or {}
	for _, s in ipairs((old and old.steps) or {}) do
		if s.kind == "elim" and s.key then
			local e = ST.enemy and ST.enemy[s.key]
			local ended = (e and e.regions and e.regions <= 0)
				or (type(S.war_set) == "table" and not S.war_set[s.key])
			if ended then events[#events + 1] = string.format("계획 달성 — %s 전선 종료.", fname(s.key)) end
		elseif s.kind == "prov" and s.key then
			for _, p in ipairs(ST.provinces or {}) do
				if p.key == s.key and p.owned and p.total and p.owned >= p.total then
					events[#events + 1] = string.format("계획 달성 — %s 속주 완성!", province_disp(s.key))
					break
				end
			end
		end
	end
	local np = plan_generate(S, dglabel)
	for _, ns in ipairs(np.steps) do
		for _, os in ipairs((old and old.steps) or {}) do
			if os.kind == ns.kind and os.key == ns.key then
				ns.created = os.created or ns.created
				ns.prev = os.last                       -- 지난 클릭 값(추세용)
				if ns.kind == "elim" and os.base and os.base > 0 then ns.base = os.base end  -- '시작 N' 유지
			end
		end
	end
	return np, events
end

-- ── 계획 산문(순수) — 【전략 계획】 블록 (전방 선언된 local에 할당) ──
function plan_prose_lines(S)
	local plan, ST = S.plan, S.strat
	local L = {}
	for _, ev in ipairs(S.plan_events or {}) do L[#L + 1] = "✦ " .. ev end
	if not plan or #(plan.steps or {}) == 0 then return L end
	local h = {}
	if ST and ST.my_rank then h[#h + 1] = string.format("국력 %d위", ST.my_rank) end
	if ST and ST.victory then
		local V = ST.victory
		if V.targets and #V.targets > 0 then
			local extra = (#V.targets > 2) and string.format(" 외 %d", #V.targets - 2) or ""
			h[#h + 1] = string.format("장기 승리: %s%s 격멸", first_names(V.targets, 2), extra)
		elseif V.total and V.vtype == "OCCUPY_LOOT_RAZE_OR_SACK_X_SETTLEMENTS" then
			h[#h + 1] = string.format("장기 승리: 정착지 %d곳 점령/파괴(현재 %s)", V.total, tostring(num(S.regions, "?")))
		elseif V.total then
			h[#h + 1] = string.format("장기 승리: 목표 규모 %d", V.total)
		elseif V.prov_need then
			h[#h + 1] = string.format("장기 승리: 지정 속주 %d곳 장악", V.prov_need)
		end
	end
	L[#L + 1] = "【전략 계획】" .. (#h > 0 and (" " .. table.concat(h, " · ")) or "")
	local NUMS = { "①", "②", "③" }
	for i = 1, math.min(#plan.steps, 3) do
		local s, line = plan.steps[i], nil
		if s.kind == "elim" then
			local trend = ""
			if s.prev and s.last then
				if s.last < s.prev then trend = " — 순항"
				elseif s.last > s.prev then trend = " — 역전(적이 성장)"
				elseif s.created and num(S.turn, 0) > s.created then trend = " — 정체" end
			end
			line = string.format("%s %s 제거 — 잔여 %d정착지(시작 %d)%s.", NUMS[i], fname(s.key), s.last or 0, s.base or s.last or 0, trend)
			if S.threats and S.threats.targets then
				for _, t in ipairs(S.threats.targets) do
					if t.owner == s.key and t.near then
						line = line .. string.format(" 다음 수: %s 공략.", region_disp(t.region)); break
					end
				end
			end
		elseif s.kind == "prov" then
			line = string.format("%s %s 속주 완성 — %d/%d.", NUMS[i], province_disp(s.key), s.last or 0, s.base or 0)
			for _, p in ipairs((ST and ST.provinces) or {}) do
				if p.key == s.key and p.miss_region then
					line = line .. string.format(" 미보유: %s%s.", region_disp(p.miss_region),
						p.miss_owner and ("(" .. fname(p.miss_owner) .. ")") or "")
					break
				end
			end
		elseif s.kind == "prep" then
			line = string.format("%s 위기 대비 — '%s' %s턴 발동 예정(현재 %s턴). 자금과 예비군을 비축하세요.",
				NUMS[i], endgame_disp(s.key), tostring(s.base or "?"), tostring(num(S.turn, "?")))
		elseif s.kind == "posture" then
			local m = {
				consolidate = "내실 — 확장을 멈추고 통합·방어를 정비",
				expand = "확장 준비 — 약한 이웃 방면으로 다음 전쟁을 설계",
				tech = "내실 — 기술·경제 축적으로 다음 도약을 준비",
			}
			line = NUMS[i] .. " " .. (m[s.key] or "자세 정비") .. "."
		end
		if line then L[#L + 1] = line end
	end
	if ST and ST.endgame and #(ST.endgame.active or {}) > 0 then
		L[#L + 1] = "⚠ 진행 중 위기: " .. endgame_disp(ST.endgame.active[1]) .. " — 최우선 대응."
	end
	-- 군단 점검 1줄(검증 가능한 신호만: 충원율·야포)
	if ST and ST.armies and #ST.armies > 0 then
		local weakest, art_total = nil, 0
		for _, a in ipairs(ST.armies) do
			art_total = art_total + (a.art or 0)
			if a.avg and (not weakest or a.avg < weakest.avg) then weakest = a end
		end
		local parts = {}
		if weakest and weakest.avg and weakest.avg < 70 then
			parts[#parts + 1] = string.format("%s 군단 충원율 %d%% — 회복 후 진격", weakest.name or "일부", weakest.avg)
		end
		if art_total == 0 and S.threats and S.threats.targets and #S.threats.targets > 0 then
			parts[#parts + 1] = "야포 0문 — 공성 장기화 주의"
		end
		if #parts > 0 then L[#L + 1] = "군단 점검: " .. table.concat(parts, " · ") .. "." end
	end
	return L
end

-- ── 팝업 패널 (v11) — CA 공식 패턴: scripted_subtitles + text_child ──
-- 근거: 바닐라 lib_campaign_manager.lua show_subtitle(). CreateComponent
--   "UI/Common UI/scripted_subtitles.twui.xml" → find "text_child" 자식에 SetStateText.
local PANEL_ID = "advisor_panel"
local g_panel_shown = false
local g_panel_turn  = -1   -- 마지막으로 패널을 띄운 턴(①: 턴 인식 토글 — 같은 턴 재클릭만 숨김)
local function get_panel()
	local panel = nil
	pcall(function()
		local root = core:get_ui_root()
		panel = find_uicomponent(root, PANEL_ID)
		if panel then return end
		local addr = root:CreateComponent(PANEL_ID, "UI/Common UI/scripted_subtitles.twui.xml")
		if addr then panel = UIComponent(addr); proof("v11 패널 생성(scripted_subtitles)", true)
		else proof("v11 !!! 패널 생성 실패", true) end
	end)
	return panel
end
-- 클릭 시: 이미 떠 있고 '같은 턴'이면 숨김(재클릭=닫기), 그 외엔 항상 표시+갱신(①).
-- → 다음 턴에 새 브리핑을 보려고 클릭하면 숨김이 아니라 갱신됨(기존 토글의 UX 버그 해소).
-- 텍스트=text_child, 배경=frame_black(레이아웃에 있으나 visible=false).
local function show_panel(prose, turn)
	pcall(function()
		if not get_panel() then return end
		local root = core:get_ui_root()
		local textc = find_uicomponent(root, PANEL_ID, "text_child")
		if not textc then proof("v18 !!! text_child 못찾음", true); return end
		local bg = find_uicomponent(root, PANEL_ID, "frame_black")   -- 숨겨진 검은 배너 배경

		-- ① 턴 인식 토글: 같은 턴에 다시 누르면 닫기.
		if g_panel_shown and turn == g_panel_turn then
			g_panel_shown = false
			if bg then pcall(function() bg:SetVisible(false) end) end
			pcall(function() textc:SetVisible(false) end)
			proof("v18 패널 숨김(같은 턴 재클릭)", true)
			return
		end

		-- 표시 + 갱신
		pcall(function() textc:SetStateText(prose, "") end)   -- 텍스트 먼저 세팅 후 측정(순서 중요)
		g_panel_shown, g_panel_turn = true, turn
		if bg then pcall(function() bg:SetVisible(true) end) end
		pcall(function() textc:SetVisible(true) end)

		local COL, X, Y, PAD = 460, 24, 150, 18
		pcall(function() textc:SetTextHAlign("left") end)
		pcall(function() textc:SetOpacity(255) end)
		-- ② 클리핑 해결 — CA 정식 패턴(lib_text_pointers.lua): 폭 강제 래핑 후 TextDimensions(높이)에
		--    TextYOffset(폰트 상/하 오프셋)을 더해 정확 높이 산출. (기존 h+8 하드코딩이 오프셋보다
		--    작아 마지막 줄이 잘리던 원인.)
		pcall(function() textc:ResizeTextResizingComponentToInitialSize(COL, 2000) end)  -- 측정용 넉넉한 높이(측정 자체가 안 잘리게)
		local box_h = 600   -- 측정 실패 시 폴백(넉넉히 — 잘리는 것보다 큰 게 나음)
		pcall(function()
			local _, th = textc:TextDimensions()
			if th and th > 20 then
				local oyt, oyb = 0, 0
				pcall(function() oyt, oyb = textc:TextYOffset() end)   -- 폰트 상/하 여백(CA와 동일)
				box_h = th + (oyt or 0) + (oyb or 0)
			end
		end)
		box_h = clamp(box_h, 60, 860)   -- 화면 밖으로 넘치지 않게 상한(Y=150 기준)
		pcall(function() textc:ResizeTextResizingComponentToInitialSize(COL, box_h) end)  -- 정확 높이로 확정(클리핑·데드스페이스 제거)
		if bg then
			pcall(function() bg:SetImagePath("ui/skins/default/tooltip_frame.png", 0, false) end)  -- 자막배너→툴팁프레임
			pcall(function() bg:SetCurrentStateImageMargins(0, 16, 20, 16, 20) end)   -- CA 정확 9-slice
			pcall(function() bg:SetCanResizeHeight(true); bg:SetCanResizeWidth(true) end)
			pcall(function() bg:Resize(COL + PAD * 2, math.floor(box_h + PAD * 2)) end)
			pcall(function() bg:SetOpacity(235) end)
			pcall(function() bg:MoveTo(X, Y) end)
		end
		pcall(function() textc:MoveTo(X + PAD, Y + PAD) end)
		-- z-순서: 패널 전체를 topmost(내부는 frame_black<text_child 순 → 텍스트가 배경 위).
		pcall(function() local p = find_uicomponent(root, PANEL_ID); if p then p:RegisterTopMost() end end)
		proof(string.format("v18 패널 표시 col=%d h=%d turn=%s", COL, box_h, tostring(turn)), true)
	end)
end

-- ── 종족 고유 자원(①) — pooled_resource_manager로 팩션 메커니즘 조회 ──
-- API(바닐라 실측): faction:pooled_resource_manager():resource("키"):value(), :is_null_interface().
-- 키는 프로필 resources에 정의(za_faction_profiles). 임계치 아는 것만 긴급 플래그, 나머지는 값+프레이밍.
local function gather_resource(prof)
	if not (prof and prof.resources and #prof.resources > 0) then return nil end
	local outv = nil
	local diag = {}   -- DEBUG용: 키별 조회 상태
	pcall(function()
		local f = cm:get_local_faction(true)
		if not f then diag[#diag+1] = "팩션없음"; return end
		local prm = f:pooled_resource_manager()
		if not prm then diag[#diag+1] = "prm없음"; return end
		for _, r in ipairs(prof.resources) do
			local res = nil
			pcall(function() res = prm:resource(r.key) end)
			if not res then diag[#diag+1] = r.key .. ":res-nil"
			elseif res:is_null_interface() then diag[#diag+1] = r.key .. ":null(팩션에 없음)"
			else
				local v = nil
				pcall(function() v = res:value() end)
				if v == nil then diag[#diag+1] = r.key .. ":값읽기실패"
				else
					local note, urgent = r.note, false
					if r.low_thresh and v <= r.low_thresh and r.low_note then note = r.low_note; urgent = true end
					outv = { label = r.label, value = v, note = note, urgent = urgent }
					return   -- 첫 유효 자원만
				end
			end
		end
	end)
	if DEBUG_FILE and not outv and #diag > 0 then
		pcall(function() proof("[디버그] 종족자원 미해결 → " .. table.concat(diag, " / "), true) end)
	end
	return outv
end

-- ── 클릭 시 실행되는 두뇌 ────────────────────────────────────────────
local function run_advisor()
	local ok, err = pcall(function()
		local S = gather_state()
		local prof = get_profile(S)                        -- 진영 전략 프로필
		S.resource = gather_resource(prof)                 -- 종족 고유 자원(①)
		local hist = read_history()                        -- 턴별 추세
		S.trend = compute_trend(S, hist)
		S.rival_growth = compute_rival_growth(S, hist)   -- ⑥ 라이벌 성장률
		proof(string.format("[디버그] 세이브값 히스토리 %d행 · 추세 %s · 최강라이벌 %s · 종족자원 %s",
			#hist, S.trend and "O" or "X(첫턴/미축적)",
			S.snowball and tostring(S.snowball.key) or "없음",
			S.resource and tostring(S.resource.label) or "없음(미커버 종족)"), true)
		S.strat = collect_strategic(S)                     -- 전략 2.0: 속주·국력·군단·엔드게임·승리조건
		local D, cand = analyze(S, prof)
		-- 전략 2.0: 다턴 계획 — 로드 → 완료 감지·기준선 승계 갱신 → 저장
		do
			local dg = diagnose(S, D)
			local oldraw = nil
			pcall(function() oldraw = cm:get_saved_value("advisor_plan") end)
			local plan, events = plan_revise(S, dg and dg.label, plan_deserialize(oldraw))
			S.plan, S.plan_events = plan, events
			pcall(function() cm:set_saved_value("advisor_plan", plan_serialize(plan)) end)
		end
		proof(build_briefing(S, D, cand, prof), true)      -- 파일: 구조화 블록
		local prose = build_prose(S, D, cand, prof)        -- 자연어 산문
		proof("[참모 브리핑] " .. prose, true)             -- 파일에도 산문 기록
		local race = (prof.race and prof.race ~= "(일반)") and prof.race or fname(S.faction)
		local tip = string.format("📋 %s 참모 브리핑 · %s턴\n%s", race, tostring(num(S.turn, "?")), prose)
		pcall(function()                                   -- 화면: 산문 툴팁
			local btn = find_uicomponent(core:get_ui_root(), BUTTON_ID)
			if btn then btn:SetTooltipText(tip, "", true) end
		end)
		show_panel(prose, num(S.turn, 0))                  -- 화면: 팝업 패널(①턴 인식 토글, ②정확 높이)
		record_snapshot(S, hist)                           -- 현재 턴 스냅샷 저장
	end)
	if not ok then proof("v9f run_advisor 예외: " .. tostring(err), true) end
end

-- ── 버튼 + 리스너 (Step3/4 유지) ─────────────────────────────────────
local function register_click_listener()
	core:add_listener(
		"advisor_button_click", "ComponentLClickUp",
		function(context) return context.string == BUTTON_ID end,
		function(context) run_advisor() end,
		true)
	proof("2a 클릭 리스너 등록 (버튼=" .. BUTTON_ID .. ")", true)
end

local function create_advisor_button()
	local ok, err = pcall(function()
		local root = core:get_ui_root()
		local addr = root:CreateComponent(BUTTON_ID, BUTTON_TEMPLATE)
		if not addr then proof("2a !!! CreateComponent nil", true); return end
		local btn = UIComponent(addr)
		local rw, rh = root:Dimensions()
		btn:MoveTo(math.floor(rw * 0.45), 90)
		btn:SetVisible(true); btn:SetInteractive(true); btn:SetDisabled(false)
		btn:RegisterTopMost(); btn:SetMoveable(true)
		pcall(function() btn:SetTooltipText("전략 어드바이저 — 클릭하면 브리핑 생성 (마우스 올려 확인)", "", true) end)
		proof("2a 버튼 생성 OK id=" .. tostring(btn:Id()), true)
	end)
	if not ok then proof("2a !!! 버튼 생성 예외: " .. tostring(err), true) end
end

-- [first tick] 전역 함수(파일명 동일)
function campaign_advisor()
	if g_done then return end
	g_done = true
	register_click_listener()
	create_advisor_button()
	proof("2a campaign_advisor() 준비 완료 — 버튼 클릭 시 전략 브리핑 생성.", true)
end

-- ── 오프라인 테스트 export (게임에선 완전 무시) ──────────────────────
-- 하니스(test/run_brain_tests.lua)가 dofile 전에 ADVISOR_TEST_EXPORTS=true를
-- 설정하면 순수 함수들을 노출. 인게임에선 전역이 nil이라 이 블록은 no-op.
if ADVISOR_TEST_EXPORTS then
	CA_TEST = {
		num = num, clamp = clamp, sev = sev, urgency = urgency,
		has_batchim = has_batchim, josa = josa,
		fname = fname, region_disp = region_disp, first_names = first_names,
		get_profile = get_profile,
		analyze = analyze, overall = overall, diagnose = diagnose,
		build_briefing = build_briefing, build_prose = build_prose,
		read_history = read_history, compute_trend = compute_trend,
		compute_rival_growth = compute_rival_growth, record_snapshot = record_snapshot,
		gather_resource = gather_resource,
		-- 전략 2.0(순수부)
		plan_serialize = plan_serialize, plan_deserialize = plan_deserialize,
		plan_generate = plan_generate, plan_revise = plan_revise,
		plan_prose_lines = plan_prose_lines, endgame_disp = endgame_disp,
	}
end
