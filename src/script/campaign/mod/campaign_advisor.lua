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

local PROOF_PATH      = "C:/Users/veria/tw3_advisor_proof.txt"
local HISTORY_PATH    = "C:/Users/veria/tw3_advisor_history.txt"   -- 턴별 스냅샷(추세 계산)
local BUTTON_ID       = "advisor_recommend_button"
local BUTTON_TEMPLATE = "ui/templates/round_medium_button"

-- CA 실측 시드 상수
local SEED = {
	army_base = 55, cons_base = 40,   -- default 예산배분(%)
	reinvest  = 0.9,                  -- 순수입 재투자 비율
	buffer_target = 5,                -- 흑자시 목표 재정버퍼(턴)
}

-- out() + (io 가능하면) 파일 기록. 둘 다 pcall 보호.
local function proof(msg, append)
	pcall(function() out("[CAMPAIGN_ADVISOR] " .. msg) end)
	pcall(function()
		if io and io.open then
			local f = io.open(PROOF_PATH, append and "a" or "w")
			if f then f:write(msg .. "\n"); f:close() end
		end
	end)
end

proof("STEP5(2a) 파일 로드됨 (NewSession/top-level).", false)
-- 세션(캠페인)마다 추세 히스토리 초기화 → 캠페인 간 오염 방지.
pcall(function() if io and io.open then local h = io.open(HISTORY_PATH, "w"); if h then h:close() end end end)

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
local function fname(key)
	if key == nil then return "(알수없음)" end
	return FACTION_NAME[key] or key
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
	-- 방어 (전선 방어) — 국경 접한 적 중심
	do
		local sc, rs = 0, {}
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
	-- 기술 (연구)
	if S.research_idle == true then
		cand[#cand+1] = { key = "tech", label = "기술", score = 45, reasons = { "연구가 미가동 상태 — 즉시 착수 권장" } }
	end
	-- 외교 (동맹/화친)
	if wars >= 2 then
		cand[#cand+1] = { key = "diplomacy", label = "외교", score = clamp(30 + wars * 6, 0, 100),
			reasons = { string.format("%d개 세력과 동시 전쟁 — 동맹/화친으로 전선 축소 검토", wars) } }
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
		((num(S.net,0) >= 0) and ("+"..num(S.net,0)) or tostring(S.net)),
		tostring(num(S.regions,"?")), tostring(num(S.generals,"?")), tostring(num(S.armies,"?")))
	L[#L+1] = string.format("파생: 군대밀도 %.2f · 재정버퍼 %s · 국경적 %d(%s) · 원거리전 %d · 비적대이웃 %d",
		D.density, buffer_str, D.immediate, wars, D.distant, D.others)
	if S.trend then
		L[#L+1] = string.format("📈 추세(%d턴 전 대비): 재정 %+d · 영토 %+d · 수입 %+d",
			S.trend.dt, S.trend.treasury, S.trend.regions, S.trend.income)
	end
	L[#L+1] = "▶ 종합: " .. overall(S, D)
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

local function build_prose(S, D, cand, prof)
	local race = (prof and prof.race and prof.race ~= "(일반)") and prof.race or fname(S.faction)
	local rot = function(t) return t[(g_click - 1) % #t + 1] end
	local P = {}
	-- 정세 도입
	local eco = D.deficit and "재정은 적자라 주의가 필요하고"
		or (D.net > 0 and string.format("재정은 순 +%d로 흑자이며", num(S.net, 0)) or "재정은 대체로 균형이고")
	local threat
	if D.immediate >= 2 then threat = "국경에서 여러 세력의 압박을 받고 있습니다"
	elseif D.immediate == 1 then threat = string.format("국경에서 %s의 압박을 받고 있습니다", tostring(S.war_names[1] or "적"))
	elseif D.wars > 0 then threat = "전쟁 중이나 국경은 아직 평온합니다"
	else threat = "국경은 평온합니다" end
	P[#P+1] = string.format("%s, %s%s %s턴 현재 %s, %s.", rot(PROSE_OPEN), race, josa(race, "은", "는"), tostring(num(S.turn, "?")), eco, threat)
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
			P[#P+1] = string.format("무엇보다 %s%s %s — %s.", cand[1].label, josa(cand[1].label, "이", "가"), urgency(cand[1].score), tostring(r1))
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

-- ── 턴별 추세 (io 스냅샷 비교) ───────────────────────────────────────
-- 각 줄: faction|turn|treasury|regions|armies|income
local function read_history()
	local list = {}
	pcall(function()
		if not (io and io.open) then return end
		local fh = io.open(HISTORY_PATH, "r")
		if not fh then return end
		for line in fh:lines() do
			local fac, t, tr, rg, ar, inc = line:match("([^|]*)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)")
			if fac then
				list[#list + 1] = { faction = fac, turn = tonumber(t), treasury = tonumber(tr),
					regions = tonumber(rg), armies = tonumber(ar), income = tonumber(inc) }
			end
		end
		fh:close()
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

-- 현재 턴 스냅샷 기록(같은 팩션·턴 갱신, 최근 12줄 유지).
local function record_snapshot(S, hist)
	pcall(function()
		if not (io and io.open) or not S.faction then return end
		local kept = {}
		for _, h in ipairs(hist) do
			if not (h.faction == S.faction and h.turn == num(S.turn, 0)) then kept[#kept + 1] = h end
		end
		kept[#kept + 1] = { faction = S.faction, turn = num(S.turn, 0), treasury = num(S.treasury, 0),
			regions = num(S.regions, 0), armies = num(S.generals, 0), income = num(S.income, 0) }
		while #kept > 12 do table.remove(kept, 1) end
		local fh = io.open(HISTORY_PATH, "w")
		if not fh then return end
		for _, h in ipairs(kept) do
			fh:write(string.format("%s|%d|%d|%d|%d|%d\n", tostring(h.faction), h.turn or 0,
				h.treasury or 0, h.regions or 0, h.armies or 0, h.income or 0))
		end
		fh:close()
	end)
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

-- ── 클릭 시 실행되는 두뇌 ────────────────────────────────────────────
local function run_advisor()
	local ok, err = pcall(function()
		local S = gather_state()
		local prof = get_profile(S)                        -- 진영 전략 프로필
		local hist = read_history()                        -- 턴별 추세
		S.trend = compute_trend(S, hist)
		local D, cand = analyze(S, prof)
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
