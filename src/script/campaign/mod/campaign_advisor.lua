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
		if sc > 0 then cand[#cand+1] = { key = "defense", label = "방어", score = clamp(sc, 0, 100), reasons = rs } end
	end
	-- 확장 (선제/영토) — 국경 평온 + 흑자 + 비적대 이웃 존재
	if immediate == 0 and net > 0 and buffer >= SEED.buffer_target and others > 0 then
		local sc = 35 + ((density >= 1) and 15 or 0)
		local tgt = fname(S.border_others[1])
		cand[#cand+1] = { key = "expansion", label = "확장", score = clamp(sc, 0, 100),
			reasons = { string.format("국경 평온+흑자, 인접 세력 %d개(%s 등) — 확장/선제 검토", others, tgt) } }
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
	L[#L+1] = "▶ 종합: " .. overall(S, D)
	if prof and prof.race and prof.race ~= "(일반)" then
		L[#L+1] = string.format("🏰 %s — %s", prof.race, tostring(prof.identity or ""))
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

-- 화면(툴팁)용 간략 브리핑 — g_click 증가시키지 않음(build_briefing과 별개).
local function build_tooltip(S, D, cand, prof)
	local L = {}
	L[#L+1] = string.format("[전략 브리핑] %s · %s턴", fname(S.faction), tostring(num(S.turn, "?")))
	L[#L+1] = string.format("재정 %s (순 %s) · 영토 %s · 필드군 %s",
		tostring(num(S.treasury, "?")),
		((num(S.net, 0) >= 0) and ("+" .. num(S.net, 0)) or tostring(S.net)),
		tostring(num(S.regions, "?")), tostring(num(S.generals, "?")))
	L[#L+1] = "종합: " .. overall(S, D)
	if prof and prof.tips and #prof.tips > 0 then
		L[#L+1] = "💡 " .. prof.tips[(g_click - 1) % #prof.tips + 1]
	end
	for i = 1, math.min(#cand, 3) do
		local c = cand[i]
		local r0 = (#c.reasons > 0) and c.reasons[1] or "(기본)"
		L[#L+1] = string.format("%d. [%s·%s %d] %s", i, c.label, sev(c.score), c.score, r0)
	end
	return table.concat(L, "\n")
end

-- ── 클릭 시 실행되는 두뇌 ────────────────────────────────────────────
local function run_advisor()
	local ok, err = pcall(function()
		local S = gather_state()
		local prof = get_profile(S)                        -- 진영 전략 프로필
		local D, cand = analyze(S, prof)
		proof(build_briefing(S, D, cand, prof), true)      -- 파일: 전체 브리핑
		local tip = build_tooltip(S, D, cand, prof)        -- 화면: 간략 브리핑
		pcall(function()
			local btn = find_uicomponent(core:get_ui_root(), BUTTON_ID)
			if btn then btn:SetTooltipText(tip, "", true) end
		end)
	end)
	if not ok then proof("v9a run_advisor 예외: " .. tostring(err), true) end
end

-- ── 버튼 + 리스너 (Step3/4 유지) ─────────────────────────────────────
local function register_click_listener()
	core:add_listener(
		"advisor_button_click", "ComponentLClickUp",
		function(context) return context.string == BUTTON_ID end,
		function(context) run_advisor() end,
		true)
	proof("2a 클릭 리스너 등록 (id=" .. BUTTON_ID .. ")", true)
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
