--[[===========================================================================
  TW3 캠페인 어드바이저 — 본체(두뇌 + UI 셸)
  ---------------------------------------------------------------------------
  로더 계약: NewSession 때 top-level 실행 → first tick 때 전역 campaign_advisor().
  버튼 클릭 → 상태수집 → 파생지표 → 스코어링 → 국면 진단 → 다턴 계획 →
  한국어 산문 + 7탭 패널. 전부 읽기 전용(게임 상태를 바꾸지 않는다).

  화면: 게임 언어가 한국어면 CJK 폰트가 이미 로드돼 있어 **패널에 한글이 그대로
  렌더된다**(v8 인게임 확인). 툴팁은 요약, 패널은 탭별 본문. 프루프 파일은
  디버그용이지 유일한 출력이 아니다.

  탭은 CA_DOMAINS 레지스트리로 붙는다(advisor_dom_*.lua가 각자 등록).
  ※ 로드 순서는 파일명 순이라 advisor_*가 이 파일보다 먼저 뜬다 →
    도메인이 CA_U/CA_BLD를 잡는 것은 반드시 '호출 시점'에만.

  설계 근거(실측, docs/cai_seed_data.md):
    - 경제축: 예산 default = army 55 / construction 40 (SEED.army_base/cons_base).
    - 생존버퍼 5턴 목표(SEED.buffer_target).
    - 전략축: defensive ↔ default ↔ aggressive ↔ opportunistic.

  ※ LLM 브리지는 채택하지 않기로 결정했다(2026-07-23). API 키·동반 프로세스·
    네트워크가 배포에 과한 진입장벽이라는 사용자 판단. 자연어는 순수 Lua NLG
    (문구 풀 + 절 병합 + 조사 자동선택)로 낸다.
=============================================================================]]

local BUTTON_ID       = "advisor_recommend_button"
local BUTTON_TEMPLATE = "ui/templates/round_medium_button"

-- 디버그 파일: ★개발·검증 중에는 true(프루프 파일로 계산 내역 전부 확인).
--   배포 직전 단계(F5)에서만 false로 내리면 유저 디스크에 파일 안 남김.
--   경로는 개발자(veria) 기준; 배포 시엔 off라 무관.
local DEBUG_FILE = true
local PROOF_PATH = "C:/Users/veria/tw3_advisor_proof.txt"

-- 페이지 분할 강제(검증용). nil이면 평소대로 화면 높이에서 계산한다.
--   왜 필요한가: MAXH = 화면높이 - 176 - 96 이다. 개발 기기는 UI 공간이 1240이라
--   MAXH=968인데, 탭 본문은 목록마다 상한이 있어 가장 긴 연구 탭도 866줄이다
--   (영토 25로 돌려도 내정 탭은 28줄=560px — 영토 수와 거의 무관하다).
--   즉 이 기기에서는 어떤 세이브로도 2쪽이 되지 않아 페이지 코드가 한 번도
--   실행되지 않는다. 반대로 1080p 사용자는 MAXH≈565라 '매번' 2쪽을 본다.
--   그래서 해상도를 바꾸는 대신 이 값으로 강제해 한 번 확인한다.
--   ※ DEBUG_FILE에 묶여 있다 — 배포 때 DEBUG_FILE=false면 자동으로 죽는다.
local DEBUG_MAXH = 500

-- CA 실측 시드 상수
local SEED = {
	army_base = 55, cons_base = 40,   -- default 예산배분(%)
	buffer_target = 5,                -- 흑자시 목표 재정버퍼(턴)
	-- ※ reinvest(0.9)는 뺐다. 상수만 있고 쓰는 곳이 없었는데 "CA 실측 시드"라는
	--   제목 아래 있어 재투자율이 적용되는 것처럼 보였다.
}

-- 스캔 상한(성능). 도달하면 조용히 자르지 말고 S.capped에 남겨 브리핑에 밝힌다 —
-- 특히 위협 상한에 걸리면 인접 정보가 비어 '무방비'로 오판하고, 그 오판이
-- 내정 탭의 모병 추천까지 끌고 간다(v59에서 threatened.defended를 물렸다).
local CAP = { neighbor = 600, threat = 800, province = 50, met = 60 }

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

-- 한국어 조사 자동 선택 (v35: tossi 규칙 이식 — 숫자 받침 + (으)로 ㄹ-예외).
-- 숫자 끝자리 한자음 받침: 0(영)·1(일)·3(삼)·6(육)·7(칠)·8(팔) 있음 / 2·4·5·9 없음.
--   끝자리 0은 영/십/백/천/만 어느 쪽으로 읽어도 전부 받침 있음 → true로 일괄 안전.
local DIGIT_BATCHIM = { [0]=true, [1]=true, [2]=false, [3]=true, [4]=false,
                        [5]=false, [6]=true, [7]=true, [8]=true, [9]=false }
-- 마지막 음절의 코드포인트(한글이면), 아니면 nil. #·byte는 바이트 단위(실측)라 안전.
local function last_hangul_cp(word)
	local n = #word
	if n < 3 then return nil end
	local b1, b2, b3 = word:byte(n - 2), word:byte(n - 1), word:byte(n)
	if not (b1 and b2 and b3) then return nil end
	if b1 < 0xE0 or b1 > 0xEF then return nil end                 -- 3바이트 UTF-8(한글) 아님
	local cp = (b1 % 0x10) * 4096 + (b2 % 0x40) * 64 + (b3 % 0x40)
	if cp < 0xAC00 or cp > 0xD7A3 then return nil end             -- 한글 음절 범위 아님
	return cp
end
local function has_batchim(word)
	local n = #word
	if n >= 1 then
		local lb = word:byte(n)
		if lb and lb >= 0x30 and lb <= 0x39 then return DIGIT_BATCHIM[lb - 0x30] end
	end
	local cp = last_hangul_cp(word)
	if not cp then return nil end
	return ((cp - 0xAC00) % 28) ~= 0                              -- 받침 있으면 true
end
-- 조사 선택: 받침 있으면 withB, 없으면(또는 비한글) without.
-- ※ WH3 Lua의 string.sub은 문자 단위라 pair 분리가 깨짐 → 조사를 개별 인자로 받는다(실측 버그 회피).
local function josa(word, withB, without)
	if has_batchim(word) == true then return withB else return without end
end
-- (으)로 전용: 받침 없음 또는 ㄹ받침(종성 8)이면 "로"(서울로·물로), 그 외 "으로"(짚으로).
-- 숫자: 1(일)·7(칠)·8(팔)=ㄹ받침→로, 2·4·5·9=모음→로, 0(영·십·백…)·3(삼)·6(육)→으로.
local function josa_ro(word)
	local n = #word
	if n >= 1 then
		local lb = word:byte(n)
		if lb and lb >= 0x30 and lb <= 0x39 then
			local d = lb - 0x30
			if d == 0 or d == 3 or d == 6 then return "으로" end
			return "로"
		end
	end
	local cp = last_hangul_cp(word)
	if not cp then return "로" end                                -- 비한글 폴백(josa와 동일 방침)
	local jong = (cp - 0xAC00) % 28
	if jong == 0 or jong == 8 then return "로" end
	return "으로"
end
-- 숫자+(으)로 축약 헬퍼: nro(-20) → "-20으로"
local function nro(v)
	local s = tostring(v)
	return s .. josa_ro(s)
end

-- 재정 활주로 문구(v40) — 음수 국고·0턴을 "~-3턴 내 고갈" 같은 헛말로 내보내지 않는다.
--   long=true 는 U(긴급) 줄용 완문, 기본은 국면 줄용 축약. 둘은 상호배타 배치라 반복감 없음.
local function runway_phrase(P, long)
	if type(P) ~= "table" then return nil end
	if P.broke then return "국고가 이미 마이너스입니다" end
	if P.runway == 0 then
		return long and "이 추세면 이번 턴에 국고가 바닥납니다" or "이 추세면 이번 턴에 바닥납니다"
	end
	if P.runway then
		return long and string.format("이 추세면 약 %d턴 뒤 국고가 바닥납니다", P.runway)
			or string.format("이 추세면 ~%d턴 내 고갈됩니다", P.runway)
	end
	return nil
end

-- 첫 정착지 후보 선택(v40) — 전시 상대 우선, 기후 부적합은 최후.
--   계획 ①과 '확장 기회' 줄이 각자 고르면 같은 정착지를 두 번 방송하게 되므로 판정은 여기 한 곳.
local function pick_settle(list)
	if type(list) ~= "table" or #list == 0 then return nil end
	local pick, alt
	for _, c in ipairs(list) do
		if c.suit ~= "suitability_verypoor" then
			if c.at_war then pick = c; break elseif not alt then alt = c end
		end
	end
	return pick or alt or list[1]
end

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
-- v40: ok(조회 성공 여부)도 반환 — 실패한 빈 집합을 "전쟁 없음"으로 위장하지 않기 위해.
local function key_set(list_getter, cap)
	local set, cnt = {}, 0
	local ok = pcall(function()
		local l = list_getter(); local n = l:num_items()
		for i = 0, math.min(n, cap or 200) - 1 do set[l:item_at(i):name()] = true; cnt = cnt + 1 end
	end)
	return set, cnt, ok
end

-- 실제 국경 인접: 내 지역들의 인접 지역 소유주 → 이웃 팩션 키 집합.
-- (adjacency 폭주 방지 위해 총 검사 횟수 상한.)
-- v40: ok도 반환 — 인접 조회 실패를 "국경 평온"으로 위장하지 않기 위해(수집상태에 기록).
local function gather_neighbors(f, my_key)
	local nb = {}
	local capped = false
	local ok = pcall(function()
		local regions = f:region_list(); local rn = regions:num_items()
		local checks = 0
		for i = 0, rn - 1 do
			if checks > CAP.neighbor then capped = true; break end
			local reg = regions:item_at(i)
			local adj = reg:adjacent_region_list(); local an = adj:num_items()
			for j = 0, an - 1 do
				checks = checks + 1
				local a = adj:item_at(j)
				local abandoned = false
				pcall(function() abandoned = a:is_abandoned() end)
				if not abandoned then
					local own = nil        -- v40: 바깥 ok(pcall 결과)와 이름 충돌 피해 own으로
					pcall(function()
						local o = a:owning_faction()
						if o and not o:is_null_interface() then own = o:name() end
					end)
					if own and own ~= my_key then nb[own] = true end
				end
			end
		end
	end)
	return nb, ok, capped
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
local function gather_threats(f, war_set, border_enemies, my_key)
	local T = { sieges = {}, threatened = {}, targets = {}, settle = {}, my_field = {} }
	T.ok = pcall(function()
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
					if checks > CAP.threat then T.capped = true; break end
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
							local suit = nil   -- 기후 적합성(v33) — 부적합 땅 점령 추천 방지
							pcall(function() suit = f:get_climate_suitability(areg:settlement():get_climate()) end)
							T.targets[#T.targets + 1] = { region = anm, owner = ok, my_border = nm, suit = suit }
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
		-- v40: 영토 0(호드·유랑) 실명 구간 — 위 지역 루프가 한 번도 돌지 않아 표적·위협이
		--   전부 빈 값이 되던 문제. 내 야전군이 선 지역을 앵커로 인접을 훑어
		--   ①첫 정착지 후보(T.settle) ②전쟁 중 적 정착지(T.targets) ③앵커 인근 적군 접근을 잡는다.
		--   폐허(is_abandoned)는 식민 가능 여부 미실측이라 제외(짐작 금지).
		if rn == 0 then
			local acheck = 0
			pcall(function()
				local myf = f:military_force_list(); local mn = myf:num_items()
				for i = 0, math.min(mn, 10) - 1 do
					local mf = myf:item_at(i)
					local reg = nil
					pcall(function()
						if mf:has_general() and not mf:is_armed_citizenry() then
							local ch = mf:general_character()
							if ch and ch:has_region() and not ch:region():is_null_interface() then reg = ch:region() end
						end
					end)
					if reg then
						local anchor = reg:name()
						adj_to_mine[anchor] = anchor        -- 앵커 = 내 위치(적군 접근 판정 기준선)
						local cands = { reg }
						pcall(function()
							local adj = reg:adjacent_region_list(); local an = adj:num_items()
							for j = 0, an - 1 do
								if acheck > 60 then break end
								acheck = acheck + 1
								cands[#cands + 1] = adj:item_at(j)
							end
						end)
						for _, c in ipairs(cands) do
							pcall(function()
								local cn = c:name()
								if not adj_to_mine[cn] then adj_to_mine[cn] = anchor end
								if not tgt_seen[cn] and #T.settle < 8 then
									tgt_seen[cn] = true
									local aband = false
									pcall(function() aband = c:is_abandoned() end)
									local ow = nil
									pcall(function()
										local o = c:owning_faction()
										if o and not o:is_null_interface() then ow = o:name() end
									end)
									if not aband and ow and ow ~= my_key then
										local suit = nil
										pcall(function() suit = f:get_climate_suitability(c:settlement():get_climate()) end)
										T.settle[#T.settle + 1] = { region = cn, owner = ow, at_war = (war_set[ow] == true), suit = suit }
										if war_set[ow] then
											T.targets[#T.targets + 1] = { region = cn, owner = ow, my_border = anchor, suit = suit }
										end
									end
								end
							end)
						end
					end
				end
			end)
		end
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
	D.ok = pcall(function()
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
	PV.ok = pcall(function()
		local regions = f:region_list(); local rn = regions:num_items()
		PV.capped = rn > CAP.province
		local seen, corr_seen = {}, {}
		for i = 0, math.min(rn, CAP.province) - 1 do
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
	local capped = false
	local ok = pcall(function()
		local met = f:factions_met(); local n = met:num_items()
		capped = n > CAP.met
		for i = 0, math.min(n, CAP.met) - 1 do
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
	if not top then return nil, ok, capped end   -- ok=true면 '정말 라이벌 없음', false면 '조회 실패'(v35 구분)
	top.dominant = top.regions >= math.max(12, num(my_regions, 0) * 2)   -- 압도적이면 즉시 경고, 아니면 성장률 추적용
	return top, ok, capped
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
	S.can_capture  = V(function() return f:is_allowed_to_capture_territory() end)   -- v39: 호드(false)는 정착 조언 제외

	-- 전쟁 집합 + 국경 인접 → 즉각/먼 위협, 비적대 이웃 구분
	local war_set, war_count, war_ok = key_set(function() return f:factions_at_war_with() end, 60)
	S.war_count = war_count
	S.war_set = war_set   -- 전략 2.0: 계획 엔진의 "아직 전쟁 중인가" 판정용
	local neighbors, nb_ok, nb_cap = gather_neighbors(f, S.faction)
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
	-- 위협·방어(모듈1): 포위·접근 적군·무방비 정착지 (+v40 영토0 앵커 스캔)
	S.threats = gather_threats(f, war_set, S.border_enemies, S.faction)
	-- 외교 기회(모듈4): 성사 가능한 화친/동맹
	S.diplo = gather_diplomacy(f, war_set, S.border_enemies, S.border_others)
	-- 속주 내부(④): 공공질서 위기
	S.province = gather_province_issues(f, S.subculture)
	-- 스노우볼 감시(⑥): 압도적으로 큰 비동맹 세력
	local sb, sb_ok, sb_cap = gather_snowball(f, S.regions)
	S.snowball = sb
	-- 스캔 상한 도달 기록. '실패'(health)와는 다르다 — 읽긴 읽었는데 다 못 읽은 것이다.
	-- 조용히 자르면 대제국 후반에 "국경 평온·무방비 없음"이 거짓으로 나온다.
	S.capped = {}
	if nb_cap then S.capped[#S.capped + 1] = "국경" end
	if S.threats and S.threats.capped then S.capped[#S.capped + 1] = "위협" end
	if S.province and S.province.capped then S.capped[#S.capped + 1] = "속주" end
	if sb_cap then S.capped[#S.capped + 1] = "라이벌" end
	-- 수집 건강 상태(v35 — 3-상태 분리): '실패'와 '평온'을 구분. 실패 섹션은 조언 보류를 명시.
	S.health = {}
	if S.faction == nil then S.health[#S.health + 1] = "핵심 상태" end
	-- v40: 재정·규모 원값과 국경/전쟁 수집도 감시. 이 둘이 조용히 비면 "국경 평온·전쟁 없음"으로
	--   위장돼 v35 3-상태의 취지가 무너진다(가장 상위 입력인데 유일하게 ok가 없던 구간).
	if S.treasury == nil or S.income == nil or S.regions == nil then S.health[#S.health + 1] = "재정·규모" end
	if not nb_ok then S.health[#S.health + 1] = "국경" end
	if not war_ok then S.health[#S.health + 1] = "전쟁" end
	if not (S.threats and S.threats.ok) then S.health[#S.health + 1] = "위협" end
	if not (S.diplo and S.diplo.ok) then S.health[#S.health + 1] = "외교" end
	if not (S.province and S.province.ok) then S.health[#S.health + 1] = "내정" end
	if not sb_ok then S.health[#S.health + 1] = "라이벌" end
	return S
end

-- IAUS-lite(v38, 문서1 1순위 축소 채택): 근거를 기여 점수와 함께 기록 → 기여 순 출력.
--   (전면 곱셈형 IAUS는 정직하게 보류 — v32 이후 패널 조언은 계획 엔진이 주도해
--    analyze 재구성의 가시 효과가 작음. 근거 랭킹 + 응답곡선 스무딩만 채택.)
-- issue=true면 '문제형' 근거(부족·위협) — 보강 줄이 기회 설명 대신 이것을 우선(v39).
local function R(rs, pts, text, issue) rs[#rs + 1] = { p = pts, t = text, issue = issue } end
local function finish_reasons(rs)
	table.sort(rs, function(a, b) return a.p > b.p end)
	local out, issue1 = {}, nil
	for _, r in ipairs(rs) do
		out[#out + 1] = r.t
		if r.issue and not issue1 then issue1 = r.t end
	end
	return out, issue1
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

	-- v40: buffer의 999는 "수입 0 = 산출 불가" 센티넬. 값처럼 문구에 흘리면
	--   무일푼에게 "금고 과다 적재(999턴치)" 같은 정반대 조언이 나간다 → known 플래그로 차단.
	-- v53: 장부가 흑자라도 국고가 비어 있으면 위기다. 42턴 벨라코르 실측에서
	--   국고 7골드 · 버퍼 0.0턴 · 실측 추세 -1412인데 순수입이 +55라
	--   deficit=false로 잡혀 "흑자 운영 / 국면=소모전"이 나왔다. 순수입만 보면
	--   일회성 지출(모병·건설)로 금고가 마르는 상황을 통째로 놓친다.
	local cash_low = (income > 0) and (buffer < 1)
	local D = { density = density, buffer = buffer, buffer_known = (income > 0), immediate = immediate,
	            distant = distant, wars = wars, others = others, deficit = deficit, net = net,
	            cash_low = cash_low, money_trouble = (deficit or cash_low) }
	local cand = {}

	-- 군사 (모집/증원) — 즉각 위협을 먼 전쟁보다 크게 가중
	do
		local sc, rs = SEED.army_base, {}
		if immediate > 0 then local p = immediate * 12; sc = sc + p; R(rs, p, string.format("국경 접한 적 %d개(즉각 위협)", immediate)) end
		if distant  > 0 then local p = distant * 3; sc = sc + p; R(rs, p, string.format("국경 밖 전쟁 %d개", distant)) end
		if regions > 0 and density < 1 then
			local p = math.floor(20 * (1 - density) + 0.5)   -- 응답곡선(v38): 얇을수록 비례(계단 제거)
			if p > 0 then sc = sc + p; R(rs, p, string.format("영토 %d 대비 필드군 %s 얇음", regions, nro(field))) end
		end
		if deficit then sc = sc - 15; R(rs, -15, "적자라 모집 여력 제한") end
		-- v53: 국고가 비었으면 순수입이 +라도 지금 뽑을 돈이 없다. 실측(42턴 벨라코르)에서
		--   국고 7골드에 "순수입 +55로 모집 여력"을 근거로 군사를 1순위로 올렸다.
		if cash_low then sc = sc - 18; R(rs, -18, string.format("국고 %s뿐 — 당장 뽑을 돈이 없음", nro(treasury))) end
		if net > 0 and not cash_low then sc = sc + 8; R(rs, 8, string.format("순수입 +%s 모집 여력", nro(net))) end
		cand[#cand+1] = { key = "military", label = "군사", score = clamp(sc, 0, 100), reasons = finish_reasons(rs) }
	end
	-- 경제 (건설/수입기반)
	do
		local sc, rs = SEED.cons_base, {}
		if deficit then sc = sc + 30; R(rs, 30, "적자 — 수입 기반 확충 시급", true)
		elseif cash_low then sc = sc + 20; R(rs, 20, "국고 고갈 — 수입 기반부터 세워야 함", true) end
		if buffer < SEED.buffer_target then
			local p = math.floor(15 * (SEED.buffer_target - buffer) / SEED.buffer_target + 0.5)   -- 응답곡선(v38)
			if p > 0 then sc = sc + p; R(rs, p, string.format("재정 버퍼 %.1f턴(CA 권장 %d턴 미만)", buffer, SEED.buffer_target), true) end
		end
		if D.buffer_known and buffer > 15 and not deficit then sc = sc + 10; R(rs, 10, string.format("금고 과다 적재(%.0f턴치) — 재투자 권장", buffer), true) end
		if regions > 0 and immediate == 0 then sc = sc + 12; R(rs, 12, "국경 평온 — 성장 적기") end   -- v40: 영토0엔 공허한 말
		if immediate >= 2 then local p = -immediate * 4; sc = sc + p; R(rs, p, "다전선 압박으로 건설 우선순위 하락", true) end
		local rr, ri = finish_reasons(rs)
		cand[#cand+1] = { key = "economy", label = "경제", score = clamp(sc, 0, 100), reasons = rr, issue = ri }
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
		if nsiege > 0 then local p = 45 + nsiege * 10; sc = sc + p; R(rs, p, string.format("정착지 %d곳 포위 중 — 즉시 구원", nsiege), true) end
		if nundef > 0 then local p = 20 + nundef * 8; sc = sc + p; R(rs, p, string.format("무방비 위협 %d곳(근처 아군 없음)", nundef), true) end
		if nthreat > nundef then sc = sc + 8; R(rs, 8, string.format("적 야전군이 %d개 지역 위협", nthreat), true) end
		local nunrest = (S.province and #S.province.unrest) or 0
		if nunrest > 0 then local p = 8 + nunrest * 5; sc = sc + p; R(rs, p, string.format("공공질서 위기 속주 %d곳(반란 위험)", nunrest), true) end
		if immediate > 0 then local p = immediate * 15; sc = sc + p; R(rs, p, string.format("국경 접한 적 %d개", immediate), true) end
		if regions > 0 and density < 0.5 then sc = sc + 25; R(rs, 25, "군대 밀도 매우 낮음 — 방어 취약", true) end
		if S.strong_enemy and num(S.strong_enemy_r, 0) > num(S.my_regions, 0) then
			sc = sc + 15
			R(rs, 15, string.format("%s(영토 %d)가 우리(%d)보다 커 방어 강화 필요", fname(S.strong_enemy), num(S.strong_enemy_r, 0), num(S.my_regions, 0)), true)
		end
		if sc > 0 then
			local rr, ri = finish_reasons(rs)
			cand[#cand+1] = { key = "defense", label = "방어", score = clamp(sc, 0, 100), reasons = rr, issue = ri }
		end
	end
	-- 확장 (선제/영토) — 국경 평온 + 흑자 + 비적대 이웃 존재. 약한 이웃을 표적으로 지목.
	-- buffer_known 필수: 수입 0이면 buffer가 999 센티넬이라 무일푼에게 "확장 적기"가 나간다.
	-- v40이 같은 센티넬을 '금고 과다' 문구에서만 막고 이 게이트는 놓쳤다.
	if immediate == 0 and net > 0 and D.buffer_known and buffer >= SEED.buffer_target and others > 0 then
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
		cand[#cand+1] = { key = "tech", label = "기술", score = 45, reasons = { "연구가 미가동 상태 — 즉시 착수 권장" }, issue = "연구가 미가동 상태 — 즉시 착수 권장" }
	end
	-- 외교 (동맹/화친) — 다전선 + 성사 가능한 화친/동맹(모듈4)
	do
		local sc, rs = 0, {}
		if wars >= 2 then local p = 30 + wars * 6; sc = sc + p; R(rs, p, string.format("%d개 세력과 동시 전쟁 — 전선 축소 검토", wars)) end
		if S.diplo and #S.diplo.peace > 0 then sc = sc + 22; R(rs, 22, string.format("화친 성사 가능: %s", first_names(S.diplo.peace, 2))) end
		if S.diplo and #S.diplo.ally > 0 then sc = sc + 12; R(rs, 12, string.format("동맹 성사 가능: %s", first_names(S.diplo.ally, 2))) end
		if sc > 0 then cand[#cand + 1] = { key = "diplomacy", label = "외교", score = clamp(sc, 0, 100), reasons = finish_reasons(rs) } end
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
	-- 국고가 비었으면 장부가 흑자여도 '흑자 운영'이라고 부르지 않는다(v53).
	if D.deficit then p[#p+1] = "적자 운영"
	elseif D.cash_low then p[#p+1] = "국고 바닥"
	elseif D.net > 0 then p[#p+1] = "흑자 운영" end
	if D.immediate >= 2 then p[#p+1] = "국경 다전선 압박"
	elseif D.immediate == 1 then p[#p+1] = "국경 교전"
	elseif D.wars > 0 then p[#p+1] = "원거리 전쟁만"
	else p[#p+1] = "국경 평온" end
	if D.density < 1 and num(S.regions, 0) > 0 then p[#p+1] = "군대 얇음" end   -- v39: 영토 0은 얇음이 아님
	return table.concat(p, " · ")
end

-- ── 전략 국면 진단(② → v38 보간) — if-else 사다리 대신 소속도(membership) ──
-- 체스 tapered eval 유비(문서1): 국면별 소속도를 연속값으로 매겨 최댓값을 주 국면으로,
-- 0.45 이상의 차점을 "조짐"으로 병기 → 경계에서 조언이 급변하지 않고 복합 국면 표현.
-- 소속도는 구 사다리 조건을 연속화한 것(회귀 테스트 6종으로 라벨 보존 검증).
local function diagnose(S, D)
	local regions = num(S.regions, 0)
	local field   = num(S.generals, 0)
	local nsiege  = (S.threats and #S.threats.sieges) or 0
	local buffer  = D.buffer or 999
	local turn    = num(S.turn, 99)
	local A = {}
	local function put(label, m, note) if m > 0 then A[#A + 1] = { label = label, m = m, note = note } end end
	local mj = 0
	if nsiege > 0 then mj = 1 elseif D.immediate >= 3 then mj = 0.8 elseif D.immediate == 2 then mj = 0.35 end
	put("궁지", mj, "포위·다전선으로 수세에 몰렸습니다. 전선을 줄이고 핵심 영토 사수에 집중하세요")
	if regions >= 5 and field > 0 then
		local mo = clamp((regions / field - 3) / 2, 0, 1) * ((D.immediate >= 2) and 1 or 0.4)
		put("과확장", mo, "영토에 비해 군대가 얇고 다전선입니다. 확장을 멈추고 통합·방어를 우선하세요")
	end
	if D.money_trouble then
		-- v53: 적자만이 아니라 '국고가 비었음'도 위기다. 장부상 +55라도 금고에
		--   7골드뿐이면 한 번의 지출로 무너진다(42턴 벨라코르 실측).
		put("재정 위기", clamp((4 - buffer) / 3, 0, 1),
			D.deficit and "적자로 곧 자금이 바닥납니다. 군대 감축이나 수입 확충이 시급합니다"
			          or "국고가 비었습니다. 장부는 흑자여도 지출 한 번에 무너집니다. 여유분부터 만드세요")
	end
	if D.immediate == 0 and D.net > 0 then
		put("성장 정체", clamp((buffer - 12) / 8, 0, 1), "평온하나 금고만 쌓였습니다. 재투자·확장으로 우위를 굴리세요")
		put("성장기", 0.6, "평온+흑자, 우위를 확보할 적기입니다. 경제와 영토를 키우세요")
	end
	put("초반 정착", clamp((11 - turn) / 10, 0, 1), "기반을 다지는 시기입니다. 인접 약체 흡수와 경제 기틀을 우선하세요")
	if D.wars > 0 then
		put("소모전", 0.4, "전쟁이 이어지나 전선은 관리되고 있습니다. 결정적 지점에 전력을 모으세요")
	end
	put("안정", 0.2, "큰 위협은 없습니다. 다음 목표를 정해 주도적으로 움직이세요")
	table.sort(A, function(a, b) return a.m > b.m end)
	local top = A[1]
	local second = nil
	if A[2] and A[2].m >= 0.45 and A[2].label ~= "안정" and A[2].label ~= "성장기" then
		second = A[2].label
	end
	return { label = top.label, note = top.note, m = top.m, second = second }
end

-- ── 브리핑 조립(다양한 오프너 + 랭킹 조언) ──────────────────────────
local OPENERS = { "전략 브리핑", "현황 분석", "참모 보고", "정세 판단", "전황 점검", "국면 진단", "정세 브리핑", "전략 평가" }

local function build_briefing(S, D, cand, prof)
	g_click = g_click + 1
	local opener = OPENERS[(g_click - 1) % #OPENERS + 1]
	local buffer_str = (D.buffer_known == false) and "미상(수입 0)"          -- v40: 센티넬을 '충분'으로 읽지 않기
		or ((D.buffer >= 999) and "충분" or string.format("%.1f턴", D.buffer))
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
	if S.proj then   -- v37 전방 투영(외삽)
		local parts = { string.format("턴당 %+d(%s) → 3턴 뒤 국고 ~%d", math.floor(S.proj.rate + 0.5), S.proj.src, S.proj.t3) }
		if S.proj.broke then parts[#parts+1] = "국고 마이너스"
		elseif S.proj.runway == 0 then parts[#parts+1] = "이번 턴 고갈"
		elseif S.proj.runway then parts[#parts+1] = string.format("고갈 ~%d턴", S.proj.runway) end
		if S.proj.rival_cross then parts[#parts+1] = string.format("라이벌 2배 교차 ~%d턴", S.proj.rival_cross) end
		L[#L+1] = "🔮 투영: " .. table.concat(parts, " · ")
	end
	L[#L+1] = "🩺 수집상태: " .. ((S.health and #S.health > 0) and ("실패=" .. table.concat(S.health, ",") .. " — 해당 영역 판단 보류") or "전 섹션 정상")
	if S.capped and #S.capped > 0 then
		L[#L+1] = "🔎 스캔 상한 도달: " .. table.concat(S.capped, ",") .. " — 뒤쪽은 못 봤습니다(없는 게 아니라 안 본 것)"
	end
	L[#L+1] = "▶ 종합: " .. overall(S, D)
	do
		local dg = diagnose(S, D)
		if dg then L[#L+1] = "◆ 국면: " .. dg.label .. (dg.second and (" (겸 " .. dg.second .. ")") or "") .. " — " .. dg.note end
	end
	local Tset = (S.threats and S.threats.settle) or {}
	if S.threats and (#S.threats.sieges > 0 or #S.threats.threatened > 0 or #S.threats.targets > 0 or #Tset > 0) then
		local parts = {}
		-- v40: 대제국 후반에 한 줄이 수백 항목으로 부푸는 것 방지 — 8개 + "외 N".
		local function cap(list, n, fmt)
			local o = {}
			for i = 1, math.min(#list, n) do o[#o+1] = fmt(list[i]) end
			if #list > n then o[#o+1] = string.format("외 %d", #list - n) end
			return table.concat(o, ",")
		end
		if #S.threats.sieges > 0 then
			parts[#parts+1] = "포위=" .. cap(S.threats.sieges, 8, function(k) return region_disp(k) end)
		end
		if #S.threats.threatened > 0 then
			parts[#parts+1] = "위협=" .. cap(S.threats.threatened, 8, function(a) return region_disp(a.region) .. (a.defended and "(방어됨)" or "(무방비)") end)
		end
		if #S.threats.targets > 0 then
			parts[#parts+1] = "표적=" .. cap(S.threats.targets, 8, function(t) return region_disp(t.region) .. (t.near and "(근접)" or "") end)
		end
		if #Tset > 0 then   -- v40: 영토0 앵커 스캔 결과(첫 정착지 후보)
			parts[#parts+1] = "정착후보=" .. cap(Tset, 5, function(c) return region_disp(c.region) .. (c.at_war and "" or "(비전시)") end)
		end
		L[#L+1] = "⚔ 지도: " .. table.concat(parts, " · ")
	end
	if S.diplo and (#S.diplo.peace > 0 or #S.diplo.ally > 0) then
		local dp = {}
		if #S.diplo.peace > 0 then dp[#dp+1] = "화친가능=" .. first_names(S.diplo.peace, 3) end
		if #S.diplo.ally > 0 then dp[#dp+1] = "동맹가능=" .. first_names(S.diplo.ally, 3) end
		L[#L+1] = "🤝 외교: " .. table.concat(dp, " · ")
	end
	if S.strat and (S.strat.enemy or S.strat.hostile) then   -- v36 CAI 정찰(디버그 가시성)
		local cs = {}
		for k, e in pairs(S.strat.enemy or {}) do
			if e.war_chest ~= nil then cs[#cs+1] = string.format("%s군비%d", fname(k), e.war_chest) end
		end
		for _, h in ipairs(S.strat.hostile or {}) do cs[#cs+1] = string.format("적대이웃 %s(%d)", fname(h.key), h.stance) end
		if #cs > 0 then L[#L+1] = "🎯 CAI 정찰: " .. table.concat(cs, " · ") end
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
local PROSE_OPEN = { "정세를 보면", "현 상황을 정리하면", "참모의 판단으로는", "전황을 짚어보면", "보고드리자면", "냉정히 보면", "종합하면" }
local PROSE_MAX  = 13   -- 패널 산문 목표 총량(정보 예산). A+U(계획·국면·정세·긴급)는 열외, N·F부터 탈락.
-- ※ PROSE_CONN(접속부사 풀)과 urgency(점수→시급도 문구)는 제거했다. v32에서 산문이
--   계획 엔진 주도로 바뀌면서 둘 다 호출부가 사라졌는데 선언만 남아 있었다(v40 리뷰에서
--   지적됐던 것). 문장 접속은 join_clauses가, 우선순위는 계획 단계가 맡는다.

-- ── 절 병합(aggregation, v35 — 문서2 §B·C) ──────────────────────────
-- 사실들을 한 문장으로: 같은 극성은 병렬(이고→이며 교대), 극성 전환은 딱 한 번 '이나'로 신호.
-- 종류: n=명사술어(이고/이며/이나/입니다), v=받침 용언어간 전용(고/으며/으나/습니다), h=하다(하고/하며/하나/합니다).
local CLAUSE_END = {
	n = { a1 = "이고", a2 = "이며", bt = "이나", fi = "입니다" },
	v = { a1 = "고",   a2 = "으며", bt = "으나", fi = "습니다" },
	h = { a1 = "하고", a2 = "하며", bt = "하나", fi = "합니다" },
}
local function clause(body, kind, pol)
	return { body = body, e = CLAUSE_END[kind] or CLAUSE_END.n, pol = pol or 1 }
end
local function join_clauses(cs)
	if #cs == 0 then return "" end
	local pos, neg = {}, {}
	for _, c in ipairs(cs) do
		if (c.pol or 1) >= 0 then pos[#pos + 1] = c else neg[#neg + 1] = c end
	end
	local function chain(list, tail)   -- a1/a2 교대로 잇고 마지막만 tail 어미
		local parts = {}
		for i = 1, #list do
			local c = list[i]
			if i < #list then parts[#parts + 1] = c.body .. ((i % 2 == 1) and c.e.a1 or c.e.a2)
			else parts[#parts + 1] = c.body .. c.e[tail] end
		end
		return table.concat(parts, " ")
	end
	if #neg == 0 then return chain(pos, "fi") end
	if #pos == 0 then return chain(neg, "fi") end
	return chain(pos, "bt") .. ", " .. chain(neg, "fi")   -- 긍정 병렬 →(전환 1회)→ 부정 병렬
end

local plan_prose_lines   -- 전방 선언(전략 2.0 — 실제 정의는 아래 계획 엔진 섹션; upvalue 바인딩)

local function build_prose(S, D, cand, prof)
	local race = (prof and prof.race and prof.race ~= "(일반)") and prof.race or fname(S.faction)
	local rot = function(t) return t[(g_click - 1) % #t + 1] end
	-- ── 정보 예산(가독성 v32): A=항상, U=긴급(예산 열외), N=일반, F=플레이버 ──
	-- 목표 총량 PROSE_MAX줄. A+U는 자르지 않음(긴급을 숨기지 않는 정직 설계) →
	-- 넘치면 N 뒤쪽·F부터 탈락. "12가지 말고 3가지" 원칙의 규칙 구현.
	local A, U, N, F = {}, {}, {}, {}
	-- 계획이 이미 다루는 대상(팩션 키) — 하위 줄 중복 억제(같은 사실 재방송 방지)
	local covered = {}
	if S.plan then for _, st in ipairs(S.plan.steps or {}) do
		if st.key then covered[st.key] = true end
		if st.kind == "posture" and st.key == "settle" then   -- v40: 계획 ①이 지목한 정착 후보의 소유주도 커버
			local c = pick_settle(S.threats and S.threats.settle)
			if c and c.owner then covered[c.owner] = true end
		end
	end end
	-- A: 전략 계획(2.0) — "앞으로 무엇을"의 직답
	for _, l in ipairs(plan_prose_lines(S)) do A[#A+1] = l end
	-- A: 전략 국면(②) — v37: 재정위기면 활주로 외삽(몇 턴 뒤 고갈)을 수치로 덧붙임
	local dg = diagnose(S, D)
	if dg then
		local extra = ""
		if dg.label == "재정 위기" then
			local rp = runway_phrase(S.proj)   -- v40: 음수 국고·0턴도 정직하게(구버전은 "~-3턴 내 고갈")
			if rp then extra = " " .. rp .. "." end
		end
		local sec = dg.second and string.format(" %s 조짐도 겹쳐 있습니다.", dg.second) or ""
		A[#A+1] = string.format("【국면 · %s】 %s.%s%s", dg.label, dg.note, extra, sec)
	end
	-- A: 정세 도입 — 절 병합(v35): 경제·수입추세·국경위협을 한 문장으로. 대조는 '이나' 한 번만(남발 금지).
	local cls = {}
	local eco_pol = D.money_trouble and -1 or 1
	if D.deficit then cls[#cls + 1] = clause("재정은 적자라 주의가 필요", "h", -1)
	elseif D.cash_low then
		-- v53: 장부는 흑자인데 금고가 빈 상태. "흑자"로 시작하면 안심시키는 문장이 된다.
		local tv = tostring(num(S.treasury, 0))
		cls[#cls + 1] = clause(string.format("국고가 %s%s 사실상 비어 있", tv, josa_ro(tv)), "v", -1)
	elseif D.net > 0 then
		local nv = tostring(num(S.net, 0))
		cls[#cls + 1] = clause(string.format("재정은 순 +%s%s 흑자", nv, josa_ro(nv)), "n", 1)
	else cls[#cls + 1] = clause("재정은 대체로 균형", "n", 1) end
	if S.trend and S.trend.income ~= 0 then   -- 수입 추세를 정세 문장에 흡수(별도 줄 대신)
		local tp = (S.trend.income > 0) and 1 or -1
		local subj = (tp == eco_pol) and "수입도" or "수입은"   -- 같은 방향일 때만 '도'
		cls[#cls + 1] = clause(subj .. ((tp > 0) and " 오르는 추세" or " 꺾이는 추세"), "n", tp)
	end
	if num(S.regions, 0) == 0 then   -- v40: 영토가 없으면 '국경 평온'은 공허한 참 — 실상을 말한다
		cls[#cls + 1] = clause("아직 정착지가 없어 지킬 국경도 없", "v", -1)
	elseif D.immediate >= 2 then cls[#cls + 1] = clause("국경에서 여러 세력의 압박을 받고 있", "v", -1)
	elseif D.immediate == 1 then cls[#cls + 1] = clause(string.format("국경에서 %s의 압박을 받고 있", tostring(S.war_names[1] or "적")), "v", -1)
	elseif D.wars > 0 then cls[#cls + 1] = clause("전쟁 중에도 국경은 아직 평온", "h", 1)
	else cls[#cls + 1] = clause("국경은 평온", "h", 1) end
	A[#A+1] = string.format("%s, %s%s %s턴 현재 %s.", rot(PROSE_OPEN), race, josa(race, "은", "는"), tostring(num(S.turn, "?")), join_clauses(cls))
	-- U: 데이터 신뢰성(v35 — 문서1 0순위): 수집 실패를 '평온'으로 위장하지 않는다.
	if S.health and #S.health > 0 then
		U[#U+1] = string.format("⚠ 데이터 — 이번 클릭에 %s 정보를 읽지 못했습니다. 해당 영역은 판단을 보류합니다(조용함≠안전).", table.concat(S.health, "·"))
	end
	-- U: 재정 활주로(v37 외삽) — 국면이 이미 재정위기로 말한 경우는 제외(중복 방지)
	if S.proj and (S.proj.broke or (S.proj.runway and S.proj.runway <= 3)) and (not dg or dg.label ~= "재정 위기") then
		U[#U+1] = string.format("재정 — %s(턴당 %+d). 지출을 줄이거나 수입을 확보하세요.",
			runway_phrase(S.proj, true), math.floor(S.proj.rate + 0.5))
	end
	-- U/N: 위협(모듈1) — 포위·무방비=긴급. 방어된 위협은 계획 미커버 대상만(중복 억제).
	if S.threats then
		local Tt = S.threats
		if Tt.sieges and #Tt.sieges > 0 then
			local ns = {}
			for _, k in ipairs(Tt.sieges) do ns[#ns + 1] = region_disp(k) end
			U[#U+1] = string.format("긴급 — 포위된 정착지: %s. 구원군을 급파하거나 농성으로 버티세요.", table.concat(ns, ", "))
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
			U[#U+1] = string.format("위협 — %s 인근에 %s 야전군이 있는데 근처 아군이 없습니다. 회군하거나 증원하세요.", region_disp(undef[1].region), fname(undef[1].faction))
		elseif #defo > 0 and not covered[defo[1].faction] then
			N[#N+1] = string.format("위협 — %s 인근에 %s 야전군이 있으나 아군이 대응 가능한 위치입니다. 요격을 검토하세요.", region_disp(defo[1].region), fname(defo[1].faction))
		end
	end
	-- U/N: 스노우볼(⑥) — 압도=긴급, 급성장 주시=일반
	if S.snowball then
		local g = S.rival_growth
		local fastgrow = g and g.dt >= 2 and g.growth >= 3
		if S.snowball.dominant then
			local extra = fastgrow and string.format(" 게다가 최근 %d턴간 영토 +%s 급성장 중입니다.", g.dt, nro(g.growth)) or ""
			U[#U+1] = string.format("경계 — %s가 압도적으로 커졌습니다(영토 %d).%s 방치하면 손쓸 수 없습니다. 견제하거나 대항 동맹을 규합하세요.", fname(S.snowball.key), S.snowball.regions, extra)
		elseif fastgrow then
			local cross = (S.proj and S.proj.rival_cross) and string.format(" 이 추세면 ~%d턴 뒤 우리의 2배 규모가 됩니다.", S.proj.rival_cross) or ""
			N[#N+1] = string.format("주시 — %s가 최근 %d턴간 영토 +%s 급성장 중입니다(현재 %d).%s 커지기 전에 견제를 고려하세요.", fname(S.snowball.key), g.dt, nro(g.growth), S.snowball.regions, cross)
		end
	end
	-- N: 비전시 이웃 적대 스탠스(v36, CAI 실측) — 선전포고 조기 경보
	if S.strat and S.strat.hostile and #S.strat.hostile > 0 then
		local h = S.strat.hostile[1]
		local hn = fname(h.key)
		N[#N+1] = string.format("경계 — 이웃 %s%s 전쟁 전인데도 우리를 적대시하고 있습니다(CAI 스탠스 %d). 국경 방비를 갖추거나 관계 개선·선제 중 하나를 준비하세요.", hn, josa(hn, "이", "가"), h.stance)
	end
	-- U/N: 반란(임박=긴급)/내정 주의(④) — v35: 치안+타락 동시면 한 문장으로 병합(aggregation)
	local corr_used = false
	if S.province and #S.province.unrest > 0 then
		local worst = S.province.unrest[1]
		for _, u in ipairs(S.province.unrest) do if u.po < worst.po then worst = u end end
		if worst.po <= -50 then
			U[#U+1] = string.format("반란 위험 — %s의 공공질서가 %s 붕괴 직전입니다. 주둔군 강화나 억압으로 진정시키세요.", region_disp(worst.region), nro(worst.po))
		else
			local c = S.province.corruption
			if c then
				corr_used = true
				if c.region == worst.region then
					N[#N+1] = string.format("내정 — %s 치안이 %s 낮고 %s 타락도 %d%%에 달합니다. 방치하면 반란과 수입 악화로 이어집니다.",
						region_disp(worst.region), nro(worst.po), c.label, math.floor(c.value))
				else
					N[#N+1] = string.format("내정 — %s 치안이 %s 낮고, %s엔 %s 타락이 %d%%입니다. 방치하면 반란과 수입 악화로 이어집니다.",
						region_disp(worst.region), nro(worst.po), region_disp(c.region), c.label, math.floor(c.value))
				end
			else
				N[#N+1] = string.format("내정 주의 — %s의 공공질서가 %s 낮습니다. 방치하면 반란으로 이어집니다.", region_disp(worst.region), nro(worst.po))
			end
		end
	end
	-- U/N: 종족 자원(①) — 긴급 임계면 승격. max(상한, db 실측)가 있으면 비율 표시.
	if S.resource then
		local vtxt = S.resource.max and string.format("%d/%d", math.floor(S.resource.value), S.resource.max)
			or tostring(math.floor(S.resource.value))
		-- 템플릿 대시와 이중 방지: 문장 종결("…다") 뒤 대시는 마침표로, 그 외는 쉼표로
		local note = (tostring(S.resource.note):gsub("다 — ", "다. "):gsub(" — ", ", "))
		local line = string.format("%s %s — %s.", S.resource.label, vtxt, note)
		if S.resource.urgent then U[#U+1] = line else N[#N+1] = line end
	end
	-- N: 추세(영토만 — 수입 추세는 정세 문장에 병합 v35, 정체는 무정보라 생략)
	if S.trend and S.trend.regions ~= 0 then
		N[#N+1] = string.format("최근 %d턴 사이 영토가 %s.", S.trend.dt, (S.trend.regions > 0) and "늘었습니다" or "줄었습니다")
	end
	-- N: 보강 1건 — 계획(군사/확장)·전용줄(외교)과 겹치지 않는 축만.
	--   경제/기술은 항상 후보, 방어는 긴급(U)이 비었을 때만(긴급 줄과 중복 방지).
	--   v39: 문제형(issue) 근거 우선 — 기회 설명뿐이면 라벨을 '기회'로(보강≠기회 구분).
	for i = 1, #cand do
		local c = cand[i]
		if c.key == "economy" or c.key == "tech" or (c.key == "defense" and #U == 0) then
			local r1 = c.issue or (c.reasons and c.reasons[1])
			if r1 and r1 ~= "" then
				N[#N+1] = string.format("%s — %s: %s.", c.issue and "보강" or "기회", c.label, (tostring(r1):gsub(" — ", ", ")))
			end
			break
		end
	end
	-- N: 확장 기회(모듈3) — 계획 미커버 대상만 + 기후 게이트(v33: 적합 우선, 부적합뿐이면 약탈 권고)
	if S.threats and S.threats.targets then
		local pick, fallback
		for _, t in ipairs(S.threats.targets) do
			if t.near and not covered[t.owner] then
				if t.suit ~= "suitability_verypoor" then pick = t; break
				elseif not fallback then fallback = t end
			end
		end
		local nt = pick or fallback
		if nt then
			if nt.suit == "suitability_verypoor" then
				N[#N+1] = string.format("확장 주의 — 인근 공격 가능지 %s(%s)는 기후 부적합입니다. 점령보다 약탈·파괴를 권합니다.", region_disp(nt.region), fname(nt.owner))
			else
				N[#N+1] = string.format("확장 기회 — 내 군대 인근의 공격 가능 정착지: %s(%s). 여력이 되면 공략을 검토하세요.", region_disp(nt.region), fname(nt.owner))
			end
		end
	end
	-- N: 턴 마무리 점검(v33) — 일부만 움직였고 야전 대기 미이동 군단이 남았을 때만(턴 초 소음 방지)
	if S.strat and S.strat.armies and #S.strat.armies >= 2 then
		local spent, idle = false, 0
		for _, a in ipairs(S.strat.armies) do
			if a.ap and a.ap <= 20 then spent = true end
			if a.ap and a.ap >= 60 and a.in_open then idle = idle + 1 end
		end
		if spent and idle > 0 then
			N[#N+1] = string.format("이동력 — 야전 대기 중인 미이동 군단 %d개. 턴 종료 전 활용하세요.", idle)
		end
	end
	-- N: 외교(모듈4) — 계획과의 일관성(제거=모순 문구, 화친 단계=무언 흡수).
	--   v35: 화친·동맹이 동시에 가능하면 두 줄 대신 한 문장으로 병합(aggregation).
	if S.diplo then
		local peace_names, trade_name = nil, nil
		if #S.diplo.peace > 0 then
			local elim_key, sup = nil, {}
			if S.plan then
				for _, st in ipairs(S.plan.steps or {}) do
					if st.kind == "elim" and st.key then if not elim_key then elim_key = st.key end; sup[st.key] = true
					elseif st.kind == "peace" and st.key then sup[st.key] = true end
				end
			end
			local show = {}
			for _, k in ipairs(S.diplo.peace) do if not sup[k] then show[#show + 1] = k end end
			if #show > 0 then
				peace_names = first_names(show, 2)
			elseif elim_key and sup[elim_key] then
				for _, k in ipairs(S.diplo.peace) do if k == elim_key then trade_name = fname(elim_key) end end
			end
		end
		local ally_names = (#S.diplo.ally > 0) and first_names(S.diplo.ally, 2) or nil
		if peace_names and ally_names then
			N[#N+1] = string.format("외교 — %s%s는 화친이, %s%s는 군사동맹이 성사 가능합니다. 전선을 줄이고 뒷배를 얻을 기회입니다.",
				peace_names, josa(peace_names, "과", "와"), ally_names, josa(ally_names, "과", "와"))
		elseif trade_name and ally_names then
			N[#N+1] = string.format("외교 — %s%s의 화친도 성사 가능하나 계획상 제거가 우선입니다. 한편 %s%s는 군사동맹이 가능하니 제안을 검토하세요.",
				trade_name, josa(trade_name, "과", "와"), ally_names, josa(ally_names, "과", "와"))
		elseif peace_names then
			N[#N+1] = string.format("외교 — 화친이 성사 가능한 상대: %s. 전선을 줄이려면 제안하세요.", peace_names)
		elseif trade_name then
			N[#N+1] = string.format("외교 — %s%s의 화친도 성사 가능하나, 계획상 제거가 우선입니다. 전황이 급하면 화친으로 전선을 줄이는 선택도 유효합니다.", trade_name, josa(trade_name, "과", "와"))
		elseif ally_names then
			N[#N+1] = string.format("외교 — 군사동맹이 가능한 상대: %s. 제안을 검토하세요.", ally_names)
		end
	end
	-- N: 연구(모듈2) / 타락(④)
	if S.research_idle == true then
		N[#N+1] = "연구가 지정되지 않았습니다. 기술을 골라 착수하세요."
	end
	if S.province and S.province.corruption and not corr_used then
		local c = S.province.corruption
		N[#N+1] = string.format("타락 주의 — %s에 %s 타락이 %d%%입니다. 통제·수입에 악영향이니 정화를 고려하세요.", region_disp(c.region), c.label, math.floor(c.value))
	end
	-- F: 군주 → 진영 팁(예산이 남을 때만; 군주 우선 생존)
	if S.leader_key and prof and prof.lords and prof.lords[S.leader_key] then
		local lord = prof.lords[S.leader_key]
		F[#F+1] = string.format("%s: %s.", tostring(lord.name or "군주"), tostring(lord.note or ""))
	end
	if prof and prof.tips and #prof.tips > 0 then
		F[#F+1] = string.format("%s답게, %s.", race, tostring(prof.tips[g_click % #prof.tips + 1]))
	elseif prof and prof.sig and prof.sig.note then
		F[#F+1] = string.format("%s답게, %s.", race, prof.sig.note)
	end
	-- 조립: A+U 전량 → N은 잔여 예산 → F는 그래도 남으면
	local P = {}
	for _, l in ipairs(A) do P[#P+1] = l end
	for _, l in ipairs(U) do P[#P+1] = l end
	local budget = PROSE_MAX - #P
	for _, l in ipairs(N) do if budget > 0 then P[#P+1] = l; budget = budget - 1 end end
	for _, l in ipairs(F) do if budget > 0 then P[#P+1] = l; budget = budget - 1 end end
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

-- ── 전방 투영(v37, 문서1 2순위) — 얕은 추세 외삽 ─────────────────────
-- 게임 시뮬레이션이 아니라 '수집한 추세의 선형 외삽'. 정확한 예측이 아닌
-- 방향 비교용 → 문구에 반드시 "이 추세면"을 붙여 외삽임을 정직하게 명시.
local function project(S)
	local P = {}
	local g = num(S.treasury, 0)
	-- 재정 턴당 변화: 히스토리 실측 우선(이벤트·유지비 변화 반영), 폴백=현재 순수입
	local rate, src = num(S.net, 0), "순수입 기준"
	if S.trend and S.trend.dt and S.trend.dt >= 1 then
		rate = S.trend.treasury / S.trend.dt
		src = string.format("최근 %d턴 실측", S.trend.dt)
	end
	P.rate, P.src = rate, src
	P.t3 = math.floor(g + rate * 3 + 0.5)             -- 3턴 뒤 국고(외삽)
	-- 활주로: 이 추세로 버티는 턴 수. v40 — 이미 마이너스면 '몇 턴 뒤 고갈'이 성립하지 않고
	--   (구버전은 "~-3턴 내 고갈"을 출력), 1턴 미만이면 0으로 두고 소비처에서 "이번 턴" 문구로.
	if rate < -1 then
		if g <= 0 then P.broke = true else P.runway = math.floor(g / -rate) end
	end
	-- 라이벌 2배 교차: 라이벌·내 영토 증가율로 "우리의 2배가 되는 시점" 외삽
	if S.snowball and S.rival_growth and S.rival_growth.dt and S.rival_growth.dt >= 2 then
		local rr = S.rival_growth.growth / S.rival_growth.dt
		local mr = (S.trend and S.trend.dt and S.trend.dt >= 1) and (S.trend.regions / S.trend.dt) or 0
		local my, rv = num(S.regions, 0), num(S.snowball.regions, 0)
		local den = rr - 2 * mr
		if den > 0.05 and rv < 2 * my then
			local t = (2 * my - rv) / den
			if t >= 1 and t <= 20 then P.rival_cross = math.ceil(t) end
		end
	end
	return P
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
	ST.ok = pcall(function()
		local f = cm:get_local_faction(true)
		if not f then error("팩션 조회 실패") end   -- v35: 조용한 return 대신 실패로 기록
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
		-- CAI 정찰(v36, 인게임 실측 확정): 스탠스·즉시 군비 — 반드시 '팩션 키 문자열' 인자.
		--   실측: 키 인자만 실값(전쟁상대 -2/중립 0, 군비 1964 등), 객체·cqi 인자는 0(미해석).
		local ai = nil
		pcall(function()
			local a = cm:model():campaign_ai()
			if a and not a:is_null_interface() then ai = a end
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
						if ai then   -- v36: 적 군비 여력(소모전 판단용)
							pcall(function() e.war_chest = ai:funds_available_for_immediate_payment_for_faction_by_area(k, "ARMIES") end)
						end
						pcall(function()   -- 야전 전력 합(승산 판단용) — mf:strength() 실측 API
							local el = ef:military_force_list(); local en = el:num_items()
							local s2 = 0
							for j = 0, math.min(en, 15) - 1 do
								local mf2 = el:item_at(j)
								local okf = false
								pcall(function() okf = mf2:has_general() and not mf2:is_armed_citizenry() end)
								if okf then pcall(function() s2 = s2 + (mf2:strength() or 0) end) end
							end
							if s2 > 0 then e.strength = s2 end
						end)
						ST.enemy[k] = e
					end
				end)
			end
		end
		-- 비전시 이웃의 적대 스탠스 감시(v36) — 선전포고 조기 경보(실측: 음수=적대, 0=중립)
		if ai then
			ST.hostile = {}
			for i = 1, math.min(#(S.border_others or {}), 8) do
				local k = S.border_others[i]
				local st = nil
				pcall(function() st = ai:strategic_stance_between_factions(k, S.faction) end)
				if type(st) == "number" and st < 0 then
					ST.hostile[#ST.hostile + 1] = { key = k, stance = st }
				end
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
					local a = { units = 0, art = 0, ranged = 0, combat = 0 }
					pcall(function()
						local ul = mf:unit_list(); local un = ul:num_items()
						a.units = un
						local sum, cnt = 0, 0
						for j = 0, math.min(un, 25) - 1 do
							local u = ul:item_at(j)
							pcall(function()   -- 완전 어휘(unit_class db 실측 18종) 기반 분류
								local ucl = u:unit_class()
								if ucl == "art_fld" or ucl == "art_fix" or ucl == "art_siege" then a.art = a.art + 1 end
								if ucl == "inf_mis" or ucl == "cav_mis" or ucl == "art_fld" or ucl == "art_fix" or ucl == "art_siege" then a.ranged = a.ranged + 1 end
								if ucl ~= "com" then a.combat = a.combat + 1 end
							end)
							pcall(function()
								local p = u:percentage_proportion_of_full_strength()
								if p then sum = sum + p; cnt = cnt + 1 end
							end)
						end
						if cnt > 0 then a.avg = math.floor(sum / cnt + 0.5) end
					end)
					pcall(function()   -- 이동력·야전 대기(턴 마무리 점검용)
						local ch = mf:general_character()
						pcall(function() a.ap = ch:action_points_remaining_percent() end)
						pcall(function()
							a.in_open = ch:has_region() and (not ch:is_at_sea()) and (not ch:in_settlement())
								and (not ch:is_besieging()) and (not ch:is_embedded_in_military_force())
						end)
					end)
					pcall(function()
						local loc = common.get_localised_string(mf:general_character():get_forename())
						if loc and loc ~= "" then a.name = loc end
					end)
					pcall(function() a.str = mf:strength() end)
					if a.str then ST.my_strength = (ST.my_strength or 0) + a.str end
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

-- ── 계획 생성(순수) — 상황 판단: 생존 국면=화친 우선, 건재=제거 우선 ──
-- 단계: ①군사(peace 또는 elim) ②속주 완성 ③대비/자세. 최대 3단계.
local function plan_generate(S, dglabel)
	local steps, ST = {}, S.strat or {}
	-- v39: 영토 0(호드 제외) = 무엇보다 첫 거점 — 시작 공성/식민 유도(아콘 등 정착지 없는 출발)
	if num(S.regions, 0) == 0 and S.can_capture ~= false then
		steps[#steps + 1] = { kind = "posture", key = "settle", base = 0, last = 0, created = num(S.turn, 0) }
	end
	-- 생존 국면(궁지/재정위기/과확장): 화친 가능한 적 중 '가장 큰' 상대와 강화 → 최대 위협부터 전선 정리
	local survival = (dglabel == "궁지" or dglabel == "재정 위기" or dglabel == "과확장")
	local peace_key = nil
	if survival then
		local bestp
		for _, k in ipairs((S.diplo and S.diplo.peace) or {}) do
			local e = ST.enemy and ST.enemy[k]
			local r = (e and e.regions) or -1   -- 크기 미상(원거리)은 후순위지만 자격 있음
			if not bestp or r > bestp.r then bestp = { key = k, r = r } end
		end
		if bestp then
			peace_key = bestp.key
			steps[#steps + 1] = { kind = "peace", key = peace_key, base = math.max(bestp.r, 0), last = math.max(bestp.r, 0), created = num(S.turn, 0) }
		end
	end
	-- 군사: 국경 전쟁적 중 잔여 영토 최소(가장 빨리 끝낼 전선). 화친 대상은 제외.
	local best
	for i = 1, #(S.border_enemies or {}) do
		local k = S.border_enemies[i]
		local e = ST.enemy and ST.enemy[k]
		if k ~= peace_key and e and e.regions and e.regions > 0 then
			if not best or e.regions < best.regions then best = { key = k, regions = e.regions } end
		end
	end
	-- 승산 판단(전력 대조): 제거 표적에 야전 전력 열세(<0.8)면 — 이길 수 없는 싸움 대신 강화(화친 가능 시)
	if best and not peace_key and ST.my_strength then
		local es = ST.enemy and ST.enemy[best.key] and ST.enemy[best.key].strength
		if es and es > 0 and (ST.my_strength / es) < 0.8 then
			for _, k in ipairs((S.diplo and S.diplo.peace) or {}) do
				if k == best.key then
					peace_key = best.key
					steps[#steps + 1] = { kind = "peace", key = best.key, base = best.regions, last = best.regions, created = num(S.turn, 0) }
					best = nil
					break
				end
			end
		end
	end
	if best and #steps < 3 then
		steps[#steps + 1] = { kind = "elim", key = best.key, base = best.regions, last = best.regions, created = num(S.turn, 0) }
	end
	-- ② 내정: 미완 속주 중 남은 칸(gap) 최소 → 완성 임박 우선(CA 자체 넛지와 동일 설계).
	--   시너지: 미보유 지역 소유주가 ①의 대상(제거=흡수됨 / 화친=단기 불가)이면 후보 제외.
	local blocked = {}
	if peace_key then blocked[peace_key] = true end
	if best then blocked[best.key] = true end
	local bp
	for _, p in ipairs(ST.provinces or {}) do
		if p.owned and p.total and p.owned < p.total and not (p.miss_owner and blocked[p.miss_owner]) then
			local gap = p.total - p.owned
			if not bp or gap < bp.gap or (gap == bp.gap and p.owned > bp.owned) then
				bp = { key = p.key, gap = gap, owned = p.owned, total = p.total }
			end
		end
	end
	if bp and #steps < 3 then
		steps[#steps + 1] = { kind = "prov", key = bp.key, base = bp.total, last = bp.owned, created = num(S.turn, 0) }
	end
	-- ③ 대비/자세 (상한 3)
	-- v40: 폴백이 국면을 무시하던 결함 수정. 화친 상대가 없거나 적 정보 조회가 실패해 다른 단계가
	--   하나도 안 서면, 파산 직전·수도 포위 상황에서도 "다음 전쟁을 설계"가 나왔다(재현 확인).
	--   생존 국면이면 미래 대비(prep)보다 당면 자세가 먼저다.
	if #steps < 3 then
		local crisis = (dglabel == "재정 위기" and "retrench") or (dglabel == "궁지" and "hold") or nil
		if #steps == 0 and crisis then
			steps[#steps + 1] = { kind = "posture", key = crisis, base = 0, last = 0, created = num(S.turn, 0) }
		elseif ST.endgame and ST.endgame.armed then
			steps[#steps + 1] = { kind = "prep", key = ST.endgame.armed.scenario, base = ST.endgame.armed.turn or 0, last = 0, created = num(S.turn, 0) }
		elseif dglabel == "과확장" then
			steps[#steps + 1] = { kind = "posture", key = "consolidate", base = 0, last = 0, created = num(S.turn, 0) }
		elseif #steps == 0 then
			local key = "tech"
			if num(S.regions, 0) == 0 and S.can_capture == false then key = "raid"   -- 영구 호드(비스트맨 등)
			elseif S.weak_target then key = "expand" end
			steps[#steps + 1] = { kind = "posture", key = key, base = 0, last = 0, created = num(S.turn, 0) }
		end
	end
	return { steps = steps }
end

-- ── 계획 갱신(순수) — 완료 감지 후 재생성 + 기존 단계의 기준선 승계 ──
local function plan_revise(S, dglabel, old)
	local events, ST = {}, S.strat or {}
	for _, s in ipairs((old and old.steps) or {}) do
		if (s.kind == "elim" or s.kind == "peace") and s.key then
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
			-- 승산(전력 대조) 표기 — collect된 야전 전력 비율
			local rl = ""
			do
				local m = ST and ST.my_strength
				local e = ST and ST.enemy and ST.enemy[s.key] and ST.enemy[s.key].strength
				if m and e and e > 0 then
					local r = m / e
					if r >= 1.5 then rl = " · 야전 전력 우위"
					elseif r >= 0.8 then rl = " · 야전 전력 백중"
					else rl = " · 야전 전력 열세 — 요격·증원 먼저" end
				end
			end
			-- v36: 적 즉시 군비(CAI 실측). 유닛 하나 값(<300)도 없으면 재건 불능 → 속전 신호
			local wc = ST and ST.enemy and ST.enemy[s.key] and ST.enemy[s.key].war_chest
			if type(wc) == "number" and wc < 300 then rl = rl .. " · 적 군비 고갈 — 몰아칠 때" end
			-- v37: 진행 속도 외삽 — 시작 이후 정착지 감소 속도로 완료 시점 추정
			local eta = ""
			if s.base and s.last and s.created and num(S.turn, 0) > s.created and s.base > s.last and s.last > 0 then
				local pace = (s.base - s.last) / (num(S.turn, 0) - s.created)
				if pace > 0 then
					local t = math.ceil(s.last / pace)
					if t <= 12 then eta = string.format(" 이 속도면 ~%d턴 내 정리.", t) end
				end
			end
			line = string.format("%s %s 제거 — 잔여 %d정착지(시작 %d)%s%s.%s", NUMS[i], fname(s.key), s.last or 0, s.base or s.last or 0, trend, rl, eta)
			if S.threats and S.threats.targets then
				local nx, nxf
				for _, t in ipairs(S.threats.targets) do
					if t.owner == s.key and t.near then
						if t.suit ~= "suitability_verypoor" then nx = t; break
						elseif not nxf then nxf = t end
					end
				end
				local pt = nx or nxf
				if pt then
					line = line .. string.format(" 다음 수: %s 공략%s.", region_disp(pt.region),
						(pt.suit == "suitability_verypoor") and "(기후 부적합 — 약탈 권장)" or "")
				end
			end
			-- 시너지: 이 팩션이 미완 속주의 소유주면 — 제거가 곧 속주 완성(일석이조)
			for _, p in ipairs((ST and ST.provinces) or {}) do
				if p.miss_owner == s.key and p.owned and p.total and p.owned < p.total then
					line = line .. string.format(" 정리하면 %s 속주 완성(일석이조).", province_disp(p.key))
					break
				end
			end
		elseif s.kind == "peace" then
			local nm = fname(s.key)
			local why = ""
			do
				local m = ST and ST.my_strength
				local e = ST and ST.enemy and ST.enemy[s.key] and ST.enemy[s.key].strength
				if m and e and e > 0 and (m / e) < 0.8 then why = " 야전 전력도 열세입니다." end
			end
			line = string.format("%s 강화 — %s%s 화친해 전선을 줄이세요(성사 가능).%s 지금은 생존과 정비가 우선입니다.", NUMS[i], nm, josa(nm, "과", "와"), why)
		elseif s.kind == "prov" then
			local ptrend = ""
			if s.prev and s.last then
				if s.last > s.prev then ptrend = " — 순항"
				elseif s.last < s.prev then ptrend = " — 후퇴(지역 상실)" end
			end
			line = string.format("%s %s 속주 완성 — %d/%d%s.", NUMS[i], province_disp(s.key), s.last or 0, s.base or 0, ptrend)
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
				settle = "거점 확보 — 아직 정착지가 없습니다. 첫 정착지를 점령해 기반부터 만드세요",
				retrench = "긴축 — 적자를 멈추는 게 먼저입니다. 유지비 큰 군단을 줄이고 불필요한 지출을 정리하세요",   -- v40
				hold = "사수 — 전선을 좁히고 핵심 정착지에 병력을 모아 버티세요",                                    -- v40
				raid = "약탈 — 정착하지 않는 종족입니다. 약탈·파괴로 자금과 성장을 벌어들이세요",                    -- v40
			}
			line = NUMS[i] .. " " .. (m[s.key] or "자세 정비") .. "."
			-- v40: 첫 정착지를 '어디'로 잡을지까지 — 영토0 앵커 스캔 결과에서 지목.
			local c = (s.key == "settle") and pick_settle(S.threats and S.threats.settle) or nil
			if c then
				local tags = {}
				if not c.at_war then tags[#tags + 1] = "점령하려면 선전포고 필요" end
				if c.suit == "suitability_verypoor" then tags[#tags + 1] = "기후 부적합 — 약탈 권장" end
				line = line .. string.format(" 인근 후보: %s(%s)%s.", region_disp(c.region), fname(c.owner),
					(#tags > 0) and (" — " .. table.concat(tags, ", ")) or "")
			end
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
		-- 원거리 비중(v33, 완전 어휘) — 근접 정체성 종족은 제외
		if not S.melee_race then
			local big
			for _, a in ipairs(ST.armies) do
				local n = (a.combat and a.combat > 0) and a.combat or a.units
				if n and n >= 10 then
					local bn = big and (((big.combat and big.combat > 0) and big.combat) or big.units) or -1
					if n > bn then big = a end
				end
			end
			if big then
				local bn = ((big.combat and big.combat > 0) and big.combat) or big.units
				local rr = (big.ranged or 0) / math.max(1, bn)
				if rr < 0.15 then
					parts[#parts + 1] = string.format("%s 군단 원거리 %d%% — 사격 지원 보강 고려", big.name or "주력", math.floor(rr * 100 + 0.5))
				end
			end
		end
		if #parts > 0 then L[#L + 1] = "군단 점검: " .. table.concat(parts, " · ") .. "." end
	end
	return L
end

--[[═════════════════════════════════════════════════════════════════════
  UI 셸 (v41) — 가로 탭 + 본문 + 측정 기반 페이지
  ------------------------------------------------------------------------
  패널 본체는 v11~v18에서 인게임 확인된 경로 그대로:
    root:CreateComponent("UI/Common UI/scripted_subtitles.twui.xml")
    → text_child(본문) / frame_black(배경) · 높이는 TextDimensions+TextYOffset 실측.
  새로 더한 것은 탭 버튼뿐이고, 탭 템플릿은 아직 인게임 미검증이라
  후보를 순서대로 시도해 성공한 이름을 프루프에 남긴다. 전부 실패해도
  본문·메인 버튼은 그대로 동작한다(탭만 사라짐 — 조용한 고장 아님).
═══════════════════════════════════════════════════════════════════════]]
local PANEL_ID   = "advisor_panel"
local TAB_PREFIX = "advisor_tab_"
local NAV_PREV, NAV_NEXT = "advisor_nav_prev", "advisor_nav_next"
-- v41 인게임 결과: square_medium_text_button 성공. 다만 그건 '탭'이 아니라 버튼이라
-- 활성 표시가 안 되고 텍스트 자식(button_txt)까지 있어 라벨이 두 번 그려졌다.
-- v42: 같은 폴더에 실재하는 진짜 탭 템플릿을 앞에 세운다(states에 selected 존재 확인).
local TAB_TEMPLATES = {
	"ui/templates/square_medium_text_tab_toggle",   -- selected/selected_hover 보유 · 텍스트 자식 없음
	"ui/templates/square_medium_text_tab",          -- 같은 계열 · 텍스트 자식 tx
	"ui/templates/square_medium_text_button",       -- v41 인게임 성공 확인(최후 폴백)
}
local LAY = { X = 24, Y = 176, COL = 520, PAD = 18, MAXH = 720, TABH = 30, TABW = 96, GAP = 3 }
-- sink: 라벨을 어디에 쓸지(자식 이름 or false=루트) · sel: selected 상태 지원 여부
-- state0: 비활성 복귀용 최초 상태명 · boxh: 마지막 본문 높이(페이지 버튼 배치에 필요)
local g_ui = { open = false, tab = nil, page = 1, npages = 1, built = false, tmpl = nil, tabs = {},
               sink = nil, sel = nil, state0 = nil, boxh = 0 }

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

local function panel_text()
	local t = nil
	pcall(function() t = find_uicomponent(core:get_ui_root(), PANEL_ID, "text_child") end)
	return t
end

-- 문자열 → 줄 배열. 도메인이 문자열을 돌려줘도 받아주기 위한 것.
local function split_lines(s)
	local L = {}
	if type(s) ~= "string" then return L end
	for line in (s .. "\n"):gmatch("([^\n]*)\n") do L[#L + 1] = line end
	while #L > 0 and L[#L] == "" do L[#L] = nil end
	return L
end

-- 렌더 높이 실측(px). 텍스트를 실제로 넣어보고 잰다 — 글자수로 추정하지 않는다.
--   (한글 폭·자동 줄바꿈 지점을 우리가 모르므로 추정하면 반드시 틀린다.)
local function measure(textc, text)
	local h = nil
	pcall(function()
		textc:ResizeTextResizingComponentToInitialSize(LAY.COL, 4000)   -- 측정용 넉넉한 높이
		textc:SetStateText(text, "")
		local _, th = textc:TextDimensions()
		if th and th > 0 then
			local oyt, oyb = 0, 0
			pcall(function() oyt, oyb = textc:TextYOffset() end)        -- 폰트 상/하 여백(CA 정식 패턴)
			h = th + (oyt or 0) + (oyb or 0)
		end
	end)
	return h
end

-- 쪽 끝에 홀로 남으면 안 되는 줄인가(다음 쪽으로 함께 넘긴다).
--   ① 섹션 헤더 "─ …" — 제목만 남고 내용이 다음 쪽으로 가면 읽히지 않는다
--   ② 번호 항목 "N. …" 바로 뒤에 들여쓴 설명이 오는 경우 — 제목과 설명이 갈린다
--   근거: MAXH를 500으로 강제해 인게임에서 실제로 나눠 봤더니 기타 탭은
--   "─ 지금 할 일"만 1쪽 끝에 남았고, 연구 탭은 "4. 피에 젖은 예복"과
--   그 "티어 1 · 지도 효과 계열" 줄이 쪽 경계로 갈렸다.
local function orphan_at(lines, idx)
	local s = lines[idx]
	if type(s) ~= "string" then return false end
	if s:match("^─") then return true end
	if s:match("^%d+%. ") then
		local nx = lines[idx + 1]
		if type(nx) == "string" and nx:match("^%s") then return true end
	end
	return false
end

-- 페이지 분할. 한 화면에 들어가면 측정 1회로 끝내고, 넘칠 때만 줄 단위로 채운다.
local function paginate(textc, lines)
	local whole = table.concat(lines, "\n")
	if not textc then return { whole } end
	local h = measure(textc, whole)
	if h == nil or h <= LAY.MAXH then return { whole } end   -- 측정 실패 시엔 자르지 않음(잘림 < 통째로)
	local pages, cur = {}, {}
	for i = 1, #lines do
		cur[#cur + 1] = lines[i]
		local hh = measure(textc, table.concat(cur, "\n"))
		if hh and hh > LAY.MAXH and #cur > 1 then
			cur[#cur] = nil
			-- 고아 줄은 최대 2줄까지 같이 넘긴다. 쪽을 비우지는 않는다(#cur > 1).
			local carry, back = { lines[i] }, i - 1
			while #cur > 1 and (i - back) <= 2 and orphan_at(lines, back) do
				table.insert(carry, 1, cur[#cur])
				cur[#cur] = nil
				back = back - 1
			end
			pages[#pages + 1] = table.concat(cur, "\n")
			cur = carry
		end
	end
	if #cur > 0 then pages[#pages + 1] = table.concat(cur, "\n") end
	if #pages == 0 then pages[1] = whole end
	return pages
end

-- 본문 한 페이지를 그린다(정확 높이 → 클리핑·데드스페이스 없음).
local function panel_draw(text)
	pcall(function()
		if not get_panel() then return end
		local root = core:get_ui_root()
		local textc = panel_text()
		if not textc then proof("v41 !!! text_child 못찾음", true); return end
		local bg = find_uicomponent(root, PANEL_ID, "frame_black")   -- 숨겨진 검은 배너 배경
		pcall(function() textc:SetTextHAlign("left") end)
		pcall(function() textc:SetOpacity(255) end)
		local box_h = measure(textc, text) or 600    -- 측정 실패 폴백(넉넉히 — 잘리는 것보다 큰 게 낫다)
		box_h = clamp(box_h, 60, LAY.MAXH + 60)
		g_ui.boxh = box_h                            -- 페이지 버튼을 본문 아래에 붙이려면 필요
		pcall(function() textc:ResizeTextResizingComponentToInitialSize(LAY.COL, box_h) end)
		if bg then
			pcall(function() bg:SetImagePath("ui/skins/default/tooltip_frame.png", 0, false) end)  -- 자막배너→툴팁프레임
			pcall(function() bg:SetCurrentStateImageMargins(0, 16, 20, 16, 20) end)   -- CA 정확 9-slice
			pcall(function() bg:SetCanResizeHeight(true); bg:SetCanResizeWidth(true) end)
			pcall(function() bg:Resize(LAY.COL + LAY.PAD * 2, math.floor(box_h + LAY.PAD * 2)) end)
			pcall(function() bg:SetOpacity(235) end)
			pcall(function() bg:MoveTo(LAY.X, LAY.Y) end)
			pcall(function() bg:SetVisible(true) end)
		end
		pcall(function() textc:MoveTo(LAY.X + LAY.PAD, LAY.Y + LAY.PAD) end)
		pcall(function() textc:SetVisible(true) end)
		-- z-순서: 패널 전체를 topmost(내부는 frame_black<text_child 순 → 텍스트가 배경 위).
		pcall(function() local p = find_uicomponent(root, PANEL_ID); if p then p:RegisterTopMost() end end)
		proof(string.format("v41 본문 표시 col=%d h=%d tab=%s page=%d/%d",
			LAY.COL, box_h, tostring(g_ui.tab), g_ui.page, g_ui.npages), true)
		-- v54: 그린 본문을 그대로 프루프에 남긴다. 지금까지 파일에는 브리핑 산문만
		-- 남아서, 탭이 실제로 뭐라고 조언했는지는 화면을 봐야만 알 수 있었다.
		-- 조언이 '틀린' 결함(v53 국고 7골드에 "흑자 운영")은 전부 텍스트를 읽어서
		-- 잡았다. 탭도 같은 방식으로 검증할 수 있어야 한다.
		proof(string.format("[v54본문 %s %d/%d]\n%s",
			tostring(g_ui.tab), g_ui.page, g_ui.npages, tostring(text)), true)
	end)
end

local function panel_hide()
	pcall(function()
		local root = core:get_ui_root()
		local textc = find_uicomponent(root, PANEL_ID, "text_child")
		local bg = find_uicomponent(root, PANEL_ID, "frame_black")
		if textc then pcall(function() textc:SetVisible(false) end) end
		if bg then pcall(function() bg:SetVisible(false) end) end
	end)
end

-- 버튼 1개 생성(있으면 재사용). 첫 성공 템플릿을 기억해 나머지에 재사용.
local function make_button(id)
	local btn = nil
	pcall(function()
		local root = core:get_ui_root()
		btn = find_uicomponent(root, id)
		if btn then return end
		local addr = nil
		if g_ui.tmpl then
			pcall(function() addr = root:CreateComponent(id, g_ui.tmpl) end)
		else
			for _, t in ipairs(TAB_TEMPLATES) do
				pcall(function() addr = root:CreateComponent(id, t) end)
				if addr then g_ui.tmpl = t; proof("v41 탭 템플릿 채택 = " .. t, true); break end
			end
		end
		if addr then btn = UIComponent(addr) end
	end)
	if btn then pcall(function() btn:SetInteractive(true); btn:SetDisabled(false); btn:RegisterTopMost() end) end
	return btn
end

-- 라벨을 쓸 곳은 '하나'여야 한다. v41은 루트와 자식에 둘 다 써서 인게임에서
-- "대전략 대전략"처럼 두 번 그려졌다(스크린샷 확인). 템플릿에 텍스트 자식이
-- 있으면 그쪽만, 없으면 루트에만 쓴다. 판별은 첫 버튼에서 한 번만.
local TEXT_CHILDREN = { "tx", "button_txt", "dy_text" }
local function label_sink(btn)
	if g_ui.sink == nil then
		g_ui.sink = false
		for _, nm in ipairs(TEXT_CHILDREN) do
			local c = nil
			pcall(function() c = find_uicomponent(btn, nm) end)
			if c then g_ui.sink = nm; break end
		end
		proof("v42 탭 라벨 싱크 = " .. (g_ui.sink and ("자식 " .. g_ui.sink) or "루트"), true)
	end
	if g_ui.sink == false then return nil end
	local c = nil
	pcall(function() c = find_uicomponent(btn, g_ui.sink) end)
	return c
end

-- 텍스트는 '상태별'로 따로 저장된다 — v42 인게임에서 확인: SetState("selected")로
-- 바꾸는 순간 활성 탭 라벨만 사라졌다(그 상태엔 텍스트를 쓴 적이 없으므로).
-- 호버·클릭도 상태를 바꾸니 같은 일이 난다. 그래서 쓸 수 있는 상태 전부에 미리 넣는다.
-- 목록은 square_medium_text_tab_toggle의 states 실측 + 인게임이 알려준 최초상태 active.
local TAB_STATES = { "default", "active", "inactive", "hover", "down", "down_off",
                     "selected", "selected_hover", "selected_down", "selected_down_off", "selected_inactive" }
-- 텍스트를 받는 컴포넌트와 상태를 바꾸는 컴포넌트는 반드시 같아야 한다.
-- 지금 템플릿은 싱크가 루트라 문제가 없지만, 폴백 템플릿(square_medium_text_tab)은
-- 싱크가 자식 tx다 — 그때 부모 상태만 돌리면 자식의 다른 상태는 여전히 빈칸이 된다.
local function write_label(btn, label, st)
	local t = label_sink(btn) or btn
	if st then pcall(function() t:SetState(st) end) end
	pcall(function() t:SetStateText(label, "") end)
	-- 정렬도 '현재 상태의' 설정이라 여기서 같이 넣는다(공식 문서 문구 그대로).
	-- v44 인게임에서 GetTextVAlign()이 "left"(가로값)를 돌려줬다 — 두 함수의 축이
	-- 문서와 어긋나 있다는 뜻이라 어느 쪽이 어느 축이든 결과가 같도록 둘 다 centre로 둔다.
	pcall(function() t:SetTextVAlign("centre") end)
	pcall(function() t:SetTextHAlign("centre") end)
end

local function set_label(btn, label)
	local cur = nil
	pcall(function() cur = btn:CurrentState() end)
	for _, st in ipairs(TAB_STATES) do
		pcall(function() btn:SetState(st) end)   -- 없는 상태면 무시됨(pcall) — 현재 상태에 덧쓸 뿐
		write_label(btn, label, st)
	end
	if cur then pcall(function() btn:SetState(cur) end) end
	pcall(function() btn:SetTooltipText(label, "", true) end)
end

-- 템플릿의 button_flame은 "부모에 마우스가 올라갔을 때"만 켜지도록 짜인 발광
-- 오버레이다(ContextVisibilitySetter, self.ParentContext.IsMouseOver). 그런데
-- 우리 탭은 root 밑에 단독으로 만든 것이라 부모 컨텍스트가 없어 조건이 평가되지
-- 않고 계속 켜져 있다 — 인게임에서 라벨을 가리던 파란 박스가 이것이다.
-- (좌표 역산으로 확인: 22 높이 · dock_offset 0,-6 → 탭 안 y 6~28 위치와 일치)
-- 페이지 버튼 폭은 생성할 때와 배치할 때 두 곳에서 쓰인다 — 한 군데서만 계산한다.
local function nav_w() return math.floor(LAY.TABW * 1.1) end

local function hide_flame(btn)
	local hid = false
	pcall(function()
		local f = find_uicomponent(btn, "button_flame")
		if f then f:SetVisible(false); hid = true end
	end)
	return hid
end

-- 라벨이 실제로 들어갔는지 첫 탭에서 한 번만 되읽는다. 안 들어갔다면 탭 줄이
-- 통째로 빈 칸으로 보이는데 그건 조용한 고장이므로 프루프에 크게 남긴다.
local function verify_label(btn, label)
	local got = nil
	pcall(function() got = (label_sink(btn) or btn):GetStateText() end)
	if got == label then proof("v42 탭 라벨 확인 OK = " .. tostring(got), true)
	else proof(string.format("v42 !!! 탭 라벨 확인 실패 — 기대 '%s' 실제 '%s'", label, tostring(got)), true) end
end

-- 활성 탭 표시: 템플릿에 selected 상태가 있으면 그게 정석이다. 있는지 여부를
-- 짐작하지 않고, SetState 후 CurrentState로 되읽어 확인한다(둘 다 바닐라 실사용 API).
-- 없으면 v41처럼 라벨 접두사로 대신한다.
local function probe_selected(btn)
	if g_ui.sel ~= nil then return g_ui.sel end
	g_ui.sel = false
	pcall(function()
		local before = btn:CurrentState()
		g_ui.state0 = before
		btn:SetState("selected")
		if btn:CurrentState() == "selected" then g_ui.sel = true end
		if before then btn:SetState(before) end
	end)
	proof(string.format("v42 탭 활성표시 = %s (최초상태 %s)",
		g_ui.sel and "selected 상태" or "라벨 접두사", tostring(g_ui.state0)), true)
	return g_ui.sel
end

local function ui_build_tabs(doms)
	if g_ui.built then return end
	pcall(function()
		local root = core:get_ui_root()
		local rw, rh = 1600, 900
		pcall(function()
			local w, h = root:Dimensions()
			if w and w > 0 then rw = w end
			if h and h > 0 then rh = h end
		end)
		g_ui.rh = rh                                        -- 페이지 버튼이 화면 밖으로 나가지 않게
		-- 본문 폭·높이를 화면에서 뽑는다(고정값이면 해상도마다 남거나 잘린다).
		LAY.COL  = clamp(math.floor(rw * 0.34), 460, 720)
		LAY.MAXH = clamp(rh - LAY.Y - 96, 240, 980)         -- 96 = 본문 아래 페이지 버튼 자리
		-- 검증용 강제(DEBUG_FILE에 묶임 → 배포 시 자동 무력화). 낮은 해상도 사용자가
		-- 늘 보게 되는 2쪽 경로를 개발 기기에서 재현하기 위한 것.
		if DEBUG_FILE and DEBUG_MAXH then LAY.MAXH = DEBUG_MAXH end
		-- 탭 줄은 패널 폭에 정확히 맞춘다. v41은 탭 줄이 패널보다 배 가까이 넓어 따로 놀았다.
		local rowW = LAY.COL + LAY.PAD * 2
		local n = #doms
		LAY.TABW = clamp(math.floor((rowW - (n - 1) * LAY.GAP) / n), 52, 160)
		-- 버튼을 먼저 만들고, 손대기 전에 템플릿 자연 높이를 잰다. v42에서 30으로 눌렀더니
		-- 라벨이 프레임 위로 밀려났다 — 실제 상태 블록이 46 높이로 짜여 있기 때문이다.
		local btns = {}
		for _, d in ipairs(doms) do btns[#btns + 1] = { d = d, b = make_button(TAB_PREFIX .. d.id) } end
		local nat_w, nat_h = nil, nil
		if btns[1] and btns[1].b then
			pcall(function() nat_w, nat_h = btns[1].b:Dimensions() end)   -- 상태를 건드리기 전에
			probe_selected(btns[1].b)
		end
		if nat_h and nat_h > 0 then LAY.TABH = clamp(nat_h, 22, 64) end
		local flames = 0
		local y, x = LAY.Y - LAY.TABH - 4, LAY.X
		for _, e in ipairs(btns) do
			local b, d = e.b, e.d
			if b then
				set_label(b, d.title)
				flames = flames + (hide_flame(b) and 1 or 0)
				if #g_ui.tabs == 0 then verify_label(b, d.title) end
				pcall(function() b:SetCanResizeWidth(true); b:SetCanResizeHeight(true) end)
				pcall(function() b:Resize(LAY.TABW, LAY.TABH) end)
				pcall(function() b:MoveTo(x, y) end)
				pcall(function() b:SetVisible(false) end)
				g_ui.tabs[#g_ui.tabs + 1] = { id = d.id, comp = TAB_PREFIX .. d.id, title = d.title }
			end
			x = x + LAY.TABW + LAY.GAP
		end
		-- 페이지 버튼은 탭 줄이 아니라 본문 아래에 둔다(탭 줄 폭을 잡아먹지 않게).
		-- 위치는 본문 높이에 따라 달라지므로 ui_place_nav()에서 매번 다시 잡는다.
		for _, id in ipairs({ NAV_PREV, NAV_NEXT }) do
			local b = make_button(id)
			if b then
				set_label(b, (id == NAV_PREV) and "◀ 이전" or "다음 ▶")
				hide_flame(b)
				pcall(function() b:SetCanResizeWidth(true); b:SetCanResizeHeight(true) end)
				pcall(function() b:Resize(nav_w(), LAY.TABH) end)
				pcall(function() b:SetVisible(false) end)
			end
		end
		-- 실제로 어떻게 잡혔는지 남긴다 — 다음 회차 레이아웃 보정의 유일한 근거.
		local dbg = ""
		pcall(function()
			local b = find_uicomponent(root, TAB_PREFIX .. doms[1].id)
			if b then
				local bw, bh = b:Dimensions()
				local px, py = b:Position()
				-- 두 정렬 게터를 같이 찍는다: v44에서 VAlign이 "left"를 돌려줘
				-- 두 함수의 축이 문서와 어긋난 것으로 보인다. 실제 어느 쪽이 어느 축인지 확인용.
				local va, ha, oyt, oyb, tw2, th2 = "?", "?", nil, nil, nil, nil
				pcall(function() va = tostring(b:GetTextVAlign()) end)
				pcall(function() ha = tostring(b:GetTextHAlign()) end)
				pcall(function() oyt, oyb = b:TextYOffset() end)
				pcall(function() tw2, th2 = b:TextDimensions() end)
				dbg = string.format(" · 탭1 실측 %sx%s @%s,%s 정렬(V=%s H=%s) Y여백 %s/%s 글자 %sx%s",
					tostring(bw), tostring(bh), tostring(px), tostring(py), va, ha,
					tostring(oyt), tostring(oyb), tostring(tw2), tostring(th2))
			end
		end)
		proof(string.format("[v45레이아웃] root=%sx%s COL=%d MAXH=%d 탭 %dx%d(자연 %sx%s) %d개 발광끔 %d개 템플릿=%s%s",
			tostring(rw), tostring(rh), LAY.COL, LAY.MAXH, LAY.TABW, LAY.TABH,
			tostring(nat_w), tostring(nat_h), #g_ui.tabs, flames, tostring(g_ui.tmpl), dbg), true)
	end)
	-- 하나도 못 만들었다면 '만들었다'고 표시하지 않는다 — 다음 클릭에 다시 시도해야
	-- 한 번의 실패로 세션 내내 탭이 사라진 채로 남지 않는다.
	g_ui.built = (#g_ui.tabs > 0)
	if not g_ui.built then proof("v45 !!! 탭을 하나도 만들지 못했습니다 — 다음 클릭에 재시도", true) end
end

local function ui_tabs_visible(vis)
	pcall(function()
		local root = core:get_ui_root()
		for _, t in ipairs(g_ui.tabs) do
			local b = find_uicomponent(root, t.comp)
			if b then pcall(function() b:SetVisible(vis) end) end
		end
		for _, id in ipairs({ NAV_PREV, NAV_NEXT }) do
			local b = find_uicomponent(root, id)
			if b then pcall(function() b:SetVisible(vis and g_ui.npages > 1) end) end
		end
	end)
end

-- 활성 탭 표시. probe_selected가 확인해 준 방식만 쓴다(둘 다 쓰면 v41처럼 겹친다).
local function ui_mark_active()
	pcall(function()
		local root = core:get_ui_root()
		for _, t in ipairs(g_ui.tabs) do
			local b = find_uicomponent(root, t.comp)
			if b then
				if g_ui.sel then
					pcall(function() b:SetState((t.id == g_ui.tab) and "selected" or (g_ui.state0 or "default")) end)
				else
					-- 폴백 경로: set_label은 상태를 전부 순회하므로 싸지 않다.
					-- 표시가 실제로 바뀔 때만 다시 쓴다.
					local want = (t.id == g_ui.tab) and ("▶" .. t.title) or t.title
					if t.shown ~= want then set_label(b, want); t.shown = want end
				end
			end
		end
	end)
end

-- 페이지 버튼을 본문 아래 가운데에 놓는다(본문 높이는 그릴 때마다 바뀐다).
local function ui_place_nav()
	pcall(function()
		local root = core:get_ui_root()
		local w  = nav_w()
		local y  = LAY.Y + (g_ui.boxh or 0) + LAY.PAD * 2 + 4
		-- 본문이 아주 길면(상한 + 여유분) 이 y가 화면 아래로 넘어간다 → 눌러 앉힌다.
		local ymax = (g_ui.rh or 900) - LAY.TABH - 8
		if y > ymax then y = ymax end
		local cx = LAY.X + math.floor((LAY.COL + LAY.PAD * 2) / 2)
		local p  = find_uicomponent(root, NAV_PREV)
		local nx = find_uicomponent(root, NAV_NEXT)
		if p  then pcall(function() p:MoveTo(cx - w - 6, y) end) end
		if nx then pcall(function() nx:MoveTo(cx + 6, y) end) end
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
					outv = { label = r.label, value = v, max = r.max, note = note, urgent = urgent }
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

-- ── v36 실측 프로브(DEBUG 전용) — CAI 스탠스·예산 API ────────────────
-- tw_autogen 실존 확인됨(CAMPAIGN_AI_SCRIPT_INTERFACE)이나 반환 형식·인자 타입·
-- 플레이어 대상 작동 여부 미상 → 인게임 1클릭으로 전부 기록. 확정되면 조언에 채택.
local function probe_cai_v36(S)
	if not DEBUG_FILE then return end
	pcall(function()
		local L = {}
		local ai = nil
		pcall(function() ai = cm:model():campaign_ai() end)
		if not ai then proof("[v36프로브] campaign_ai() nil", true); return end
		local isnull = nil
		pcall(function() isnull = ai:is_null_interface() end)
		L[#L+1] = string.format("ai=%s null=%s", tostring(ai), tostring(isnull))
		local f = nil
		pcall(function() f = cm:get_local_faction(true) end)
		-- 2차(v36b): 1차 결과 = 전부 number, 객체인자=0(디폴트 의심) vs 키인자=-2(실값 유력).
		--   → 키 인자로 방향·대상 매트릭스 + 예산도 키로 재시도 → enum 실재 여부 확정.
		local ekey = S.border_enemies and S.border_enemies[1]                    -- 전쟁 상대
		local nkey = (S.border_others and S.border_others[1])
			or (S.snowball and S.snowball.key)                                   -- 비적대(대조군)
		L[#L+1] = string.format("적=%s 중립=%s", tostring(ekey), tostring(nkey))
		local function try(tag, fn)
			local ok2, v = pcall(fn)
			L[#L+1] = string.format("%s: ok=%s %s", tag, tostring(ok2), tostring(v))
		end
		local pairs_to_test = {
			{ "나→적",   S.faction, ekey }, { "적→나",   ekey, S.faction },
			{ "나→중립", S.faction, nkey }, { "중립→나", nkey, S.faction },
			{ "적→중립", ekey, nkey },
		}
		for _, p in ipairs(pairs_to_test) do
			if p[2] and p[3] then
				try("stance(" .. p[1] .. ")", function() return ai:strategic_stance_between_factions(p[2], p[3]) end)
			end
		end
		-- cqi 변형(일부 CA 함수는 cqi를 받음)
		if f and ekey then
			try("stance(cqi)", function()
				local ef = cm:get_faction(ekey, false)
				return ai:strategic_stance_between_factions(f:command_queue_index(), ef:command_queue_index())
			end)
		end
		-- 예산: 키 인자로 재시도(1차 객체인자=전부 0)
		if ekey then
			for _, area in ipairs({ "ARMIES", "CONSTRUCTION", "DIPLOMACY", "TECHNOLOGIES", "AGENTS", "CHARACTERS" }) do
				try("funds적(" .. area .. ")", function() return ai:funds_available_for_immediate_payment_for_faction_by_area(ekey, area) end)
			end
			try("funds적유지", function() return ai:funds_available_for_upkeep_for_faction_by_area(ekey, "ARMIES") end)
		end
		if nkey then
			try("funds중립(ARMIES)", function() return ai:funds_available_for_immediate_payment_for_faction_by_area(nkey, "ARMIES") end)
		end
		-- 스탠스 패밀리 부가정보(있으면 enum 해석에 도움)
		if ekey and S.faction then
			try("stance차단(나→적)", function() return ai:strategic_stance_between_factions_is_being_blocked(S.faction, ekey) end)
			try("stance승격시작(나→적)", function() return ai:strategic_stance_between_factions_promotion_start_level(S.faction, ekey) end)
		end
		proof("[v36b프로브] " .. table.concat(L, " | "), true)
	end)
end

-- ── 도메인 레지스트리(v41) ───────────────────────────────────────────
-- 도메인 파일(advisor_dom_*.lua)이 로드 시 CA_DOMAINS에 등록:
--   { id="internal", order=20, title="내정", build=function(S, B) return {줄...} end }
-- 로드 순서는 보장되지 않으므로 전역 접근은 전부 '호출 시점'에만 한다.
local function domains_sorted()
	local L = {}
	pcall(function()
		if type(CA_DOMAINS) == "table" then
			for _, d in ipairs(CA_DOMAINS) do
				if type(d) == "table" and d.id and d.build then L[#L + 1] = d end
			end
		end
	end)
	table.sort(L, function(a, b) return (a.order or 99) < (b.order or 99) end)
	return L
end

-- ── 턴당 1회 기반 수집(v41) — 탭을 바꿔도 다시 긁지 않는다 ───────────
-- 클릭마다 전부 수집하면 도메인이 늘어난 만큼 그대로 느려진다. 기반 상태는
-- 턴당 1회, 도메인 본문은 탭을 처음 열 때 1회만 계산해 B.content에 캐시.
local g_base = { turn = -2, content = {}, pages = {} }
local function ensure_base()
	local turn = -1
	pcall(function() turn = cm:turn_number() end)
	-- 'S가 있으면'이 아니라 '이번 턴에 시도했으면'으로 판정한다. 수집이 실패하면
	-- S가 nil이라, 예전 조건으로는 탭을 누를 때마다 무거운 수집을 통째로 다시 돌리고
	-- 프루프에도 같은 예외를 계속 쌓았다. 실패도 턴당 한 번으로 묶는다.
	if g_base.turn == turn and g_base.tried then return g_base end
	local B = { turn = turn, content = {}, pages = {}, tried = true }
	local ok, err = pcall(function()
		local S = gather_state()
		local prof = get_profile(S)                        -- 진영 전략 프로필
		S.melee_race = (prof and prof.melee) or false      -- v33: 근접 정체성 종족(원거리 경고 제외)
		S.resource = gather_resource(prof)                 -- 종족 고유 자원(①)
		local hist = read_history()                        -- 턴별 추세
		S.trend = compute_trend(S, hist)
		S.rival_growth = compute_rival_growth(S, hist)   -- ⑥ 라이벌 성장률
		S.proj = project(S)                              -- v37 전방 투영(외삽)
		proof(string.format("[디버그] 세이브값 히스토리 %d행 · 추세 %s · 최강라이벌 %s · 종족자원 %s",
			#hist, S.trend and "O" or "X(첫턴/미축적)",
			S.snowball and tostring(S.snowball.key) or "없음",
			S.resource and tostring(S.resource.label) or "없음(미커버 종족)"), true)
		S.strat = collect_strategic(S)                     -- 전략 2.0: 속주·국력·군단·엔드게임·승리조건
		if S.health and not (S.strat and S.strat.ok) then S.health[#S.health + 1] = "전략" end   -- v35
		probe_cai_v36(S)                                   -- v36: CAI 스탠스·예산 API 실측(DEBUG 전용)
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
		pcall(function()                                   -- 메인 버튼 툴팁(패널 없이도 요약이 보이게)
			local btn = find_uicomponent(core:get_ui_root(), BUTTON_ID)
			if btn then btn:SetTooltipText(tip, "", true) end
		end)
		B.S, B.D, B.cand, B.prof, B.prose = S, D, cand, prof, prose
		record_snapshot(S, hist)                           -- 현재 턴 스냅샷 저장
	end)
	if not ok then proof("v41 기반 수집 예외: " .. tostring(err), true) end
	g_base = B
	return B
end

-- 탭 본문(캐시). 실패는 반드시 눈에 보이게 — 빈 화면으로 위장하지 않는다.
local function content_for(id)
	local B = ensure_base()
	if B.content[id] then return B.content[id] end
	local lines, ok = nil, false
	for _, d in ipairs(domains_sorted()) do
		if d.id == id then
			ok = pcall(function() lines = d.build(B.S, B) end)
			break
		end
	end
	if type(lines) == "string" then lines = split_lines(lines) end
	if type(lines) ~= "table" or #lines == 0 then
		-- 실패 문구는 캐시하지 않는다 — 캐시해 버리면 일시적 실패가 그 턴 내내 굳는다.
		return { "⚠ 이 항목을 읽지 못했습니다 — 짐작 대신 판단을 보류합니다.",
		         ok and "(수집은 됐지만 내용이 비었습니다)" or "(수집 중 오류)" }
	end
	B.content[id] = lines
	return lines
end

local function ui_render()
	local lines = content_for(g_ui.tab)
	local textc = panel_text()
	if not textc then get_panel(); textc = panel_text() end
	-- 페이지 분할은 줄 수만큼 실측을 반복하므로 싸지 않다. 페이지를 넘길 때마다
	-- 다시 계산하지 않도록 탭별로 캐시한다(기반 캐시와 같이 턴이 바뀌면 버려진다).
	g_base.pages = g_base.pages or {}
	local pages = g_base.pages[g_ui.tab]
	if not pages then
		pages = paginate(textc, lines)
		g_base.pages[g_ui.tab] = pages
	end
	g_ui.npages = #pages
	if g_ui.page > g_ui.npages then g_ui.page = g_ui.npages end
	if g_ui.page < 1 then g_ui.page = 1 end
	local body = pages[g_ui.page] or ""
	if g_ui.npages > 1 then
		body = body .. string.format("\n— %d/%d 쪽 —", g_ui.page, g_ui.npages)
	end
	panel_draw(body)
	ui_place_nav()
	ui_mark_active()
	ui_tabs_visible(true)
end

local function ui_open(tab)
	local doms = domains_sorted()
	if #doms == 0 then proof("v41 !!! 등록된 도메인이 없음", true); return end
	ui_build_tabs(doms)
	local want = tab or g_ui.tab or doms[1].id
	local found = false
	for _, d in ipairs(doms) do if d.id == want then found = true end end
	g_ui.tab = found and want or doms[1].id
	g_ui.open = true
	ui_render()
end

local function ui_close()
	g_ui.open = false
	panel_hide()
	ui_tabs_visible(false)
end

local function ui_click(id)
	local ok, err = pcall(function()
		if id == BUTTON_ID then
			if g_ui.open then ui_close() else g_ui.page = 1; ui_open(nil) end
			return
		end
		if not g_ui.open then return end
		if id == NAV_PREV then
			g_ui.page = (g_ui.page <= 1) and g_ui.npages or (g_ui.page - 1); ui_render(); return
		end
		if id == NAV_NEXT then
			g_ui.page = (g_ui.page >= g_ui.npages) and 1 or (g_ui.page + 1); ui_render(); return
		end
		local tid = id:match("^" .. TAB_PREFIX .. "(.+)$")
		if tid then
			if tid == g_ui.tab then ui_close() else g_ui.tab = tid; g_ui.page = 1; ui_render() end
		end
	end)
	if not ok then proof("v41 클릭 처리 예외(" .. tostring(id) .. "): " .. tostring(err), true) end
end

-- ── 버튼 + 리스너 (Step3/4 유지, v41에서 탭·페이지로 확장) ───────────
local function register_click_listener()
	core:add_listener(
		"advisor_button_click", "ComponentLClickUp",
		function(context)
			local s = context.string
			if type(s) ~= "string" then return false end
			return s == BUTTON_ID or s == NAV_PREV or s == NAV_NEXT
				or s:match("^" .. TAB_PREFIX) ~= nil
		end,
		function(context) ui_click(context.string) end,
		true)
	proof("2a 클릭 리스너 등록 (메인=" .. BUTTON_ID .. " · 탭=" .. TAB_PREFIX .. "*)", true)
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

--[[═════════════════════════════════════════════════════════════════════
  도메인 공용 유틸 노출(v41) — 게임에서도 항상 켜짐
  ------------------------------------------------------------------------
  advisor_dom_*.lua 는 이 파일보다 먼저 로드될 수 있으므로, 도메인 쪽에서는
  반드시 '호출 시점'에 CA_U를 읽어야 한다(로드 시점 캡처 금지).
═══════════════════════════════════════════════════════════════════════]]
-- 천 단위 구분 / 부호 붙이기. 도메인 파일마다 복사하지 않도록 여기서 한 번만 정의한다
-- (게임 Lua의 string.sub은 문자 단위라 자릿수 계산 대신 gsub 반복으로 처리).
local function comma(n)
	local s = tostring(math.floor(tonumber(n) or 0))
	local sign = ""
	if s:sub(1, 1) == "-" then sign = "-"; s = s:sub(2) end
	while true do
		local rep
		s, rep = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
		if rep == 0 then break end
	end
	return sign .. s
end

local function signed(n)
	local v = math.floor(tonumber(n) or 0)
	return (v >= 0 and "+" or "") .. comma(v)
end

-- ── 로컬라이즈 이름 조회 (게임 언어가 한국어면 한글이 온다) ────────────
--   접두사 규칙은 전부 언어팩 실측(local_kr.pack의 194,564 엔트리 대조):
--     technologies_onscreen_name_<기술키>      1,863개 — 연결 없이 단순
--     land_units_onscreen_name_<유닛키>        2,483개 — 우리 해금 유닛 718/766 적중
--   ※ 건물 이름만 규칙이 다르다(기본키 컬럼 연결) → CA_BLDQ.name이 따로 처리.
--   실패하면 키를 사람이 읽을 만하게 다듬어 돌려준다. 없는 한글을 지어내지 않는다.
local g_loc_cache = {}
local function loc_name(prefix, key)
	if type(key) ~= "string" or key == "" then return nil end
	local ck = prefix .. key
	local hit = g_loc_cache[ck]
	if hit then return hit end
	local disp = nil
	pcall(function()
		local s = common.get_localised_string(ck)
		if s and s ~= "" then disp = s end
	end)
	if not disp then disp = (key:gsub("^wh%d?_[%w]+_", ""):gsub("_", " ")) end
	g_loc_cache[ck] = disp
	return disp
end
local function tech_name(k) return loc_name("technologies_onscreen_name_", k) end
local function unit_name(k) return loc_name("land_units_onscreen_name_", k) end

CA_U = {
	num = num, clamp = clamp, sev = sev,
	loc_name = loc_name, tech_name = tech_name, unit_name = unit_name,
	josa = josa, josa_ro = josa_ro, nro = nro, has_batchim = has_batchim,
	clause = clause, join_clauses = join_clauses,
	fname = fname, region_disp = region_disp, province_disp = province_disp,
	first_names = first_names, proof = proof,
	comma = comma, signed = signed,
	eval_deal = eval_deal,   -- CAI 수락 예측(외교 도메인이 같은 구현을 재사용)
}

-- 대전략 탭(order 10) — 본문은 기존 산문 전체. 나머지 도메인은 별도 파일에서 등록.
CA_DOMAINS = CA_DOMAINS or {}
CA_DOMAINS[#CA_DOMAINS + 1] = {
	id = "grand", order = 10, title = "대전략",
	build = function(S, B) return split_lines(B and B.prose or "") end,
}

-- ── 오프라인 테스트 export (게임에선 완전 무시) ──────────────────────
-- 하니스(test/run_brain_tests.lua)가 dofile 전에 ADVISOR_TEST_EXPORTS=true를
-- 설정하면 순수 함수들을 노출. 인게임에선 전역이 nil이라 이 블록은 no-op.
if ADVISOR_TEST_EXPORTS then
	CA_TEST = {
		split_lines = split_lines, domains_sorted = domains_sorted,   -- v41 셸
		num = num, clamp = clamp, sev = sev,
		has_batchim = has_batchim, josa = josa, josa_ro = josa_ro,
		key_set = key_set, runway_phrase = runway_phrase,   -- v40
		gather_threats = gather_threats,                    -- v40: 영토0 앵커 스캔을 스텁으로 검증
		-- v61: 페이지 분할. 인게임에서 한 번도 실행된 적이 없는 경로다 —
		--   우리 기기 MAXH=968인데 관측 최대 본문이 866이라 늘 1쪽이었다.
		--   MAXH는 화면 높이에서 나오므로(rh-176-96) 1080p 사용자는 ~565라 지금도 2쪽이다.
		paginate = paginate, LAY = LAY,
		clause = clause, join_clauses = join_clauses,
		fname = fname, region_disp = region_disp, first_names = first_names,
		get_profile = get_profile,
		analyze = analyze, overall = overall, diagnose = diagnose,
		build_briefing = build_briefing, build_prose = build_prose,
		read_history = read_history, compute_trend = compute_trend,
		compute_rival_growth = compute_rival_growth, record_snapshot = record_snapshot,
		project = project,
		gather_resource = gather_resource,
		-- 전략 2.0(순수부)
		plan_serialize = plan_serialize, plan_deserialize = plan_deserialize,
		plan_generate = plan_generate, plan_revise = plan_revise,
		plan_prose_lines = plan_prose_lines, endgame_disp = endgame_disp,
	}
end
