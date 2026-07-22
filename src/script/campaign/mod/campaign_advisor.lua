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

-- ── 상태 수집 (getter마다 개별 pcall) ────────────────────────────────
local function gather_state()
	local f = nil
	pcall(function() f = cm:get_local_faction(true) end)
	local function V(fn)  local ok, v = pcall(fn); if ok then return v end return nil end
	local function LN(fn) local ok, l = pcall(fn); if ok and l then return l:num_items() end return nil end
	local S = {}
	S.faction      = V(function() return f:name() end)
	S.turn         = V(function() return cm:turn_number() end)
	S.treasury     = V(function() return f:treasury() end)
	S.income       = V(function() return f:income() end)
	S.net          = V(function() return f:net_income() end)
	S.losing       = V(function() return f:losing_money() end)
	S.regions      = LN(function() return f:region_list() end)
	S.provinces    = V(function() return f:num_provinces() end)
	S.armies       = LN(function() return f:military_force_list() end)  -- 수비대 포함
	S.generals     = V(function() return f:num_generals() end)          -- ≈ 필드군
	S.war_count    = LN(function() return f:factions_at_war_with() end)
	S.research_idle= V(function() return f:research_queue_idle() end)
	S.war_names = {}
	pcall(function()
		local wl = f:factions_at_war_with(); local n = wl:num_items()
		for i = 0, math.min(n, 3) - 1 do S.war_names[#S.war_names + 1] = fname(wl:item_at(i):name()) end
	end)
	return S
end

-- ── 파생지표 + 2축 스코어링 ──────────────────────────────────────────
local function analyze(S)
	local regions  = num(S.regions, 0)
	local field    = num(S.generals, 0)
	local income   = num(S.income, 0)
	local net      = num(S.net, 0)
	local treasury = num(S.treasury, 0)
	local threat   = num(S.war_count, 0)
	local deficit  = (S.losing == true) or (net < 0)
	local density  = (regions > 0) and (field / regions) or 0
	local buffer   = (income > 0) and (treasury / income) or 999

	local D = { density = density, buffer = buffer, threat = threat, deficit = deficit, net = net }
	local cand = {}

	-- 군사 (모집/증원)
	do
		local sc, rs = SEED.army_base, {}
		if threat > 0 then sc = sc + threat * 8; rs[#rs+1] = string.format("%d개 세력과 교전 중", threat) end
		if regions > 0 and density < 1 then sc = sc + 20; rs[#rs+1] = string.format("영토 %d개 대비 필드군 %d개로 얇음", regions, field) end
		if deficit then sc = sc - 15; rs[#rs+1] = "적자라 모집 여력 제한" end
		if net > 0 then sc = sc + 8; rs[#rs+1] = string.format("순수입 +%d 흑자로 모집 여력 있음", net) end
		cand[#cand+1] = { key = "military", label = "군사", score = clamp(sc, 0, 100), reasons = rs }
	end
	-- 경제 (건설/수입기반)
	do
		local sc, rs = SEED.cons_base, {}
		if deficit then sc = sc + 30; rs[#rs+1] = "적자 — 수입 기반 확충 시급" end
		if buffer < SEED.buffer_target then sc = sc + 15; rs[#rs+1] = string.format("재정 버퍼 %.1f턴치(CA 권장 %d턴 미만)", buffer, SEED.buffer_target) end
		if threat == 0 then sc = sc + 12; rs[#rs+1] = "평시 — 성장 적기" end
		if threat >= 2 then sc = sc - threat * 4; rs[#rs+1] = "다전선으로 건설 우선순위 하락" end
		cand[#cand+1] = { key = "economy", label = "경제", score = clamp(sc, 0, 100), reasons = rs }
	end
	-- 방어 (전선 방어)
	do
		local sc, rs = 0, {}
		if threat > 0 then sc = sc + threat * 12; rs[#rs+1] = string.format("%d개 전선", threat) end
		if regions > 0 and density < 0.5 then sc = sc + 25; rs[#rs+1] = "군대 밀도 매우 낮음 — 방어 취약" end
		if sc > 0 then cand[#cand+1] = { key = "defense", label = "방어", score = clamp(sc, 0, 100), reasons = rs } end
	end
	-- 기술 (연구)
	if S.research_idle == true then
		cand[#cand+1] = { key = "tech", label = "기술", score = 45, reasons = { "연구가 미가동 상태 — 즉시 착수 권장" } }
	end
	-- 외교 (동맹/화친)
	if threat >= 2 then
		cand[#cand+1] = { key = "diplomacy", label = "외교", score = clamp(30 + threat * 6, 0, 100),
			reasons = { string.format("%d개 세력과 동시 전쟁 — 동맹/화친으로 전선 축소 검토", threat) } }
	end

	table.sort(cand, function(a, b) return a.score > b.score end)
	return D, cand
end

-- ── 종합 판단 한 줄 ──────────────────────────────────────────────────
local function overall(S, D)
	local p = {}
	if num(S.turn, 99) <= 10 then p[#p+1] = "초반 확장기" end
	if D.deficit then p[#p+1] = "적자 운영" elseif D.net > 0 then p[#p+1] = "흑자 운영" end
	if D.threat >= 2 then p[#p+1] = "다전선 압박" elseif D.threat == 1 then p[#p+1] = "국지전 중" else p[#p+1] = "평시" end
	if D.density < 1 then p[#p+1] = "군대 얇음" end
	return table.concat(p, " · ")
end

-- ── 브리핑 조립(다양한 오프너 + 랭킹 조언) ──────────────────────────
local OPENERS = { "전략 브리핑", "현황 분석", "참모 보고", "정세 판단" }

local function build_briefing(S, D, cand)
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
	L[#L+1] = string.format("파생: 군대밀도 %.2f/영토 · 재정버퍼 %s · 교전 %d(%s)",
		D.density, buffer_str, D.threat, wars)
	L[#L+1] = "▶ 종합: " .. overall(S, D)
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

-- ── 클릭 시 실행되는 두뇌 ────────────────────────────────────────────
local function run_advisor()
	local ok, err = pcall(function()
		local S = gather_state()
		local D, cand = analyze(S)
		proof(build_briefing(S, D, cand), true)
	end)
	if not ok then proof("2a run_advisor 예외: " .. tostring(err), true) end
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
		pcall(function() btn:SetTooltipText("Advisor: strategic briefing (click)", "", true) end)
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
